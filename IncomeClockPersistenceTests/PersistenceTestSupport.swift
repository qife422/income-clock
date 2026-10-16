import Foundation
import XCTest
@testable import IncomeClock

enum PersistenceTestSupport {
    static func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockPersistenceTests", isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(root.path.contains("Application Support"))
        return root
    }

    static func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    static func proposedSettings(
        updatedAtMs: Int64 = 1_000,
        notificationsEnabled: Bool = false
    ) -> SettingsRecord {
        SettingsRecord(
            schemaVersion: SettingsRecord.currentSchemaVersion,
            revision: .proposed,
            dailyWageCents: 30_000,
            workStartMinuteOfDay: 9 * 60,
            workEndMinuteOfDay: 18 * 60,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: true,
            lockPanelPosition: false,
            hideInFullScreen: true,
            launchAtLogin: false,
            panelVisible: true,
            panelPlacement: PanelPlacementRecord(
                displayUUID: "test-display",
                snapCorner: .bottomRight,
                xOffset: 20,
                yOffset: 20,
                constrainedFrame: PersistedPanelFrame(x: 100, y: 100, width: 320, height: 190)
            ),
            updatedAtMs: updatedAtMs
        )
    }

    static func proposedToday(
        updatedAtMs: Int64 = 2_000,
        clockOutAtMs: Int64? = nil
    ) -> TodayRecord {
        let start = milliseconds(year: 2026, month: 8, day: 13, hour: 9)
        let end = milliseconds(year: 2026, month: 8, day: 13, hour: 18)
        return TodayRecord(
            schemaVersion: TodayRecord.currentSchemaVersion,
            revision: .proposed,
            dateKey: "2026-08-13",
            clockInAtMs: milliseconds(year: 2026, month: 8, day: 13, hour: 8),
            clockOutAtMs: clockOutAtMs,
            settingsSnapshot: PersistedSettingsSnapshot(
                dailyWageCents: 30_000,
                workStartMinuteOfDay: 9 * 60,
                workEndMinuteOfDay: 18 * 60,
                currency: "CNY",
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            scheduledStartAtMs: start,
            scheduledEndAtMs: end,
            notificationScheduledDateKey: "2026-08-13",
            notificationRequestIdentifier: "workday-end-2026-08-13",
            updatedAtMs: updatedAtMs
        )
    }

    static func proposedThemePreferences(updatedAtMs: Int64 = 3_000) -> ThemePreferencesRecord {
        ThemePreferencesRecord(
            schemaVersion: ThemePreferencesRecord.currentSchemaVersion,
            revision: .proposed,
            selectedThemeId: "app.incomeclock.warm-island",
            preferredThemeAppearance: .system,
            themeSoundsEnabled: false,
            updatedAtMs: updatedAtMs
        )
    }

    static func milliseconds(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

final class ControllableRecordFileStore: RecordFileStore, @unchecked Sendable {
    enum Event: Equatable {
        case commitStarted(String)
        case commitFinished(String)
    }

    private let underlying = AtomicRecordFileStore()
    private let lock = NSLock()
    private var failNextAtomicCommit = false
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func failNextCommit() {
        lock.withLock { failNextAtomicCommit = true }
    }

    func readData(at url: URL) throws -> Data? {
        try underlying.readData(at: url)
    }

    func commitAtomically(_ data: Data, to destinationURL: URL) throws {
        let filename = destinationURL.lastPathComponent
        lock.withLock { recordedEvents.append(.commitStarted(filename)) }
        let shouldFail = lock.withLock { () -> Bool in
            defer { failNextAtomicCommit = false }
            return failNextAtomicCommit
        }
        if shouldFail {
            throw PersistenceError.atomicWriteFailed
        }
        try underlying.commitAtomically(data, to: destinationURL)
        lock.withLock { recordedEvents.append(.commitFinished(filename)) }
    }

    func removeItem(at url: URL) throws {
        try underlying.removeItem(at: url)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }
}

struct FailingAtomicFileReplacer: AtomicFileReplacing {
    func replaceItem(at temporaryURL: URL, withItemAt destinationURL: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        throw PersistenceError.atomicWriteFailed
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
