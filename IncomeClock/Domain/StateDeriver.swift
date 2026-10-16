import Foundation

enum StateDeriver {
    static func derive(
        context: StateDerivationContext,
        nowProvider: any NowProvider
    ) -> StateDerivationResult {
        let now = nowProvider.nowMilliseconds()
        return derive(context: context, now: now)
    }

    static func derive(
        context: StateDerivationContext,
        now: TimestampMilliseconds
    ) -> StateDerivationResult {
        switch context.today {
        case .absent:
            return stateWithoutToday(context: context)
        case let .corrupted(reason):
            return .recovery(reason)
        case let .decoded(record):
            return deriveDecodedRecord(record, context: context, now: now)
        }
    }

    private static func stateWithoutToday(
        context: StateDerivationContext,
        previousDayDisposition: PreviousDayDisposition = .none
    ) -> StateDerivationResult {
        guard let settings = context.currentSettings,
              settings.schedule.dateKey == context.currentDateKey else {
            return .state(.unconfigured, previousDayDisposition: previousDayDisposition)
        }
        return .state(.ready, previousDayDisposition: previousDayDisposition)
    }

    private static func deriveDecodedRecord(
        _ record: TodayRecordSnapshot,
        context: StateDerivationContext,
        now: TimestampMilliseconds
    ) -> StateDerivationResult {
        guard let recordDateKey = try? WorkdayKey(validating: record.dateKey) else {
            return .recovery(.invalidTodayDateKey)
        }
        guard recordDateKey <= context.currentDateKey else {
            return .recovery(.futureDatedTodayRecord)
        }
        guard let clockInAt = record.clockInAt else {
            return .recovery(.missingClockIn)
        }

        let settings: WorkdaySettingsSnapshot
        switch record.settingsSnapshot {
        case .missing:
            return .recovery(.missingSettingsSnapshot)
        case .invalid:
            return .recovery(.invalidSettingsSnapshot)
        case let .valid(value):
            settings = value
        }

        let schedule = settings.schedule
        guard schedule.dateKey == recordDateKey else {
            return .recovery(.snapshotDateMismatch)
        }
        guard schedule.contains(clockInAt) else {
            return .recovery(.timestampOutsideWorkday)
        }
        guard clockInAt <= schedule.scheduledEndAt else {
            return .recovery(.clockInAfterScheduledEnd)
        }
        if let clockOutAt = record.clockOutAt, clockOutAt < clockInAt {
            return .recovery(.clockOutBeforeClockIn)
        }

        if recordDateKey < context.currentDateKey {
            return .state(record.clockOutAt == nil ? .awaitingClockOut : .completed)
        }

        guard clockInAt <= now else {
            return .recovery(.timestampAfterNow)
        }

        if record.clockOutAt != nil {
            return .state(.completed)
        }
        if now < schedule.scheduledStartAt {
            return .state(.clockedInWaiting)
        }
        if now < schedule.scheduledEndAt {
            return .state(.earning)
        }
        return .state(.awaitingClockOut)
    }
}
