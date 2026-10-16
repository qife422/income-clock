import Foundation

enum BusinessCalendarError: Error, Equatable, Sendable {
    case invalidTimeZone
    case invalidDate
    case inconsistentSchedule
    case invalidDomainValue
}

enum ScheduleTimeBoundary: String, Equatable, Sendable {
    case start
    case end
}

enum ScheduleTimeError: Error, Equatable, Sendable {
    case nonexistentLocalTime(
        boundary: ScheduleTimeBoundary,
        dateKey: String,
        timeZoneIdentifier: String
    )
    case ambiguousLocalTime(
        boundary: ScheduleTimeBoundary,
        dateKey: String,
        timeZoneIdentifier: String
    )
}

protocol LocalScheduleResolving: Sendable {
    func resolve(
        dateKey: WorkdayKey,
        timeZoneIdentifier: String,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) throws -> WorkdaySchedule
}

struct LocalScheduleResolver: LocalScheduleResolving, Sendable {
    func resolve(
        dateKey: WorkdayKey,
        timeZoneIdentifier: String,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) throws -> WorkdaySchedule {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw BusinessCalendarError.invalidTimeZone
        }
        let parts = dateKey.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw BusinessCalendarError.invalidDate
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try uniqueInstant(
            boundary: .start,
            dateKey: dateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            minuteOfDay: startMinuteOfDay,
            parts: parts,
            calendar: calendar
        )
        let end = try uniqueInstant(
            boundary: .end,
            dateKey: dateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            minuteOfDay: endMinuteOfDay,
            parts: parts,
            calendar: calendar
        )

        let dayStart = calendar.startOfDay(for: start)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw BusinessCalendarError.invalidDate
        }
        do {
            return try WorkdaySchedule(
                dateKey: dateKey,
                dayStartAt: Self.timestamp(from: dayStart),
                dayEndExclusiveAt: Self.timestamp(from: dayEnd),
                scheduledStartAt: Self.timestamp(from: start),
                scheduledEndAt: Self.timestamp(from: end)
            )
        } catch {
            throw BusinessCalendarError.invalidDomainValue
        }
    }

    private func uniqueInstant(
        boundary: ScheduleTimeBoundary,
        dateKey: WorkdayKey,
        timeZoneIdentifier: String,
        minuteOfDay: Int,
        parts: [Int],
        calendar: Calendar
    ) throws -> Date {
        let target = DateComponents(
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0
        )
        let reference = Self.utcReferenceDate(parts: parts)
        let searchStart = reference.addingTimeInterval(-36 * 60 * 60)
        let first = calendar.nextDate(
            after: searchStart,
            matching: target,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward
        )
        let last = calendar.nextDate(
            after: searchStart,
            matching: target,
            matchingPolicy: .strict,
            repeatedTimePolicy: .last,
            direction: .forward
        )
        let candidates = [first, last]
            .compactMap { $0 }
            .filter { Self.roundTrips($0, to: target, calendar: calendar) }
        let uniqueCandidates = Array(Set(candidates.map(\.timeIntervalSinceReferenceDate)))

        guard !uniqueCandidates.isEmpty else {
            throw ScheduleTimeError.nonexistentLocalTime(
                boundary: boundary,
                dateKey: dateKey.rawValue,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        guard uniqueCandidates.count == 1,
              let instant = candidates.first else {
            throw ScheduleTimeError.ambiguousLocalTime(
                boundary: boundary,
                dateKey: dateKey.rawValue,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        return instant
    }

    private static func roundTrips(
        _ date: Date,
        to target: DateComponents,
        calendar: Calendar
    ) -> Bool {
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return actual.year == target.year
            && actual.month == target.month
            && actual.day == target.day
            && actual.hour == target.hour
            && actual.minute == target.minute
            && actual.second == 0
    }

    private static func utcReferenceDate(parts: [Int]) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(
            timeZone: utc.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 12
        ))!
    }

    private static func timestamp(from date: Date) -> TimestampMilliseconds {
        TimestampMilliseconds(rawValue: Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

struct BusinessWorkdayCalendar: Sendable {
    let timeZoneIdentifier: String
    private let scheduleResolver: any LocalScheduleResolving
    private let settingsParsingObserver: @Sendable () -> Void

    init(
        timeZoneIdentifier: String,
        scheduleResolver: any LocalScheduleResolving = LocalScheduleResolver(),
        settingsParsingObserver: @escaping @Sendable () -> Void = {}
    ) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw BusinessCalendarError.invalidTimeZone
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        self.scheduleResolver = scheduleResolver
        self.settingsParsingObserver = settingsParsingObserver
    }

    func currentDateKey(at timestamp: TimestampMilliseconds) throws -> WorkdayKey {
        try dateKey(at: timestamp, timeZoneIdentifier: timeZoneIdentifier)
    }

    func dateKey(
        at timestamp: TimestampMilliseconds,
        timeZoneIdentifier: String
    ) throws -> WorkdayKey {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw BusinessCalendarError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: Self.date(from: timestamp)
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let key = try? WorkdayKey(
                  validating: String(format: "%04d-%02d-%02d", year, month, day)
              ) else {
            throw BusinessCalendarError.invalidDate
        }
        return key
    }

    func settingsSnapshot(
        from record: SettingsRecord,
        for dateKey: WorkdayKey
    ) throws -> WorkdaySettingsSnapshot {
        try settingsSnapshot(
            from: record,
            for: dateKey,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func settingsSnapshot(
        from record: SettingsRecord,
        for dateKey: WorkdayKey,
        timeZoneIdentifier: String
    ) throws -> WorkdaySettingsSnapshot {
        settingsParsingObserver()
        return try makeSettingsSnapshot(
            dateKey: dateKey,
            dailyWageCents: record.dailyWageCents,
            startMinute: record.workStartMinuteOfDay,
            endMinute: record.workEndMinuteOfDay,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func todaySnapshot(from record: TodayRecord) throws -> TodayRecordSnapshot {
        settingsParsingObserver()
        let dateKey: WorkdayKey
        do {
            dateKey = try WorkdayKey(validating: record.dateKey)
        } catch {
            throw BusinessCalendarError.invalidDate
        }
        let persisted = try persistedSchedule(
            dateKey: dateKey,
            timeZoneIdentifier: record.settingsSnapshot.timeZoneIdentifier,
            startMinute: record.settingsSnapshot.workStartMinuteOfDay,
            endMinute: record.settingsSnapshot.workEndMinuteOfDay,
            scheduledStartAt: .init(rawValue: record.scheduledStartAtMs),
            scheduledEndAt: .init(rawValue: record.scheduledEndAtMs)
        )
        let settings: WorkdaySettingsSnapshot
        do {
            settings = try WorkdaySettingsSnapshot(
                dailyWage: DailyWageCents(validating: record.settingsSnapshot.dailyWageCents),
                schedule: persisted,
                currency: .cny,
                timeZoneIdentifier: record.settingsSnapshot.timeZoneIdentifier
            )
        } catch {
            throw BusinessCalendarError.invalidDomainValue
        }
        guard settings.schedule.scheduledStartAt.rawValue == record.scheduledStartAtMs,
              settings.schedule.scheduledEndAt.rawValue == record.scheduledEndAtMs else {
            throw BusinessCalendarError.inconsistentSchedule
        }
        return TodayRecordSnapshot(
            dateKey: record.dateKey,
            clockInAt: TimestampMilliseconds(rawValue: record.clockInAtMs),
            clockOutAt: record.clockOutAtMs.map(TimestampMilliseconds.init(rawValue:)),
            settingsSnapshot: .valid(settings)
        )
    }

    func proposedToday(
        from settings: SettingsRecord,
        at now: TimestampMilliseconds
    ) throws -> TodayRecord {
        let context = BusinessCommandContext(
            commandID: UUID(),
            timestampMs: now,
            commandTimeZoneIdentifier: timeZoneIdentifier,
            commandDateKey: try currentDateKey(at: now)
        )
        return try proposedToday(from: settings, context: context)
    }

    func proposedToday(
        from settings: SettingsRecord,
        context: BusinessCommandContext
    ) throws -> TodayRecord {
        let dateKey = context.commandDateKey
        let domainSettings = try settingsSnapshot(
            from: settings,
            for: dateKey,
            timeZoneIdentifier: context.commandTimeZoneIdentifier
        )
        return TodayRecord(
            schemaVersion: TodayRecord.currentSchemaVersion,
            revision: .proposed,
            dateKey: dateKey.rawValue,
            clockInAtMs: context.timestampMs.rawValue,
            clockOutAtMs: nil,
            settingsSnapshot: PersistedSettingsSnapshot(
                dailyWageCents: settings.dailyWageCents,
                workStartMinuteOfDay: settings.workStartMinuteOfDay,
                workEndMinuteOfDay: settings.workEndMinuteOfDay,
                currency: Currency.cny.rawValue,
                timeZoneIdentifier: context.commandTimeZoneIdentifier
            ),
            scheduledStartAtMs: domainSettings.schedule.scheduledStartAt.rawValue,
            scheduledEndAtMs: domainSettings.schedule.scheduledEndAt.rawValue,
            notificationScheduledDateKey: nil,
            notificationRequestIdentifier: nil,
            updatedAtMs: context.timestampMs.rawValue
        )
    }

    private func makeSettingsSnapshot(
        dateKey: WorkdayKey,
        dailyWageCents: Int64,
        startMinute: Int,
        endMinute: Int,
        timeZoneIdentifier: String
    ) throws -> WorkdaySettingsSnapshot {
        let schedule = try scheduleResolver.resolve(
            dateKey: dateKey,
            timeZoneIdentifier: timeZoneIdentifier,
            startMinuteOfDay: startMinute,
            endMinuteOfDay: endMinute
        )
        do {
            return try WorkdaySettingsSnapshot(
                dailyWage: DailyWageCents(validating: dailyWageCents),
                schedule: schedule,
                currency: .cny,
                timeZoneIdentifier: timeZoneIdentifier
            )
        } catch {
            throw BusinessCalendarError.invalidDomainValue
        }
    }

    /// Restores an already-frozen Today schedule without invoking the local-time resolver.
    /// The persisted instants are authoritative; validation only proves that they round-trip
    /// to the persisted date/minutes in the persisted timezone.
    private func persistedSchedule(
        dateKey: WorkdayKey,
        timeZoneIdentifier: String,
        startMinute: Int,
        endMinute: Int,
        scheduledStartAt: TimestampMilliseconds,
        scheduledEndAt: TimestampMilliseconds
    ) throws -> WorkdaySchedule {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw BusinessCalendarError.invalidTimeZone
        }
        let parts = dateKey.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw BusinessCalendarError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = DateComponents(timeZone: timeZone, year: parts[0], month: parts[1], day: parts[2])
        guard let dayStart = calendar.date(from: base),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              Self.roundTrips(scheduledStartAt, dateKey: dateKey, minuteOfDay: startMinute,
                              calendar: calendar),
              Self.roundTrips(scheduledEndAt, dateKey: dateKey, minuteOfDay: endMinute,
                              calendar: calendar) else {
            throw BusinessCalendarError.inconsistentSchedule
        }
        do {
            return try WorkdaySchedule(
                dateKey: dateKey,
                dayStartAt: Self.timestamp(from: dayStart),
                dayEndExclusiveAt: Self.timestamp(from: dayEnd),
                scheduledStartAt: scheduledStartAt,
                scheduledEndAt: scheduledEndAt
            )
        } catch {
            throw BusinessCalendarError.inconsistentSchedule
        }
    }

    private static func roundTrips(
        _ timestamp: TimestampMilliseconds,
        dateKey: WorkdayKey,
        minuteOfDay: Int,
        calendar: Calendar
    ) -> Bool {
        let parts = dateKey.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date(from: timestamp)
        )
        return timestamp.rawValue.isMultiple(of: 1_000)
            && actual.year == parts[0]
            && actual.month == parts[1]
            && actual.day == parts[2]
            && actual.hour == minuteOfDay / 60
            && actual.minute == minuteOfDay % 60
            && actual.second == 0
    }

    private static func date(from timestamp: TimestampMilliseconds) -> Date {
        Date(timeIntervalSince1970: Double(timestamp.rawValue) / 1_000)
    }

    private static func timestamp(from date: Date) -> TimestampMilliseconds {
        TimestampMilliseconds(rawValue: Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

}
