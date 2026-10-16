import XCTest
@testable import IncomeClock

final class StateDeriverTests: XCTestCase {
    func testAllSevenStatesAreRepresented() {
        XCTAssertEqual(Set(WorkdayState.allCases).count, 7)
    }

    func testUnconfiguredWhenSettingsAndTodayAreAbsent() {
        let result = derive(settings: nil, today: .absent, now: DomainTestFixtures.timestamp(8))
        XCTAssertEqual(result.state, .unconfigured)
    }

    func testReadyWhenCurrentSettingsExistWithoutToday() throws {
        let result = derive(
            settings: try DomainTestFixtures.settings(),
            today: .absent,
            now: DomainTestFixtures.timestamp(8)
        )
        XCTAssertEqual(result.state, .ready)
    }

    func testEarlyClockInWaitsUntilScheduledStartBoundary() throws {
        let settings = try DomainTestFixtures.settings()
        let today = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.currentDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(8),
            clockOutAt: nil,
            settingsSnapshot: .valid(settings)
        )

        XCTAssertEqual(
            derive(settings: settings, today: .decoded(today), now: DomainTestFixtures.timestamp(milliseconds: 8 * DomainTestFixtures.hour + 59 * 60_000)).state,
            .clockedInWaiting
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(today), now: DomainTestFixtures.timestamp(9)).state,
            .earning
        )
    }

    func testScheduledEndBoundaryTransitionsToAwaitingClockOut() throws {
        let settings = try DomainTestFixtures.settings()
        let today = DomainTestFixtures.today(settings: .valid(settings))

        XCTAssertEqual(
            derive(settings: settings, today: .decoded(today), now: DomainTestFixtures.timestamp(milliseconds: 18 * DomainTestFixtures.hour - 1)).state,
            .earning
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(today), now: DomainTestFixtures.timestamp(18)).state,
            .awaitingClockOut
        )
    }

    func testClockOutProducesCompletedBeforeOrAfterScheduledEnd() throws {
        let settings = try DomainTestFixtures.settings()
        let early = DomainTestFixtures.today(
            clockInAt: DomainTestFixtures.timestamp(9),
            clockOutAt: DomainTestFixtures.timestamp(12),
            settings: .valid(settings)
        )
        let late = DomainTestFixtures.today(
            clockInAt: DomainTestFixtures.timestamp(9),
            clockOutAt: DomainTestFixtures.timestamp(20),
            settings: .valid(settings)
        )

        XCTAssertEqual(derive(settings: settings, today: .decoded(early), now: DomainTestFixtures.timestamp(12)).state, .completed)
        XCTAssertEqual(derive(settings: settings, today: .decoded(late), now: DomainTestFixtures.timestamp(20)).state, .completed)
    }

    func testCorruptedAndMissingFieldsRequireRecovery() throws {
        let settings = try DomainTestFixtures.settings()
        XCTAssertEqual(
            derive(settings: settings, today: .corrupted(.unreadableTodayRecord), now: DomainTestFixtures.timestamp(10)).recoveryReason,
            .unreadableTodayRecord
        )

        let missingClockIn = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.currentDateKey.rawValue,
            clockInAt: nil,
            clockOutAt: nil,
            settingsSnapshot: .valid(settings)
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(missingClockIn), now: DomainTestFixtures.timestamp(10)).recoveryReason,
            .missingClockIn
        )

        let missingSnapshot = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.currentDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(9),
            clockOutAt: nil,
            settingsSnapshot: .missing
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(missingSnapshot), now: DomainTestFixtures.timestamp(10)).recoveryReason,
            .missingSettingsSnapshot
        )

        let invalidSnapshot = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.currentDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(9),
            clockOutAt: nil,
            settingsSnapshot: .invalid
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(invalidSnapshot), now: DomainTestFixtures.timestamp(10)).recoveryReason,
            .invalidSettingsSnapshot
        )
    }

    func testInvalidTimestampRelationshipsRequireRecovery() throws {
        let settings = try DomainTestFixtures.settings()
        let clockInAfterEnd = DomainTestFixtures.today(
            clockInAt: DomainTestFixtures.timestamp(19),
            settings: .valid(settings)
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(clockInAfterEnd), now: DomainTestFixtures.timestamp(19)).recoveryReason,
            .clockInAfterScheduledEnd
        )

        let clockOutBeforeClockIn = DomainTestFixtures.today(
            clockInAt: DomainTestFixtures.timestamp(10),
            clockOutAt: DomainTestFixtures.timestamp(9),
            settings: .valid(settings)
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(clockOutBeforeClockIn), now: DomainTestFixtures.timestamp(11)).recoveryReason,
            .clockOutBeforeClockIn
        )

        let outsideDay = DomainTestFixtures.today(
            clockInAt: TimestampMilliseconds(rawValue: -1),
            settings: .valid(settings)
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(outsideDay), now: DomainTestFixtures.timestamp(10)).recoveryReason,
            .timestampOutsideWorkday
        )

        let afterNow = DomainTestFixtures.today(
            clockInAt: DomainTestFixtures.timestamp(10),
            settings: .valid(settings)
        )
        XCTAssertEqual(
            derive(settings: settings, today: .decoded(afterNow), now: DomainTestFixtures.timestamp(9)).recoveryReason,
            .timestampAfterNow
        )
    }

    func testValidatedCompletedPreviousDayIsRetainedUntilExplicitStartToday() throws {
        let currentSettings = try DomainTestFixtures.settings()
        let previousSettings = try DomainTestFixtures.settings(
            dateKey: DomainTestFixtures.previousDateKey,
            dayOffset: -1
        )
        let previousToday = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.previousDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(9, dayOffset: -1),
            clockOutAt: DomainTestFixtures.timestamp(18, dayOffset: -1),
            settingsSnapshot: .valid(previousSettings)
        )

        let result = derive(
            settings: currentSettings,
            today: .decoded(previousToday),
            now: DomainTestFixtures.timestamp(8)
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.previousDayDisposition, .none)
    }

    func testValidatedIncompletePreviousDayIsRetainedWithoutCurrentSettings() throws {
        let previousSettings = try DomainTestFixtures.settings(
            dateKey: DomainTestFixtures.previousDateKey,
            dayOffset: -1
        )
        let previousToday = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.previousDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(9, dayOffset: -1),
            clockOutAt: nil,
            settingsSnapshot: .valid(previousSettings)
        )

        let result = derive(settings: nil, today: .decoded(previousToday), now: DomainTestFixtures.timestamp(8))
        XCTAssertEqual(result.state, .awaitingClockOut)
        XCTAssertEqual(result.previousDayDisposition, .none)
    }

    func testDamagedPreviousDayIsNotAutomaticallyDiscarded() throws {
        let previousSettings = try DomainTestFixtures.settings(
            dateKey: DomainTestFixtures.previousDateKey,
            dayOffset: -1
        )
        let damaged = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.previousDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(19, dayOffset: -1),
            clockOutAt: nil,
            settingsSnapshot: .valid(previousSettings)
        )

        let result = derive(
            settings: try DomainTestFixtures.settings(),
            today: .decoded(damaged),
            now: DomainTestFixtures.timestamp(8)
        )
        XCTAssertEqual(result.state, .recoveryRequired)
        XCTAssertEqual(result.previousDayDisposition, .none)
    }

    func testFutureDatedRecordRequiresRecovery() throws {
        let futureSettings = try DomainTestFixtures.settings(
            dateKey: DomainTestFixtures.futureDateKey,
            dayOffset: 1
        )
        let future = TodayRecordSnapshot(
            dateKey: DomainTestFixtures.futureDateKey.rawValue,
            clockInAt: DomainTestFixtures.timestamp(9, dayOffset: 1),
            clockOutAt: nil,
            settingsSnapshot: .valid(futureSettings)
        )
        let result = derive(
            settings: try DomainTestFixtures.settings(),
            today: .decoded(future),
            now: DomainTestFixtures.timestamp(8)
        )
        XCTAssertEqual(result.recoveryReason, .futureDatedTodayRecord)
    }

    func testFixedClockMakesStateDerivationDeterministic() throws {
        let settings = try DomainTestFixtures.settings()
        let context = StateDerivationContext(
            currentDateKey: DomainTestFixtures.currentDateKey,
            currentSettings: settings,
            today: .decoded(DomainTestFixtures.today(settings: .valid(settings)))
        )
        let clock = FixedClock(instant: DomainTestFixtures.timestamp(12))

        XCTAssertEqual(
            StateDeriver.derive(context: context, nowProvider: clock),
            StateDeriver.derive(context: context, nowProvider: clock)
        )
        XCTAssertEqual(StateDeriver.derive(context: context, nowProvider: clock).state, .earning)
    }

    private func derive(
        settings: WorkdaySettingsSnapshot?,
        today: TodayRecordSource,
        now: TimestampMilliseconds
    ) -> StateDerivationResult {
        StateDeriver.derive(
            context: StateDerivationContext(
                currentDateKey: DomainTestFixtures.currentDateKey,
                currentSettings: settings,
                today: today
            ),
            nowProvider: FixedClock(instant: now)
        )
    }
}
