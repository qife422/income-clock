import Foundation

enum WorkdayState: String, CaseIterable, Equatable, Sendable {
    case unconfigured = "UNCONFIGURED"
    case ready = "READY"
    case clockedInWaiting = "CLOCKED_IN_WAITING"
    case earning = "EARNING"
    case awaitingClockOut = "AWAITING_CLOCK_OUT"
    case completed = "COMPLETED"
    case recoveryRequired = "RECOVERY_REQUIRED"
}

enum RecoveryReason: String, Equatable, Sendable {
    case unreadableTodayRecord
    case unsupportedTodaySchema
    case invalidTodayDateKey
    case futureDatedTodayRecord
    case missingClockIn
    case missingSettingsSnapshot
    case invalidSettingsSnapshot
    case snapshotDateMismatch
    case clockInAfterScheduledEnd
    case clockOutBeforeClockIn
    case timestampOutsideWorkday
    case timestampAfterNow
}

enum TodayRecordSource: Equatable, Sendable {
    case absent
    case decoded(TodayRecordSnapshot)
    case corrupted(RecoveryReason)
}

enum SettingsSnapshotSource: Equatable, Sendable {
    case missing
    case invalid
    case valid(WorkdaySettingsSnapshot)
}

struct TodayRecordSnapshot: Equatable, Sendable {
    let dateKey: String
    let clockInAt: TimestampMilliseconds?
    let clockOutAt: TimestampMilliseconds?
    let settingsSnapshot: SettingsSnapshotSource
}

struct StateDerivationContext: Equatable, Sendable {
    let currentDateKey: WorkdayKey
    let currentSettings: WorkdaySettingsSnapshot?
    let today: TodayRecordSource
}

enum PreviousDayDisposition: Equatable, Sendable {
    case none
}

struct StateDerivationResult: Equatable, Sendable {
    let state: WorkdayState
    let recoveryReason: RecoveryReason?
    let previousDayDisposition: PreviousDayDisposition

    static func state(
        _ state: WorkdayState,
        previousDayDisposition: PreviousDayDisposition = .none
    ) -> Self {
        Self(
            state: state,
            recoveryReason: nil,
            previousDayDisposition: previousDayDisposition
        )
    }

    static func recovery(_ reason: RecoveryReason) -> Self {
        Self(
            state: .recoveryRequired,
            recoveryReason: reason,
            previousDayDisposition: .none
        )
    }
}
