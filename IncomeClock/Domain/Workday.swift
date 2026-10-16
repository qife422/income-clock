import Foundation

struct WorkdayKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(validating rawValue: String) throws {
        let scalars = Array(rawValue.unicodeScalars)
        guard scalars.count == 10,
              scalars[4].value == 45,
              scalars[7].value == 45,
              scalars.enumerated().allSatisfy({ index, scalar in
                  index == 4 || index == 7 || (48...57).contains(scalar.value)
              }) else {
            throw DomainValidationError.invalidWorkdayKey
        }

        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...Self.daysInMonth(year: year, month: month)).contains(day) else {
            throw DomainValidationError.invalidWorkdayKey
        }

        self.rawValue = rawValue
    }

    var description: String { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let isLeap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}

struct WorkdaySchedule: Equatable, Sendable {
    let dateKey: WorkdayKey
    let dayStartAt: TimestampMilliseconds
    let dayEndExclusiveAt: TimestampMilliseconds
    let scheduledStartAt: TimestampMilliseconds
    let scheduledEndAt: TimestampMilliseconds

    init(
        dateKey: WorkdayKey,
        dayStartAt: TimestampMilliseconds,
        dayEndExclusiveAt: TimestampMilliseconds,
        scheduledStartAt: TimestampMilliseconds,
        scheduledEndAt: TimestampMilliseconds
    ) throws {
        guard dayStartAt < dayEndExclusiveAt else {
            throw DomainValidationError.invalidDayBounds
        }
        _ = try CheckedInteger.subtract(dayEndExclusiveAt.rawValue, dayStartAt.rawValue)

        guard scheduledStartAt >= dayStartAt,
              scheduledStartAt < scheduledEndAt,
              scheduledEndAt < dayEndExclusiveAt else {
            throw DomainValidationError.invalidScheduleBounds
        }
        _ = try CheckedInteger.subtract(scheduledEndAt.rawValue, scheduledStartAt.rawValue)

        self.dateKey = dateKey
        self.dayStartAt = dayStartAt
        self.dayEndExclusiveAt = dayEndExclusiveAt
        self.scheduledStartAt = scheduledStartAt
        self.scheduledEndAt = scheduledEndAt
    }

    var scheduledDuration: DurationMilliseconds {
        get throws {
            try DurationMilliseconds(
                validating: CheckedInteger.subtract(scheduledEndAt.rawValue, scheduledStartAt.rawValue)
            )
        }
    }

    func contains(_ timestamp: TimestampMilliseconds) -> Bool {
        timestamp >= dayStartAt && timestamp < dayEndExclusiveAt
    }
}

enum Currency: String, Equatable, Sendable {
    case cny = "CNY"
}

struct WorkdaySettingsSnapshot: Equatable, Sendable {
    let dailyWage: DailyWageCents
    let schedule: WorkdaySchedule
    let currency: Currency
    let timeZoneIdentifier: String

    init(
        dailyWage: DailyWageCents,
        schedule: WorkdaySchedule,
        currency: Currency = .cny,
        timeZoneIdentifier: String
    ) throws {
        guard !timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyTimeZoneIdentifier
        }
        self.dailyWage = dailyWage
        self.schedule = schedule
        self.currency = currency
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
