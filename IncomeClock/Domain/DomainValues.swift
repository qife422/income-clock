import Foundation

struct TimestampMilliseconds: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: Int64

    init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DurationMilliseconds: Hashable, Comparable, Sendable {
    let rawValue: Int64

    init(validating rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeDuration
        }
        self.rawValue = rawValue
    }

    static let zero = try! DurationMilliseconds(validating: 0)

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DailyWageCents: Hashable, Comparable, Sendable {
    static let minimum: Int64 = 1
    static let maximum: Int64 = 99_999_999

    let rawValue: Int64

    init(validating rawValue: Int64) throws {
        guard Self.minimum...Self.maximum ~= rawValue else {
            throw DomainValidationError.dailyWageOutOfRange
        }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LiveEarnedMilliYuan: Hashable, Comparable, Sendable {
    let rawValue: Int64

    init(validating rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeMoney
        }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct RoundedEarnedCents: Hashable, Comparable, Sendable {
    let rawValue: Int64

    init(validating rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeMoney
        }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct RationalCents: Equatable, Sendable {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) throws {
        guard numerator >= 0 else {
            throw DomainValidationError.negativeMoney
        }
        guard denominator > 0 else {
            throw DomainValidationError.nonPositiveDenominator
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    func roundedHalfUp() throws -> Int64 {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let threshold = denominator / 2 + denominator % 2
        guard remainder >= threshold else {
            return quotient
        }
        return try CheckedInteger.add(quotient, 1)
    }
}

enum DomainValidationError: Error, Equatable, Sendable {
    case dailyWageOutOfRange
    case negativeDuration
    case negativeMoney
    case nonPositiveDenominator
    case invalidWorkdayKey
    case invalidDayBounds
    case invalidScheduleBounds
    case emptyTimeZoneIdentifier
    case arithmeticOverflow
}

enum CheckedInteger {
    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw DomainValidationError.arithmeticOverflow
        }
        return result.partialValue
    }

    static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw DomainValidationError.arithmeticOverflow
        }
        return result.partialValue
    }

    static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw DomainValidationError.arithmeticOverflow
        }
        return result.partialValue
    }
}
