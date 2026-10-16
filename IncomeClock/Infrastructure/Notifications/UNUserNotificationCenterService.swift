import Foundation
import UserNotifications

actor UNUserNotificationCenterService: NotificationServicing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async throws -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        return granted ? .authorized : .denied
    }

    func pendingRequestIdentifiers() async throws -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func add(_ request: WorkdayEndNotificationRequest) async throws {
        guard let timeZone = TimeZone(identifier: request.timeZoneIdentifier) else {
            throw NotificationFeatureError.addFailed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(request.scheduledAt.rawValue) / 1_000)
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.timeZone = timeZone

        let content = UNMutableNotificationContent()
        content.body = WorkdayEndNotificationRequest.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func removePendingRequest(identifier: String) async throws {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
