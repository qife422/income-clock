import Foundation

struct RecordRevision: Hashable, Comparable, Sendable, Codable {
    let rawValue: UInt64

    static let proposed = RecordRevision(rawValue: 0)

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = UInt64(encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "revision must be an unsigned decimal string"
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }

    func next() throws -> Self {
        let result = rawValue.addingReportingOverflow(1)
        guard !result.overflow else {
            throw PersistenceError.revisionOverflow
        }
        return Self(rawValue: result.partialValue)
    }
}

protocol VersionedPersistenceRecord: Codable, Equatable, Sendable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }
    var revision: RecordRevision { get }

    func validated() throws
    func replacingRevision(_ revision: RecordRevision) -> Self
}

enum PanelSnapCorner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct PersistedPanelFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func validated() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else {
            throw RecordValidationError.invalidPanelPlacement
        }
    }
}

struct PanelPlacementRecord: Codable, Equatable, Sendable {
    let displayUUID: String
    let snapCorner: PanelSnapCorner
    let xOffset: Double
    let yOffset: Double
    let constrainedFrame: PersistedPanelFrame

    func validated() throws {
        guard !displayUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              xOffset.isFinite,
              yOffset.isFinite else {
            throw RecordValidationError.invalidPanelPlacement
        }
        try constrainedFrame.validated()
    }
}

struct SettingsRecord: VersionedPersistenceRecord {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: RecordRevision
    let dailyWageCents: Int64
    let workStartMinuteOfDay: Int
    let workEndMinuteOfDay: Int
    let notificationsEnabled: Bool
    let alwaysOnTop: Bool
    let lockPanelPosition: Bool
    let hideInFullScreen: Bool
    let launchAtLogin: Bool
    let panelVisible: Bool
    let panelPlacement: PanelPlacementRecord?
    let updatedAtMs: Int64

    func validated() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RecordValidationError.schemaMismatch
        }
        guard revision.rawValue > 0 else {
            throw RecordValidationError.invalidRevision
        }
        _ = try DailyWageCents(validating: dailyWageCents)
        guard (0...1_439).contains(workStartMinuteOfDay),
              (0...1_439).contains(workEndMinuteOfDay),
              workEndMinuteOfDay > workStartMinuteOfDay else {
            throw RecordValidationError.invalidWorkMinutes
        }
        try panelPlacement?.validated()
    }

    func replacingRevision(_ revision: RecordRevision) -> Self {
        Self(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            dailyWageCents: dailyWageCents,
            workStartMinuteOfDay: workStartMinuteOfDay,
            workEndMinuteOfDay: workEndMinuteOfDay,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: alwaysOnTop,
            lockPanelPosition: lockPanelPosition,
            hideInFullScreen: hideInFullScreen,
            launchAtLogin: launchAtLogin,
            panelVisible: panelVisible,
            panelPlacement: panelPlacement,
            updatedAtMs: updatedAtMs
        )
    }
}

struct PersistedSettingsSnapshot: Codable, Equatable, Sendable {
    let dailyWageCents: Int64
    let workStartMinuteOfDay: Int
    let workEndMinuteOfDay: Int
    let currency: String
    let timeZoneIdentifier: String

    func validated() throws {
        _ = try DailyWageCents(validating: dailyWageCents)
        guard (0...1_439).contains(workStartMinuteOfDay),
              (0...1_439).contains(workEndMinuteOfDay),
              workEndMinuteOfDay > workStartMinuteOfDay else {
            throw RecordValidationError.invalidWorkMinutes
        }
        guard currency == Currency.cny.rawValue else {
            throw RecordValidationError.invalidCurrency
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw RecordValidationError.invalidTimeZone
        }
    }
}

struct TodayRecord: VersionedPersistenceRecord {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: RecordRevision
    let dateKey: String
    let clockInAtMs: Int64
    let clockOutAtMs: Int64?
    let settingsSnapshot: PersistedSettingsSnapshot
    let scheduledStartAtMs: Int64
    let scheduledEndAtMs: Int64
    let notificationScheduledDateKey: String?
    let notificationRequestIdentifier: String?
    let updatedAtMs: Int64

    func validated() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RecordValidationError.schemaMismatch
        }
        guard revision.rawValue > 0 else {
            throw RecordValidationError.invalidRevision
        }
        let key = try WorkdayKey(validating: dateKey)
        try settingsSnapshot.validated()

        let boundaries = try Self.validatedPersistedBoundaries(
            dateKey: key,
            snapshot: settingsSnapshot,
            scheduledStartAtMs: scheduledStartAtMs,
            scheduledEndAtMs: scheduledEndAtMs
        )
        guard clockInAtMs >= boundaries.dayStartAtMs,
              clockInAtMs < boundaries.dayEndExclusiveAtMs,
              clockInAtMs <= scheduledEndAtMs else {
            throw RecordValidationError.timestampOutsideWorkday
        }
        if let clockOutAtMs {
            guard clockOutAtMs >= clockInAtMs else {
                throw RecordValidationError.invalidClockOut
            }
        }

        switch (notificationScheduledDateKey, notificationRequestIdentifier) {
        case (nil, nil):
            break
        case let (.some(notificationDate), .some(identifier)):
            guard notificationDate == dateKey,
                  identifier == "workday-end-\(dateKey)" else {
                throw RecordValidationError.invalidNotificationMarker
            }
        default:
            throw RecordValidationError.invalidNotificationMarker
        }
    }

    func replacingRevision(_ revision: RecordRevision) -> Self {
        Self(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            dateKey: dateKey,
            clockInAtMs: clockInAtMs,
            clockOutAtMs: clockOutAtMs,
            settingsSnapshot: settingsSnapshot,
            scheduledStartAtMs: scheduledStartAtMs,
            scheduledEndAtMs: scheduledEndAtMs,
            notificationScheduledDateKey: notificationScheduledDateKey,
            notificationRequestIdentifier: notificationRequestIdentifier,
            updatedAtMs: updatedAtMs
        )
    }

    private static func validatedPersistedBoundaries(
        dateKey: WorkdayKey,
        snapshot: PersistedSettingsSnapshot,
        scheduledStartAtMs: Int64,
        scheduledEndAtMs: Int64
    ) throws -> (dayStartAtMs: Int64, dayEndExclusiveAtMs: Int64) {
        guard let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) else {
            throw RecordValidationError.invalidTimeZone
        }
        let components = dateKey.rawValue.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else {
            throw RecordValidationError.invalidDateKey
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = DateComponents(
            timeZone: timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        )
        guard let dayStart = calendar.date(from: base),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw RecordValidationError.invalidCalendarBoundary
        }

        guard scheduledStartAtMs < scheduledEndAtMs,
              roundTrips(scheduledStartAtMs, components: components,
                         minuteOfDay: snapshot.workStartMinuteOfDay, calendar: calendar),
              roundTrips(scheduledEndAtMs, components: components,
                         minuteOfDay: snapshot.workEndMinuteOfDay, calendar: calendar),
              scheduledStartAtMs >= milliseconds(dayStart),
              scheduledEndAtMs < milliseconds(dayEnd) else {
            throw RecordValidationError.snapshotBoundaryMismatch
        }
        return (milliseconds(dayStart), milliseconds(dayEnd))
    }

    private static func roundTrips(
        _ milliseconds: Int64,
        components: [Int],
        minuteOfDay: Int,
        calendar: Calendar
    ) -> Bool {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return milliseconds.isMultiple(of: 1_000)
            && actual.year == components[0]
            && actual.month == components[1]
            && actual.day == components[2]
            && actual.hour == minuteOfDay / 60
            && actual.minute == minuteOfDay % 60
            && actual.second == 0
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

enum PreferredThemeAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

struct ThemePreferencesRecord: VersionedPersistenceRecord {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: RecordRevision
    let selectedThemeId: String
    let preferredThemeAppearance: PreferredThemeAppearance
    let themeSoundsEnabled: Bool
    let updatedAtMs: Int64

    func validated() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RecordValidationError.schemaMismatch
        }
        guard revision.rawValue > 0 else {
            throw RecordValidationError.invalidRevision
        }
        guard Self.isValidThemeID(selectedThemeId) else {
            throw RecordValidationError.invalidThemeID
        }
    }

    func replacingRevision(_ revision: RecordRevision) -> Self {
        Self(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            selectedThemeId: selectedThemeId,
            preferredThemeAppearance: preferredThemeAppearance,
            themeSoundsEnabled: themeSoundsEnabled,
            updatedAtMs: updatedAtMs
        )
    }

    private static func isValidThemeID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }

        var previousWasAlphaNumeric = false
        for byte in value.utf8 {
            let isAlphaNumeric = (48...57).contains(byte) || (97...122).contains(byte)
            if isAlphaNumeric {
                previousWasAlphaNumeric = true
            } else if byte == 45 || byte == 46 {
                guard previousWasAlphaNumeric else { return false }
                previousWasAlphaNumeric = false
            } else {
                return false
            }
        }
        return previousWasAlphaNumeric
    }
}

enum RecordValidationError: Error, Equatable, Sendable {
    case schemaMismatch
    case invalidRevision
    case invalidWorkMinutes
    case invalidPanelPlacement
    case invalidCurrency
    case invalidTimeZone
    case invalidDateKey
    case invalidCalendarBoundary
    case snapshotBoundaryMismatch
    case timestampOutsideWorkday
    case invalidClockOut
    case invalidNotificationMarker
    case invalidThemeID
}
