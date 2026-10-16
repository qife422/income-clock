import Foundation
import Combine

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemSystemStatus = .disabled
    @Published private(set) var isProcessing = false
    @Published private(set) var error: LoginItemServiceError?

    private let service: any LoginItemServicing
    private unowned let businessStore: BusinessStore
    private var latestCommandID: UUID?
    private let commandGate = LoginItemCommandGate()

    init(service: any LoginItemServicing, businessStore: BusinessStore) {
        self.service = service
        self.businessStore = businessStore
    }

    var isEnabled: Bool { status.isEnabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() async {
        let preservesInFlightMutationResult = isProcessing
        await commandGate.enter()
        let commandID = beginCommand(clearError: !preservesInFlightMutationResult)
        await performRefresh(
            commandID: commandID,
            preserveExistingError: preservesInFlightMutationResult
        )
        finishCommand(commandID)
        await commandGate.leave()
    }

    func setEnabled(_ enabled: Bool) async {
        await commandGate.enter()
        let commandID = beginCommand()
        await performSetEnabled(enabled, commandID: commandID)
        finishCommand(commandID)
        await commandGate.leave()
    }

    private func performRefresh(
        commandID: UUID,
        preserveExistingError: Bool
    ) async {
        do {
            let actual = try await service.status()
            guard isCurrent(commandID) else { return }
            status = actual
            if actual == .requiresApproval {
                error = .denied
            } else if !preserveExistingError {
                error = nil
            }
        } catch {
            guard isCurrent(commandID) else { return }
            self.error = map(error, fallback: .statusReadFailed)
        }
    }

    private func performSetEnabled(_ enabled: Bool, commandID: UUID) async {
        guard isCurrent(commandID) else { return }

        do {
            let previous = try await service.status()
            guard isCurrent(commandID) else { return }
            if previous.isEnabled != enabled {
                if enabled { try await service.register() }
                else { try await service.unregister() }
            }
            guard isCurrent(commandID) else { return }

            let confirmed = try await service.status()
            guard isCurrent(commandID) else { return }
            guard confirmed != .requiresApproval else {
                status = confirmed
                error = .denied
                return
            }
            guard confirmed.isEnabled == enabled else {
                status = confirmed
                error = .inconsistentStatus
                return
            }

            let persistence = await businessStore.persistLaunchAtLogin(
                enabled,
                commandID: commandID
            )
            guard isCurrent(commandID) else { return }
            guard persistence == .committed else {
                await rollback(to: previous.isEnabled, commandID: commandID)
                return
            }
            status = confirmed
            error = nil
        } catch {
            guard isCurrent(commandID) else { return }
            do {
                status = try await service.status()
            } catch {
                // Retain the last confirmed actual state when even the recheck fails.
            }
            self.error = map(error, fallback: enabled ? .registerFailed : .unregisterFailed)
        }
    }

    func openSystemSettings() {
        do { try service.openSystemSettings() }
        catch { self.error = map(error, fallback: .openSettingsFailed) }
    }

    private func rollback(to enabled: Bool, commandID: UUID) async {
        do {
            if enabled { try await service.register() }
            else { try await service.unregister() }
            let rolledBack = try await service.status()
            guard isCurrent(commandID) else { return }
            status = rolledBack
            error = rolledBack.isEnabled == enabled ? .settingsPersistenceFailed : .rollbackFailed
        } catch {
            guard isCurrent(commandID) else { return }
            if let actual = try? await service.status() { status = actual }
            self.error = .rollbackFailed
        }
    }

    private func beginCommand(clearError: Bool = true) -> UUID {
        let commandID = UUID()
        latestCommandID = commandID
        isProcessing = true
        if clearError { error = nil }
        return commandID
    }

    private func finishCommand(_ commandID: UUID) {
        guard isCurrent(commandID) else { return }
        isProcessing = false
    }

    private func isCurrent(_ commandID: UUID) -> Bool {
        latestCommandID == commandID
    }

    private func map(_ error: Error, fallback: LoginItemServiceError) -> LoginItemServiceError {
        error as? LoginItemServiceError ?? fallback
    }
}

private actor LoginItemCommandGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
