import XCTest
@testable import IncomeClock

final class DomainValuesTests: XCTestCase {
    func testDailyWageAcceptsContractBounds() throws {
        XCTAssertEqual(try DailyWageCents(validating: 1).rawValue, 1)
        XCTAssertEqual(try DailyWageCents(validating: 99_999_999).rawValue, 99_999_999)
    }

    func testDailyWageRejectsZeroAndValuesAboveMaximum() {
        XCTAssertThrowsError(try DailyWageCents(validating: 0)) { error in
            XCTAssertEqual(error as? DomainValidationError, .dailyWageOutOfRange)
        }
        XCTAssertThrowsError(try DailyWageCents(validating: 100_000_000)) { error in
            XCTAssertEqual(error as? DomainValidationError, .dailyWageOutOfRange)
        }
    }

    func testWorkdayKeyValidatesCalendarDatesAndLeapYears() throws {
        XCTAssertEqual(try WorkdayKey(validating: "2024-02-29").rawValue, "2024-02-29")
        XCTAssertThrowsError(try WorkdayKey(validating: "2026-02-29"))
        XCTAssertThrowsError(try WorkdayKey(validating: "2026-8-13"))
        XCTAssertThrowsError(try WorkdayKey(validating: "2026-13-01"))
    }

    func testCheckedArithmeticFailsClosedOnOverflow() {
        XCTAssertThrowsError(try CheckedInteger.multiply(Int64.max, 2)) { error in
            XCTAssertEqual(error as? DomainValidationError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try CheckedInteger.subtract(Int64.min, 1)) { error in
            XCTAssertEqual(error as? DomainValidationError, .arithmeticOverflow)
        }
    }

    func testRationalHalfUpUsesIntegerArithmetic() throws {
        XCTAssertEqual(try RationalCents(numerator: 49, denominator: 100).roundedHalfUp(), 0)
        XCTAssertEqual(try RationalCents(numerator: 50, denominator: 100).roundedHalfUp(), 1)
        XCTAssertEqual(try RationalCents(numerator: 149, denominator: 100).roundedHalfUp(), 1)
        XCTAssertEqual(try RationalCents(numerator: 150, denominator: 100).roundedHalfUp(), 2)
    }

    func testScheduleConstructionRejectsOverflowingDayRange() throws {
        let key = try WorkdayKey(validating: "2026-08-13")
        XCTAssertThrowsError(
            try WorkdaySchedule(
                dateKey: key,
                dayStartAt: TimestampMilliseconds(rawValue: Int64.min),
                dayEndExclusiveAt: TimestampMilliseconds(rawValue: Int64.max),
                scheduledStartAt: TimestampMilliseconds(rawValue: Int64.min + 1),
                scheduledEndAt: TimestampMilliseconds(rawValue: Int64.max - 1)
            )
        ) { error in
            XCTAssertEqual(error as? DomainValidationError, .arithmeticOverflow)
        }
    }
}
