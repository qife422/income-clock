import XCTest
@testable import IncomeClock

final class EarningsCalculatorTests: XCTestCase {
    func testEarlyClockInDoesNotEarnBeforeScheduledStart() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(8),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(milliseconds: 8 * DomainTestFixtures.hour + 30 * 60_000)
            )
        )

        XCTAssertEqual(result.effectiveStartAt, DomainTestFixtures.timestamp(9))
        XCTAssertEqual(result.earnedDuration, .zero)
        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 0)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 0)
        XCTAssertEqual(result.scheduledProgress, 0)
        XCTAssertEqual(result.remainingToStart.rawValue, 30 * 60_000)
    }

    func testEarlyClockInStartsAtScheduleAndStopsAtFullDailyWage() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(8),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(18)
            )
        )

        XCTAssertEqual(result.earnedDuration.rawValue, 9 * DomainTestFixtures.hour)
        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 300_000)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 30_000)
        XCTAssertEqual(result.scheduledProgress, 1)
        XCTAssertEqual(result.remainingToEnd, .zero)
    }

    func testLateClockInProducesContractFinalAmount() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(10),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(18)
            )
        )

        XCTAssertEqual(result.earnedDuration.rawValue, 8 * DomainTestFixtures.hour)
        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 266_667)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 26_667)
        XCTAssertEqual(result.exactEarnedCents.numerator, 30_000 * 8 * DomainTestFixtures.hour)
        XCTAssertEqual(result.exactEarnedCents.denominator, 9 * DomainTestFixtures.hour)
    }

    func testEarlyClockOutUsesActualEnd() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(9),
                clockOutAt: DomainTestFixtures.timestamp(12),
                now: DomainTestFixtures.timestamp(15)
            )
        )

        XCTAssertEqual(result.effectiveEndAt, DomainTestFixtures.timestamp(12))
        XCTAssertEqual(result.earnedDuration.rawValue, 3 * DomainTestFixtures.hour)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 10_000)
    }

    func testClockOutAfterScheduledEndCannotExceedDailyWage() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(8),
                clockOutAt: DomainTestFixtures.timestamp(20),
                now: DomainTestFixtures.timestamp(20)
            )
        )

        XCTAssertEqual(result.effectiveEndAt, DomainTestFixtures.timestamp(18))
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 30_000)
    }

    func testNextDayAndMultiDayClockOutRemainValidAndCapAtDailyWage() throws {
        let settings = try DomainTestFixtures.settings()
        for dayOffset in [Int64(1), Int64(4)] {
            let clockOut = DomainTestFixtures.timestamp(8, dayOffset: dayOffset)
            let result = try EarningsCalculator.calculate(.init(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(9),
                clockOutAt: clockOut,
                now: clockOut
            ))
            XCTAssertEqual(result.effectiveEndAt, DomainTestFixtures.timestamp(18))
            XCTAssertEqual(result.roundedEarnedCents.rawValue, 30_000)
        }
    }

    func testFutureClockInRelativeToNowClampsEarnedDurationToZero() throws {
        let settings = try DomainTestFixtures.settings()
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(10),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(9)
            )
        )

        XCTAssertEqual(result.earnedDuration, .zero)
        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 0)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 0)
    }

    func testLiveAndFinalHalfUpAreCalculatedIndependently() throws {
        let settings = try DomainTestFixtures.settings(
            wageCents: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 1_020
        )
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(milliseconds: 1_000),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(milliseconds: 1_001)
            )
        )

        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 1)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 0)
        XCTAssertEqual(result.exactEarnedCents, try RationalCents(numerator: 1, denominator: 20))
    }

    func testLiveHalfUpBelowBoundaryDoesNotRound() throws {
        let settings = try DomainTestFixtures.settings(
            wageCents: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 1_021
        )
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(milliseconds: 1_000),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(milliseconds: 1_001)
            )
        )

        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 0)
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 0)
    }

    func testFinalCentHalfUpBoundary() throws {
        let settings = try DomainTestFixtures.settings(
            wageCents: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 3_000
        )
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(milliseconds: 1_000),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(milliseconds: 2_000)
            )
        )

        XCTAssertEqual(result.exactEarnedCents, try RationalCents(numerator: 1_000, denominator: 2_000))
        XCTAssertEqual(result.roundedEarnedCents.rawValue, 1)
    }

    func testMaximumWageFullDayIsExactAndDoesNotOverflow() throws {
        let settings = try DomainTestFixtures.settings(wageCents: 99_999_999)
        let result = try EarningsCalculator.calculate(
            EarningsCalculationInput(
                settings: settings,
                clockInAt: DomainTestFixtures.timestamp(9),
                clockOutAt: nil,
                now: DomainTestFixtures.timestamp(18)
            )
        )

        XCTAssertEqual(result.roundedEarnedCents.rawValue, 99_999_999)
        XCTAssertEqual(result.liveEarnedMilliYuan.rawValue, 999_999_990)
    }

    func testLegalBoundaryInputFailsClosedWhenInternalMultiplicationOverflows() throws {
        let dateKey = try WorkdayKey(validating: "2026-08-13")
        let schedule = try WorkdaySchedule(
            dateKey: dateKey,
            dayStartAt: TimestampMilliseconds(rawValue: 0),
            dayEndExclusiveAt: TimestampMilliseconds(rawValue: Int64.max),
            scheduledStartAt: TimestampMilliseconds(rawValue: 1),
            scheduledEndAt: TimestampMilliseconds(rawValue: Int64.max - 1)
        )
        let settings = try WorkdaySettingsSnapshot(
            dailyWage: DailyWageCents(validating: DailyWageCents.maximum),
            schedule: schedule,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let input = EarningsCalculationInput(
            settings: settings,
            clockInAt: schedule.scheduledStartAt,
            clockOutAt: nil,
            now: schedule.scheduledEndAt
        )

        XCTAssertThrowsError(try EarningsCalculator.calculate(input)) { error in
            XCTAssertEqual(error as? EarningsCalculationError, .arithmeticOverflow)
        }
    }

    func testInvalidTimestampRelationshipsFailClosed() throws {
        let settings = try DomainTestFixtures.settings()

        XCTAssertThrowsError(
            try EarningsCalculator.calculate(
                EarningsCalculationInput(
                    settings: settings,
                    clockInAt: DomainTestFixtures.timestamp(19),
                    clockOutAt: nil,
                    now: DomainTestFixtures.timestamp(19)
                )
            )
        ) { error in
            XCTAssertEqual(error as? EarningsCalculationError, .clockInAfterScheduledEnd)
        }

        XCTAssertThrowsError(
            try EarningsCalculator.calculate(
                EarningsCalculationInput(
                    settings: settings,
                    clockInAt: DomainTestFixtures.timestamp(10),
                    clockOutAt: DomainTestFixtures.timestamp(9),
                    now: DomainTestFixtures.timestamp(11)
                )
            )
        ) { error in
            XCTAssertEqual(error as? EarningsCalculationError, .clockOutBeforeClockIn)
        }
    }

    func testSameTimestampInputIsDeterministic() throws {
        let settings = try DomainTestFixtures.settings()
        let input = EarningsCalculationInput(
            settings: settings,
            clockInAt: DomainTestFixtures.timestamp(9),
            clockOutAt: nil,
            now: DomainTestFixtures.timestamp(milliseconds: 12 * DomainTestFixtures.hour + 20_000)
        )

        XCTAssertEqual(try EarningsCalculator.calculate(input), try EarningsCalculator.calculate(input))
    }
}
