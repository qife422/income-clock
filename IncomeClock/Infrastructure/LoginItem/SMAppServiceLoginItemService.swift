import AppKit
import Foundation
import ServiceManagement

actor SMAppServiceLoginItemService: LoginItemServicing {
    func status() throws -> LoginItemSystemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: throw LoginItemServiceError.statusReadFailed
        }
    }

    func register() throws {
        do { try SMAppService.mainApp.register() }
        catch { throw LoginItemServiceError.registerFailed }
    }

    func unregister() throws {
        do { try SMAppService.mainApp.unregister() }
        catch { throw LoginItemServiceError.unregisterFailed }
    }

    @MainActor func openSystemSettings() throws {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            throw LoginItemServiceError.openSettingsFailed
        }
    }
}
