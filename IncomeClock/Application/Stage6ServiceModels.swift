import Foundation

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied

    var permitsScheduling: Bool { self == .authorized }
}

struct WorkdayEndNotificationRequest: Equatable, Sendable {
    static let body = "今日计薪已自动停止，别忘了打卡下班。"

    let identifier: String
    let scheduledAt: TimestampMilliseconds
    let timeZoneIdentifier: String
}

protocol NotificationServicing: Sendable {
    func authorizationStatus() async throws -> NotificationAuthorizationState
    func requestAuthorization() async throws -> NotificationAuthorizationState
    func pendingRequestIdentifiers() async throws -> Set<String>
    func add(_ request: WorkdayEndNotificationRequest) async throws
    func removePendingRequest(identifier: String) async throws
}

actor UnavailableNotificationService: NotificationServicing {
    func authorizationStatus() -> NotificationAuthorizationState { .denied }
    func requestAuthorization() -> NotificationAuthorizationState { .denied }
    func pendingRequestIdentifiers() -> Set<String> { [] }
    func add(_ request: WorkdayEndNotificationRequest) throws {
        _ = request
        throw NotificationFeatureError.addFailed
    }
    func removePendingRequest(identifier: String) throws { _ = identifier }
}

enum NotificationFeatureError: Error, Equatable, Sendable {
    case permissionDenied
    case permissionQueryFailed
    case permissionRequestFailed
    case settingsPersistenceFailed
    case pendingQueryFailed
    case addFailed
    case addNotConfirmed
    case markerPersistenceFailed
    case cancellationFailed
    case cancellationPendingQueryFailed
    case cancellationNotConfirmed
}

enum NotificationDiagnosticEvent: Equatable, Sendable {
    case scheduling(NotificationFeatureError, identifier: String?)
    case cancellation(NotificationFeatureError, identifier: String)
}

enum Stage6PreferenceOutcome: Equatable, Sendable {
    case committed
    case rejected
    case failed
}

enum LoginItemSystemStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool { self == .enabled }
}

enum LoginItemServiceError: Error, Equatable, Sendable {
    case denied
    case registerFailed
    case unregisterFailed
    case statusReadFailed
    case inconsistentStatus
    case settingsPersistenceFailed
    case rollbackFailed
    case openSettingsFailed
}

protocol LoginItemServicing: Sendable {
    func status() async throws -> LoginItemSystemStatus
    func register() async throws
    func unregister() async throws
    @MainActor func openSystemSettings() throws
}

actor UnavailableLoginItemService: LoginItemServicing {
    func status() -> LoginItemSystemStatus { .disabled }
    func register() throws { throw LoginItemServiceError.registerFailed }
    func unregister() throws { throw LoginItemServiceError.unregisterFailed }
    @MainActor func openSystemSettings() throws { throw LoginItemServiceError.openSettingsFailed }
}

#if DEBUG
actor FakeNotificationService: NotificationServicing {
    enum Operation: Equatable, Hashable, Sendable {
        case authorizationStatus
        case requestAuthorization
        case pending
        case add(String)
        case remove(String)
    }

    private var currentAuthorization: NotificationAuthorizationState
    private var requestedAuthorizationResult: NotificationAuthorizationState?
    private var pendingIdentifiers: Set<String>
    private var queuedErrors: [Operation: [NotificationFeatureError]] = [:]
    private var shouldRetainNextRemovedIdentifier = false
    private(set) var operations: [Operation] = []

    init(
        authorization: NotificationAuthorizationState = .notDetermined,
        pendingIdentifiers: Set<String> = []
    ) {
        currentAuthorization = authorization
        self.pendingIdentifiers = pendingIdentifiers
    }

    func authorizationStatus() throws -> NotificationAuthorizationState {
        try record(.authorizationStatus)
        return currentAuthorization
    }

    func requestAuthorization() throws -> NotificationAuthorizationState {
        try record(.requestAuthorization)
        if let requestedAuthorizationResult {
            currentAuthorization = requestedAuthorizationResult
        }
        return currentAuthorization
    }

    func pendingRequestIdentifiers() throws -> Set<String> {
        try record(.pending)
        return pendingIdentifiers
    }

    func add(_ request: WorkdayEndNotificationRequest) throws {
        try record(.add(request.identifier))
        pendingIdentifiers.insert(request.identifier)
    }

    func removePendingRequest(identifier: String) throws {
        try record(.remove(identifier))
        if shouldRetainNextRemovedIdentifier {
            shouldRetainNextRemovedIdentifier = false
            return
        }
        pendingIdentifiers.remove(identifier)
    }

    func setAuthorization(_ state: NotificationAuthorizationState) {
        currentAuthorization = state
    }

    func setRequestAuthorizationResult(_ state: NotificationAuthorizationState) {
        requestedAuthorizationResult = state
    }

    func setPendingIdentifiers(_ identifiers: Set<String>) {
        pendingIdentifiers = identifiers
    }

    func retainNextRemovedIdentifier() {
        shouldRetainNextRemovedIdentifier = true
    }

    func enqueueError(_ error: NotificationFeatureError, for operation: Operation) {
        queuedErrors[operation, default: []].append(error)
    }

    func operationLog() -> [Operation] { operations }

    private func record(_ operation: Operation) throws {
        operations.append(operation)
        if var errors = queuedErrors[operation], !errors.isEmpty {
            let error = errors.removeFirst()
            queuedErrors[operation] = errors
            throw error
        }
    }
}

actor FakeLoginItemService: LoginItemServicing {
    enum Operation: Equatable, Hashable, Sendable {
        case status
        case register
        case unregister
        case openSettings
    }

    private var currentStatus: LoginItemSystemStatus
    private var queuedErrors: [Operation: [LoginItemServiceError]] = [:]
    private var statusQueue: [LoginItemSystemStatus] = []
    private var shouldHoldNextRegister = false
    private var heldRegisterContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldNextUnregister = false
    private var heldUnregisterContinuation: CheckedContinuation<Void, Never>?
    private(set) var operations: [Operation] = []

    init(status: LoginItemSystemStatus = .disabled) {
        currentStatus = status
    }

    func status() throws -> LoginItemSystemStatus {
        try record(.status)
        if !statusQueue.isEmpty {
            currentStatus = statusQueue.removeFirst()
        }
        return currentStatus
    }

    func register() async throws {
        try record(.register)
        if shouldHoldNextRegister {
            shouldHoldNextRegister = false
            await withCheckedContinuation { heldRegisterContinuation = $0 }
        }
        currentStatus = .enabled
    }

    func unregister() async throws {
        try record(.unregister)
        if shouldHoldNextUnregister {
            shouldHoldNextUnregister = false
            await withCheckedContinuation { heldUnregisterContinuation = $0 }
        }
        currentStatus = .disabled
    }

    @MainActor func openSystemSettings() throws {
        // DEBUG/Test deliberately performs no external operation.
    }

    func setStatus(_ status: LoginItemSystemStatus) { currentStatus = status }
    func enqueueStatus(_ status: LoginItemSystemStatus) { statusQueue.append(status) }
    func enqueueError(_ error: LoginItemServiceError, for operation: Operation) {
        queuedErrors[operation, default: []].append(error)
    }
    func holdNextRegister() { shouldHoldNextRegister = true }
    func holdNextUnregister() { shouldHoldNextUnregister = true }
    func waitUntilRegisterIsHeld() async {
        while heldRegisterContinuation == nil { await Task.yield() }
    }
    func releaseHeldRegister() {
        heldRegisterContinuation?.resume()
        heldRegisterContinuation = nil
    }
    func waitUntilUnregisterIsHeld() async {
        while heldUnregisterContinuation == nil { await Task.yield() }
    }
    func releaseHeldUnregister() {
        heldUnregisterContinuation?.resume()
        heldUnregisterContinuation = nil
    }
    func operationLog() -> [Operation] { operations }

    private func record(_ operation: Operation) throws {
        operations.append(operation)
        if var errors = queuedErrors[operation], !errors.isEmpty {
            let error = errors.removeFirst()
            queuedErrors[operation] = errors
            throw error
        }
    }
}
#endif
