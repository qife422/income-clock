import XCTest
@testable import IncomeClock

enum DomainTestFixtures {
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 24 * hour

    static let currentDateKey = try! WorkdayKey(validating: "2026-08-13")
    static let previousDateKey = try! WorkdayKey(validating: "2026-08-12")
    static let futureDateKey = try! WorkdayKey(validating: "2026-08-14")

    static func timestamp(_ hours: Int64, dayOffset: Int64 = 0) -> TimestampMilliseconds {
        TimestampMilliseconds(rawValue: dayOffset * day + hours * hour)
    }

    static func timestamp(milliseconds: Int64, dayOffset: Int64 = 0) -> TimestampMilliseconds {
        TimestampMilliseconds(rawValue: dayOffset * day + milliseconds)
    }

    static func settings(
        dateKey: WorkdayKey = currentDateKey,
        dayOffset: Int64 = 0,
        wageCents: Int64 = 30_000,
        startMilliseconds: Int64 = 9 * hour,
        endMilliseconds: Int64 = 18 * hour
    ) throws -> WorkdaySettingsSnapshot {
        let dayStart = dayOffset * day
        let schedule = try WorkdaySchedule(
            dateKey: dateKey,
            dayStartAt: TimestampMilliseconds(rawValue: dayStart),
            dayEndExclusiveAt: TimestampMilliseconds(rawValue: dayStart + day),
            scheduledStartAt: TimestampMilliseconds(rawValue: dayStart + startMilliseconds),
            scheduledEndAt: TimestampMilliseconds(rawValue: dayStart + endMilliseconds)
        )
        return try WorkdaySettingsSnapshot(
            dailyWage: DailyWageCents(validating: wageCents),
            schedule: schedule,
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }

    static func today(
        dateKey: WorkdayKey = currentDateKey,
        clockInAt: TimestampMilliseconds? = timestamp(9),
        clockOutAt: TimestampMilliseconds? = nil,
        settings: SettingsSnapshotSource? = nil
    ) -> TodayRecordSnapshot {
        TodayRecordSnapshot(
            dateKey: dateKey.rawValue,
            clockInAt: clockInAt,
            clockOutAt: clockOutAt,
            settingsSnapshot: settings ?? .valid(try! self.settings())
        )
    }
}
