import Foundation
import XCTest
@testable import IncomeClock

@MainActor
final class BusinessStoreTests: XCTestCase {
    func testScheduleErrorEntryMatrixPreservesRecordsAndSupportsFailedThenSuccessfulRetry() async throws {
        // T-015: each entry exercises the real restore/refresh route for both DST errors.
        for fold in [false, true] {
            for entry in ["restore", "refresh", "cross-day", "timezone-change"] {
                let zone = "America/New_York"
                let month = fold ? 11 : 3
                let day = fold ? 1 : 8
                let badStart = fold ? 90 : 150
                let settings = ApplicationTestSupport.proposedSettings(
                    startMinuteOfDay: badStart, endMinuteOfDay: 4 * 60
                ).replacingRevision(.init(rawValue: 1))
                let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
                let errorInstant = ApplicationTestSupport.timestamp(
                    timeZoneIdentifier: zone, year: 2026, month: month, day: day, hour: 12
                )
                let clock = MutableTestClock(entry == "cross-day"
                    ? .init(rawValue: errorInstant.rawValue - 86_400_000) : errorInstant)
                let zones = MutableTestTimeZoneIdentifierProvider(entry == "timezone-change" ? "UTC" : zone)
                let store = try BusinessStore(repository: repository, nowProvider: clock,
                    timeZoneIdentifierProvider: zones)
                let originalBytes = try await repository.currentSettingsCanonicalBytes()
                await store.restore()
                if entry == "cross-day" || entry == "timezone-change" {
                    XCTAssertNotNil(store.viewState, entry)
                    XCTAssertNil(store.scheduleTimeErrorViewState, entry)
                    clock.set(errorInstant)
                    zones.set(zone)
                    await store.refresh()
                } else if entry == "refresh" {
                    await store.refresh()
                }
                XCTAssertFalse(store.isRestoring, entry)
                XCTAssertFalse(store.isCommandInFlight, entry)
                XCTAssertNil(store.viewState, entry)
                XCTAssertEqual(store.scheduleTimeErrorViewState?.context, .activeSchedule, entry)
                XCTAssertTrue(store.hasBlockingScheduleError, entry)
                let expectedError: ScheduleTimeError = fold
                    ? .ambiguousLocalTime(boundary: .start, dateKey: "2026-11-01", timeZoneIdentifier: zone)
                    : .nonexistentLocalTime(boundary: .start, dateKey: "2026-03-08", timeZoneIdentifier: zone)
                XCTAssertEqual(store.scheduleTimeErrorViewState?.error, expectedError, entry)
                XCTAssertNil(store.feedback, entry)
                let failedRetry = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(
                    startMinuteOfDay: badStart + 15, endMinuteOfDay: 4 * 60)), source: .settings)
                XCTAssertEqual(failedRetry, .failed(.scheduleTime(expectedError)), entry)
                XCTAssertNil(store.viewState, entry)
                XCTAssertNil(store.feedback, entry)
                XCTAssertFalse(store.isCommandInFlight, entry)
                let draftError = try XCTUnwrap(store.scheduleTimeErrorViewState)
                XCTAssertEqual(draftError.context, .proposedSettings, entry)
                XCTAssertEqual(draftError.error, expectedError, entry)
                XCTAssertTrue(store.hasBlockingScheduleError, entry)
                for _ in 0..<3 {
                    // Committed Settings are also invalid, so this refresh must
                    // exercise reconcile's throwing path rather than success.
                    await store.refresh()
                    XCTAssertEqual(store.scheduleTimeErrorViewState, draftError, entry)
                    XCTAssertTrue(store.hasBlockingScheduleError, entry)
                    XCTAssertNil(store.viewState, entry)
                    XCTAssertNil(store.confirmation, entry)
                    XCTAssertNil(store.feedback, entry)
                    let bytesAfterRefresh = try await repository.currentSettingsCanonicalBytes()
                    let todayAfterRefresh = await repository.currentToday()
                    XCTAssertEqual(bytesAfterRefresh, originalBytes, entry)
                    XCTAssertNil(todayAfterRefresh, entry)
                }
                let preservedBytes = try await repository.currentSettingsCanonicalBytes()
                let preservedRecord = await repository.currentSettings()
                let saveCount = await repository.settingsSaveCount
                let temporaryWrites = await repository.settingsTemporaryWriteCount
                let todaySaves = await repository.todaySaveCount
                let todayDeletes = await repository.resetTodayCount
                XCTAssertEqual(preservedBytes, originalBytes, entry)
                XCTAssertEqual(preservedRecord, settings, entry)
                XCTAssertEqual(saveCount, 0, entry)
                XCTAssertEqual(temporaryWrites, 0, entry)
                XCTAssertEqual(todaySaves, 0, entry)
                XCTAssertEqual(todayDeletes, 0, entry)
                let success = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(
                    startMinuteOfDay: 4 * 60, endMinuteOfDay: 5 * 60)), source: .settings)
                XCTAssertEqual(success, .committed, entry)
                XCTAssertEqual(store.viewState?.state, .ready, entry)
                XCTAssertNil(store.scheduleTimeErrorViewState, entry)
                XCTAssertFalse(store.hasBlockingScheduleError, entry)
                XCTAssertFalse(store.isRestoring, entry)
                XCTAssertFalse(store.isCommandInFlight, entry)
                XCTAssertNotNil(store.feedback, entry)
                let finalWrites = await repository.settingsSuccessfulWriteCount
                let finalRecord = await repository.currentSettings()
                XCTAssertEqual(finalWrites, 1, entry)
                XCTAssertEqual(finalRecord?.revision, .init(rawValue: 2), entry)
            }
        }
    }

    func testRestorePublishesNoFakeStateBeforeLoadingAndThenUnconfigured() async throws {
        let repository = BusinessRecordRepositorySpy()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        let store = try makeStore(repository: repository, clock: clock)

        XCTAssertNil(store.viewState)
        await store.restore()

        XCTAssertEqual(store.viewState?.state, .unconfigured)
        XCTAssertEqual(store.viewState?.amount, .rounded(try .init(validating: 0)))
        XCTAssertFalse(store.isRestoring)
    }

    func testSavingSettingsSamplesOnceAndPublishesReadyOnlyAfterCommit() async throws {
        let repository = BusinessRecordRepositorySpy()
        let now = ApplicationTestSupport.timestamp(hour: 8)
        let clock = MutableTestClock(now)
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        clock.resetSampleCount()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertEqual(settingsSaveReceipt(from: store.feedback)?.committedRevision, .init(rawValue: 1))
        let committed = await repository.currentSettings()
        XCTAssertEqual(committed?.revision, .init(rawValue: 1))
        XCTAssertEqual(committed?.updatedAtMs, now.rawValue)
    }

    func testSettingsWriteFailureKeepsUnconfiguredAndDoesNotPublishSuccess() async throws {
        let repository = BusinessRecordRepositorySpy()
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .failed(.persistence(.atomicWriteFailed)))
        XCTAssertEqual(store.viewState?.state, .unconfigured)
        XCTAssertEqual(
            store.feedback,
            .commandFailed(.saveWorkRules, .persistence(.atomicWriteFailed))
        )
    }

    func testDamagedSettingsUseBlockingRecoveryUntilExplicitPlanBasedReplacement() async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .damaged(damage)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )

        await store.restore()
        XCTAssertNil(store.viewState)
        XCTAssertEqual(store.settingsReadErrorViewState, .init(
            issue: .decodingFailed,
            isBlocking: true
        ))
        XCTAssertEqual(store.feedback, .settingsRecoveryRequired(.decodingFailed))

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertNotNil(settingsSaveReceipt(from: store.feedback))
        let persistedSettings = await repository.currentSettings()
        XCTAssertEqual(persistedSettings?.revision, .init(rawValue: 1))
    }

    func testEarlyClockInAutoStopAndLateClockOutUseAllAuthoritativeStates() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        XCTAssertEqual(store.viewState?.state, .ready)

        let clockInOutcome = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockInOutcome, .committed)
        XCTAssertEqual(store.viewState?.state, .clockedInWaiting)
        XCTAssertEqual(store.viewState?.amount, .live(try .init(validating: 0)))

        clock.set(ApplicationTestSupport.timestamp(hour: 9))
        await store.refresh()
        XCTAssertEqual(store.viewState?.state, .earning)

        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        await store.refresh()
        XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
        let saveCountAfterClockIn = await repository.todaySaveCount
        XCTAssertEqual(saveCountAfterClockIn, 1)

        clock.set(ApplicationTestSupport.timestamp(hour: 19))
        let clockOutOutcome = await store.send(.requestClockOut, source: .menuBar)
        XCTAssertEqual(clockOutOutcome, .committed)
        XCTAssertEqual(store.viewState?.state, .completed)
        XCTAssertEqual(store.viewState?.amount, .rounded(try .init(validating: 30_000)))
        let today = await repository.currentToday()
        XCTAssertEqual(today?.clockOutAtMs, ApplicationTestSupport.timestamp(hour: 19).rawValue)
        XCTAssertEqual(today?.scheduledEndAtMs, ApplicationTestSupport.timestamp(hour: 18).rawValue)
    }

    func testClockOutConfirmationCancelAndConfirmResampleAuthoritativeTime() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)

        clock.set(ApplicationTestSupport.timestamp(hour: 12))
        let requestOutcome = await store.send(.requestClockOut, source: .panel)
        XCTAssertEqual(requestOutcome, .confirmationPresented)
        let firstEstimate = try XCTUnwrap(clockOutEstimate(from: store.confirmation))
        XCTAssertEqual(firstEstimate.sampledAt, ApplicationTestSupport.timestamp(hour: 12))
        let cancelOutcome = await store.send(.cancelConfirmation, source: .panel)
        XCTAssertEqual(cancelOutcome, .confirmationCancelled)
        XCTAssertNil(store.confirmation)
        XCTAssertEqual(store.viewState?.state, .earning)

        _ = await store.send(.requestClockOut, source: .menuBar)
        let estimate = try XCTUnwrap(clockOutEstimate(from: store.confirmation))
        clock.set(ApplicationTestSupport.timestamp(hour: 13))
        await store.refresh()
        let refreshedEstimate = try XCTUnwrap(clockOutEstimate(from: store.confirmation))
        XCTAssertEqual(refreshedEstimate.sampledAt, ApplicationTestSupport.timestamp(hour: 13))
        XCTAssertGreaterThan(
            refreshedEstimate.roundedEarnedCents.rawValue,
            estimate.roundedEarnedCents.rawValue
        )
        XCTAssertGreaterThan(
            refreshedEstimate.earnedDuration.rawValue,
            estimate.earnedDuration.rawValue
        )

        clock.set(ApplicationTestSupport.timestamp(hour: 14))
        let confirmOutcome = await store.send(.confirmClockOut, source: .panel)
        XCTAssertEqual(confirmOutcome, .committed)

        let today = await repository.currentToday()
        XCTAssertEqual(today?.clockOutAtMs, ApplicationTestSupport.timestamp(hour: 14).rawValue)
        XCTAssertEqual(store.viewState?.state, .completed)
        guard case let .rounded(finalAmount) = store.viewState?.amount else {
            return XCTFail("Expected completed rounded amount")
        }
        XCTAssertNotEqual(finalAmount, refreshedEstimate.roundedEarnedCents)
    }

    func testClockInAtScheduledEndIsRejectedWithoutWrite() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 18))
        )
        await store.restore()

        let outcome = await store.send(.clockIn, source: .menuBar)

        XCTAssertEqual(outcome, .rejected(.clockInAfterScheduledEnd))
        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertFalse(store.viewState?.canClockIn ?? true)
        let todaySaveCount = await repository.todaySaveCount
        XCTAssertEqual(todaySaveCount, 0)
    }

    func testClockInWriteFailureKeepsReady() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        await repository.failNextTodaySave(with: .atomicWriteFailed)
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()

        let outcome = await store.send(.clockIn, source: .panel)

        XCTAssertEqual(outcome, .failed(.persistence(.atomicWriteFailed)))
        XCTAssertEqual(store.viewState?.state, .ready)
        let persistedToday = await repository.currentToday()
        XCTAssertNil(persistedToday)
    }

    func testClockOutWriteFailureKeepsStateAndConfirmationForRetry() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)
        clock.set(ApplicationTestSupport.timestamp(hour: 12))
        _ = await store.send(.requestClockOut, source: .panel)
        await repository.failNextTodaySave(with: .atomicWriteFailed)

        let outcome = await store.send(.confirmClockOut, source: .panel)

        XCTAssertEqual(outcome, .failed(.persistence(.atomicWriteFailed)))
        XCTAssertEqual(store.viewState?.state, .earning)
        XCTAssertNotNil(store.confirmation)
        let persistedToday = await repository.currentToday()
        XCTAssertNil(persistedToday?.clockOutAtMs)
    }

    func testDamagedTodayRequiresConfirmedResetAndResetFailurePreservesRecovery() async throws {
        let damaged = DamagedRecordResult(
            kind: .today,
            issue: .invalidSchemaEnvelope,
            disposition: .requireTodayReset
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current),
            today: .damaged(damaged)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        XCTAssertEqual(store.viewState?.state, .recoveryRequired)
        XCTAssertEqual(store.viewState?.amount, .hidden)

        let resetRequestOutcome = await store.send(.requestTodayReset, source: .panel)
        XCTAssertEqual(resetRequestOutcome, .confirmationPresented)
        let resetCancelOutcome = await store.send(.cancelConfirmation, source: .panel)
        XCTAssertEqual(resetCancelOutcome, .confirmationCancelled)
        XCTAssertEqual(store.viewState?.state, .recoveryRequired)

        _ = await store.send(.requestTodayReset, source: .panel)
        await repository.failNextReset(with: .deleteFailed)
        let failedResetOutcome = await store.send(.confirmTodayReset, source: .panel)
        XCTAssertEqual(failedResetOutcome, .failed(.persistence(.deleteFailed)))
        XCTAssertEqual(store.viewState?.state, .recoveryRequired)
        XCTAssertNil(store.confirmation)

        _ = await store.send(.requestTodayReset, source: .panel)
        let successfulResetOutcome = await store.send(.confirmTodayReset, source: .panel)
        XCTAssertEqual(successfulResetOutcome, .committed)
        XCTAssertEqual(store.viewState?.state, .ready)
        let persistedSettings = await repository.currentSettings()
        XCTAssertEqual(persistedSettings?.revision, .init(rawValue: 1))
    }

    func testPanelAndMenuBarConcurrentClockInSubmitExactlyOnce() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        await repository.holdNextTodaySave()
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()

        let panelTask = Task { @MainActor in
            await store.send(.clockIn, source: .panel)
        }
        await repository.waitUntilTodaySaveIsHeld()
        XCTAssertEqual(store.viewState?.state, .ready)

        let menuOutcome = await store.send(.clockIn, source: .menuBar)
        XCTAssertEqual(menuOutcome, .rejected(.commandInFlight))
        await repository.releaseHeldTodaySave()
        let panelOutcome = await panelTask.value
        XCTAssertEqual(panelOutcome, .committed)

        let todaySaveCount = await repository.todaySaveCount
        XCTAssertEqual(todaySaveCount, 1)
        XCTAssertEqual(store.viewState?.state, .earning)
        let persistedToday = await repository.currentToday()
        XCTAssertEqual(persistedToday?.revision, .init(rawValue: 1))
    }

    func testCurrentDateTodayRejectsDuplicateClockInWithoutMutationOrWrite() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let commandNow = ApplicationTestSupport.timestamp(day: 14, hour: 12)
        let currentDateToday = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(day: 14, hour: 10)
        ).replacingRevision(.init(rawValue: 7))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(currentDateToday, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(commandNow)
        )

        await store.restore()

        let loadedTodayBefore = await repository.currentToday()
        let todayBefore = try XCTUnwrap(loadedTodayBefore)
        XCTAssertEqual(todayBefore, currentDateToday)
        XCTAssertEqual(
            todayBefore.dateKey,
            try calendar.currentDateKey(at: commandNow).rawValue
        )
        let viewStateBefore = store.viewState
        XCTAssertEqual(viewStateBefore?.state, .earning)
        let feedbackBefore = store.feedback
        let settingsSaveCountBefore = await repository.settingsSaveCount
        let todaySaveCountBefore = await repository.todaySaveCount
        let resetTodayCountBefore = await repository.resetTodayCount

        let outcome = await store.send(.clockIn, source: .panel)

        XCTAssertEqual(outcome, .rejected(.invalidState))
        let todayAfter = await repository.currentToday()
        XCTAssertEqual(todayAfter, todayBefore)
        XCTAssertEqual(todayAfter?.revision, .init(rawValue: 7))
        XCTAssertEqual(todayAfter?.dateKey, todayBefore.dateKey)
        XCTAssertEqual(todayAfter?.clockInAtMs, todayBefore.clockInAtMs)
        XCTAssertEqual(todayAfter?.clockOutAtMs, todayBefore.clockOutAtMs)
        XCTAssertEqual(todayAfter?.scheduledStartAtMs, todayBefore.scheduledStartAtMs)
        XCTAssertEqual(todayAfter?.scheduledEndAtMs, todayBefore.scheduledEndAtMs)
        XCTAssertEqual(todayAfter?.updatedAtMs, todayBefore.updatedAtMs)
        let settingsSaveCountAfter = await repository.settingsSaveCount
        let todaySaveCountAfter = await repository.todaySaveCount
        let resetTodayCountAfter = await repository.resetTodayCount
        XCTAssertEqual(settingsSaveCountAfter, settingsSaveCountBefore)
        XCTAssertEqual(todaySaveCountAfter, todaySaveCountBefore)
        XCTAssertEqual(resetTodayCountAfter, resetTodayCountBefore)
        XCTAssertEqual(store.viewState, viewStateBefore)
        XCTAssertEqual(store.feedback, feedbackBefore)
    }

    func testIncompletePreviousDayIsRetainedAndBlocksNewClockIn() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let previousDay = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(day: 13, hour: 10)
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(previousDay, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )

        await store.restore()

        XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
        XCTAssertFalse(store.viewState?.previousDayCleanupPending ?? true)
        XCTAssertFalse(store.viewState?.canClockIn ?? true)
        let recordAfterFailure = await repository.currentToday()
        XCTAssertEqual(recordAfterFailure, previousDay)

        let blockedOutcome = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(blockedOutcome, .rejected(.invalidState))

        await store.refresh()

        XCTAssertFalse(store.viewState?.previousDayCleanupPending ?? true)
        XCTAssertFalse(store.viewState?.canClockIn ?? true)
        let recordAfterRetry = await repository.currentToday()
        XCTAssertEqual(recordAfterRetry, previousDay)
    }

    func testSettingsChangesDoNotMutateActiveTodaySnapshot() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)

        clock.set(ApplicationTestSupport.timestamp(hour: 10))
        _ = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                wageCents: 60_000,
                startMinuteOfDay: 10 * 60,
                endMinuteOfDay: 17 * 60
            )),
            source: .settings
        )
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        await store.refresh()

        XCTAssertEqual(store.viewState?.amount, .rounded(try .init(validating: 30_000)))
        let persistedSettings = await repository.currentSettings()
        let persistedToday = await repository.currentToday()
        XCTAssertEqual(persistedSettings?.dailyWageCents, 60_000)
        XCTAssertEqual(persistedToday?.settingsSnapshot.dailyWageCents, 30_000)
        XCTAssertEqual(persistedSettings?.workStartMinuteOfDay, 10 * 60)
        XCTAssertEqual(persistedSettings?.workEndMinuteOfDay, 17 * 60)
        XCTAssertEqual(persistedToday?.settingsSnapshot.workStartMinuteOfDay, 9 * 60)
        XCTAssertEqual(persistedToday?.settingsSnapshot.workEndMinuteOfDay, 18 * 60)
        XCTAssertEqual(
            persistedToday?.scheduledStartAtMs,
            ApplicationTestSupport.timestamp(hour: 9).rawValue
        )
        XCTAssertEqual(
            persistedToday?.scheduledEndAtMs,
            ApplicationTestSupport.timestamp(hour: 18).rawValue
        )
    }

    func testCompositionRootOwnsOneStoreAndRestoresItBeforeShowingPanel() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        let panelController = PanelControllerSpy()
        let environment = AppEnvironment(
            businessStore: store,
            panelController: panelController
        )

        XCTAssertTrue(environment.businessStore === store)
        XCTAssertNil(environment.businessStore.viewState)

        await environment.start()

        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertEqual(panelController.restoreCount, 1)
        XCTAssertEqual(panelController.showCount, 1)
        XCTAssertTrue(environment.isPanelVisible)

        await environment.start()
        XCTAssertEqual(panelController.showCount, 1)
    }

    func testLocalScheduleResolverRejectsGapAndFoldForBothBoundaries() throws {
        let resolver = LocalScheduleResolver()
        let zone = "America/New_York"
        let gapDay = try WorkdayKey(validating: "2026-03-08")
        let foldDay = try WorkdayKey(validating: "2026-11-01")

        assertScheduleError(
            .nonexistentLocalTime(
                boundary: .start,
                dateKey: gapDay.rawValue,
                timeZoneIdentifier: zone
            )
        ) {
            try resolver.resolve(
                dateKey: gapDay,
                timeZoneIdentifier: zone,
                startMinuteOfDay: 2 * 60 + 30,
                endMinuteOfDay: 4 * 60
            )
        }
        assertScheduleError(
            .nonexistentLocalTime(
                boundary: .end,
                dateKey: gapDay.rawValue,
                timeZoneIdentifier: zone
            )
        ) {
            try resolver.resolve(
                dateKey: gapDay,
                timeZoneIdentifier: zone,
                startMinuteOfDay: 60,
                endMinuteOfDay: 2 * 60 + 30
            )
        }
        assertScheduleError(
            .ambiguousLocalTime(
                boundary: .start,
                dateKey: foldDay.rawValue,
                timeZoneIdentifier: zone
            )
        ) {
            try resolver.resolve(
                dateKey: foldDay,
                timeZoneIdentifier: zone,
                startMinuteOfDay: 90,
                endMinuteOfDay: 3 * 60
            )
        }
        assertScheduleError(
            .ambiguousLocalTime(
                boundary: .end,
                dateKey: foldDay.rawValue,
                timeZoneIdentifier: zone
            )
        ) {
            try resolver.resolve(
                dateKey: foldDay,
                timeZoneIdentifier: zone,
                startMinuteOfDay: 30,
                endMinuteOfDay: 90
            )
        }
    }

    func testLocalScheduleResolverRejectsEqualAndReversedBoundariesOnOrdinaryDay() throws {
        let resolver = LocalScheduleResolver()
        let day = try WorkdayKey(validating: "2026-03-09")
        for zone in ["America/New_York", "Asia/Shanghai"] {
            for (start, end) in [(540, 540), (1_080, 540)] {
                XCTAssertThrowsError(try resolver.resolve(dateKey: day, timeZoneIdentifier: zone,
                    startMinuteOfDay: start, endMinuteOfDay: end)) { error in
                    XCTAssertEqual(error as? BusinessCalendarError, .invalidDomainValue,
                                   "\(zone) start=\(start) end=\(end)")
                }
            }
            let valid = try resolver.resolve(dateKey: day, timeZoneIdentifier: zone,
                startMinuteOfDay: 540, endMinuteOfDay: 1_080)
            XCTAssertGreaterThan(valid.scheduledEndAt.rawValue, valid.scheduledStartAt.rawValue)
            XCTAssertEqual(valid.scheduledEndAt.rawValue - valid.scheduledStartAt.rawValue, 32_400_000)
        }
    }

    func testLocalScheduleResolverRoundTripsNormalTimesAndRejectsUnknownTimeZone() throws {
        let resolver = LocalScheduleResolver()
        let dateKey = try WorkdayKey(validating: "2026-03-09")
        let zone = "America/New_York"
        let schedule = try resolver.resolve(
            dateKey: dateKey,
            timeZoneIdentifier: zone,
            startMinuteOfDay: 2 * 60 + 30,
            endMinuteOfDay: 3 * 60 + 30
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        let start = Date(
            timeIntervalSince1970: Double(schedule.scheduledStartAt.rawValue) / 1_000
        )
        let end = Date(
            timeIntervalSince1970: Double(schedule.scheduledEndAt.rawValue) / 1_000
        )
        XCTAssertEqual(calendar.component(.hour, from: start), 2)
        XCTAssertEqual(calendar.component(.minute, from: start), 30)
        XCTAssertEqual(calendar.component(.hour, from: end), 3)
        XCTAssertEqual(calendar.component(.minute, from: end), 30)

        XCTAssertThrowsError(try resolver.resolve(
            dateKey: dateKey,
            timeZoneIdentifier: "Invalid/TimeZone",
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 18 * 60
        )) { error in
            XCTAssertEqual(error as? BusinessCalendarError, .invalidTimeZone)
        }
    }

    func testRestorePublishesRecoverableGapErrorWithoutMutatingRecords() async throws {
        let zone = "America/New_York"
        let settings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 2 * 60 + 30,
            endMinuteOfDay: 3 * 60 + 30
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(
            timeZoneIdentifier: zone,
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        ))
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifier: zone
        )

        await store.restore()

        XCTAssertFalse(store.isRestoring)
        XCTAssertNil(store.viewState)
        XCTAssertEqual(store.scheduleTimeErrorViewState, .init(
            error: .nonexistentLocalTime(
                boundary: .start,
                dateKey: "2026-03-08",
                timeZoneIdentifier: zone
            ),
            context: .activeSchedule
        ))
        let preservedSettings = await repository.currentSettings()
        XCTAssertEqual(preservedSettings, settings)
        XCTAssertNil(store.feedback)
    }

    func testRestorePublishesRecoverableFoldError() async throws {
        let zone = "America/New_York"
        let settings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 90,
            endMinuteOfDay: 3 * 60
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone,
                year: 2026,
                month: 11,
                day: 1,
                hour: 12
            )),
            timeZoneIdentifier: zone
        )

        await store.restore()

        XCTAssertNil(store.viewState)
        XCTAssertEqual(store.scheduleTimeErrorViewState?.error, .ambiguousLocalTime(
            boundary: .start,
            dateKey: "2026-11-01",
            timeZoneIdentifier: zone
        ))
    }

    func testGapSaveFailsBeforeRepositoryAndValidRetryRecovers() async throws {
        let zone = "America/New_York"
        let initial = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 60,
            endMinuteOfDay: 4 * 60
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(
            timeZoneIdentifier: zone,
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        ))
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifier: zone
        )
        await store.restore()
        let oldViewState = store.viewState

        let failed = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                startMinuteOfDay: 2 * 60 + 30,
                endMinuteOfDay: 3 * 60 + 30
            )),
            source: .settings
        )

        XCTAssertEqual(failed, .failed(.scheduleTime(.nonexistentLocalTime(
            boundary: .start,
            dateKey: "2026-03-08",
            timeZoneIdentifier: zone
        ))))
        XCTAssertEqual(store.viewState, oldViewState)
        XCTAssertEqual(store.scheduleTimeErrorViewState?.context, .proposedSettings)
        XCTAssertFalse(store.hasBlockingScheduleError, "A rejected draft cannot block an existing valid business state")
        let draftError = store.scheduleTimeErrorViewState
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(store.scheduleTimeErrorViewState, draftError, "Committed-state render pulses must not dismiss the rejected draft error")
        XCTAssertEqual(store.viewState, oldViewState)
        XCTAssertNil(store.feedback)
        let failedSaveCount = await repository.settingsSaveCount
        let settingsAfterFailure = await repository.currentSettings()
        XCTAssertEqual(failedSaveCount, 0)
        XCTAssertEqual(settingsAfterFailure, initial)
        let checkingContexts: [BusinessCommandContext] = store.commandPhaseHistory.compactMap { phase in
            guard case let .checking(context) = phase else { return nil }
            return context
        }
        let failedContext = try XCTUnwrap(checkingContexts.last)

        clock.set(ApplicationTestSupport.timestamp(
            timeZoneIdentifier: zone,
            year: 2026,
            month: 3,
            day: 8,
            hour: 13
        ))

        let recovered = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                startMinuteOfDay: 4 * 60,
                endMinuteOfDay: 5 * 60
            )),
            source: .settings
        )

        XCTAssertEqual(recovered, .committed)
        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertNil(store.scheduleTimeErrorViewState)
        let recoveredReceipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertNotEqual(recoveredReceipt.context.commandID, failedContext.commandID)
        XCTAssertNotEqual(recoveredReceipt.context.timestampMs, failedContext.timestampMs)
        let recoveredSaveCount = await repository.settingsSaveCount
        XCTAssertEqual(recoveredSaveCount, 1)
    }

    func testCommitPublishesOnlyThePreconstructedSettingsTarget() async throws {
        let repository = BusinessRecordRepositorySpy()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        let zoneProvider = MutableTestTimeZoneIdentifierProvider(
            ApplicationTestSupport.timeZoneIdentifier
        )
        let resolver = CountingScheduleResolver(allowedCalls: 2)
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifierProvider: zoneProvider,
            scheduleResolver: resolver
        )
        await store.restore()
        clock.resetSampleCount()
        zoneProvider.resetSampleCount()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zoneProvider.sampleCount, 1)
        XCTAssertEqual(resolver.callCount, 2)
        XCTAssertEqual(store.viewState?.state, .ready)
        XCTAssertNil(store.scheduleTimeErrorViewState)
        let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertEqual(receipt.committedRevision, .init(rawValue: 1))
        XCTAssertEqual(receipt.context.timestampMs, ApplicationTestSupport.timestamp(hour: 8))
        XCTAssertEqual(receipt.context.commandTimeZoneIdentifier,
                       ApplicationTestSupport.timeZoneIdentifier)
        XCTAssertTrue(store.commandPhaseHistory.contains(.checking(receipt.context)))
        XCTAssertTrue(store.commandPhaseHistory.contains(
            .saving(receipt.context, targetRevision: receipt.committedRevision)
        ))
        XCTAssertEqual(store.commandPhase, .idle)
        let committed = await repository.currentSettings()
        XCTAssertEqual(committed?.revision, receipt.committedRevision)
        XCTAssertEqual(store.stateGeneration, 2)
    }

    func testSettingsCommitSuccessDoesNotRecomputeAndPublishesSuccessExactlyOnce() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let today = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(hour: 10)
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current)
        )
        let observer = FailOnPostCommitSaveSettingsExecutionObserver()
        await repository.observeSettingsCommitSuccess {
            observer.markRepositoryCommitSucceeded()
        }
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                identifier: ApplicationTestSupport.timeZoneIdentifier
            ),
            saveSettingsExecutionObserver: observer
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 45_000)),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(store.viewState?.state, .earning)
        let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertEqual(receipt.committedRevision, .init(rawValue: 2))
        let committed = await repository.currentSettings()
        XCTAssertEqual(committed?.revision, receipt.committedRevision)
        XCTAssertEqual(observer.observation, SaveSettingsExecutionObservation(
            preCommitStateDerivationCount: 1,
            preCommitEarningsCalculationCount: 1,
            preCommitViewStateConstructionCount: 1,
            postCommitStateDerivationCount: 0,
            postCommitEarningsCalculationCount: 0,
            postCommitViewStateConstructionCount: 0,
            successPublicationCount: 1,
            prematureSuccessPublicationCount: 0
        ))
    }

    func testSettingsCommitFailurePublishesNoSuccessThroughPublicationObserver() async throws {
        let repository = BusinessRecordRepositorySpy()
        let observer = FailOnPostCommitSaveSettingsExecutionObserver()
        await repository.observeSettingsCommitSuccess {
            observer.markRepositoryCommitSucceeded()
        }
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)),
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                identifier: ApplicationTestSupport.timeZoneIdentifier
            ),
            saveSettingsExecutionObserver: observer
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .failed(.persistence(.atomicWriteFailed)))
        XCTAssertEqual(
            store.feedback,
            .commandFailed(.saveWorkRules, .persistence(.atomicWriteFailed))
        )
        XCTAssertEqual(observer.observation, SaveSettingsExecutionObservation(
            preCommitStateDerivationCount: 1,
            preCommitEarningsCalculationCount: 0,
            preCommitViewStateConstructionCount: 1,
            postCommitStateDerivationCount: 0,
            postCommitEarningsCalculationCount: 0,
            postCommitViewStateConstructionCount: 0,
            successPublicationCount: 0,
            prematureSuccessPublicationCount: 0
        ))
    }

    func testFoldSaveFailsBeforeRepository() async throws {
        let zone = "America/New_York"
        let initial = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 30,
            endMinuteOfDay: 3 * 60
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone,
                year: 2026,
                month: 11,
                day: 1,
                hour: 12
            )),
            timeZoneIdentifier: zone
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                startMinuteOfDay: 90,
                endMinuteOfDay: 3 * 60
            )),
            source: .settings
        )

        XCTAssertEqual(outcome, .failed(.scheduleTime(.ambiguousLocalTime(
            boundary: .start,
            dateKey: "2026-11-01",
            timeZoneIdentifier: zone
        ))))
        let draftError = try XCTUnwrap(store.scheduleTimeErrorViewState)
        XCTAssertEqual(draftError.context, .proposedSettings)
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(store.scheduleTimeErrorViewState, draftError)
        let saveCount = await repository.settingsSaveCount
        let settingsAfterFailure = await repository.currentSettings()
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(settingsAfterFailure, initial)
    }

    func testValidTodaySnapshotWinsOverInvalidCurrentSettings() async throws {
        let zone = "America/New_York"
        let invalidCurrent = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 2 * 60 + 30,
            endMinuteOfDay: 3 * 60 + 30
        ).replacingRevision(.init(rawValue: 1))
        let snapshotSettings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 60,
            endMinuteOfDay: 4 * 60
        ).replacingRevision(.init(rawValue: 1))
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: zone)
        let today = try calendar.proposedToday(
            from: snapshotSettings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone,
                year: 2026,
                month: 3,
                day: 8,
                hour: 1
            )
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(invalidCurrent, migration: .current),
            today: .loaded(today, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone,
                year: 2026,
                month: 3,
                day: 8,
                hour: 12
            )),
            timeZoneIdentifier: zone
        )

        await store.restore()

        XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
        XCTAssertNil(store.scheduleTimeErrorViewState)
        let preservedToday = await repository.currentToday()
        XCTAssertEqual(preservedToday, today)
    }

    func testWorkRuleSavePreservesFieldsOwnedByOtherStages() async throws {
        let placement = PanelPlacementRecord(
            displayUUID: "display-1",
            snapCorner: .bottomRight,
            xOffset: 12,
            yOffset: 18,
            constrainedFrame: PersistedPanelFrame(x: 1, y: 2, width: 320, height: 190)
        )
        let initial = ApplicationTestSupport.proposedSettings(
            notificationsEnabled: true,
            alwaysOnTop: false,
            lockPanelPosition: true,
            hideInFullScreen: false,
            launchAtLogin: true,
            panelVisible: false,
            panelPlacement: placement
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                wageCents: 45_000,
                startMinuteOfDay: 8 * 60,
                endMinuteOfDay: 17 * 60
            )),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        let persistedSettings = await repository.currentSettings()
        let committed = try XCTUnwrap(persistedSettings)
        XCTAssertEqual(committed.dailyWageCents, 45_000)
        XCTAssertEqual(committed.workStartMinuteOfDay, 8 * 60)
        XCTAssertEqual(committed.workEndMinuteOfDay, 17 * 60)
        XCTAssertEqual(committed.notificationsEnabled, initial.notificationsEnabled)
        XCTAssertEqual(committed.alwaysOnTop, initial.alwaysOnTop)
        XCTAssertEqual(committed.lockPanelPosition, initial.lockPanelPosition)
        XCTAssertEqual(committed.hideInFullScreen, initial.hideInFullScreen)
        XCTAssertEqual(committed.launchAtLogin, initial.launchAtLogin)
        XCTAssertEqual(committed.panelVisible, initial.panelVisible)
        XCTAssertEqual(committed.panelPlacement, initial.panelPlacement)
    }

    func testSettingsRevisionConflictKeepsExternalRecordAndOldViewState() async throws {
        let initial = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        let oldViewState = store.viewState
        let external = ApplicationTestSupport.proposedSettings(wageCents: 40_000)
            .replacingRevision(.init(rawValue: 2))
        await repository.replaceSettingsExternally(external)

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 50_000)),
            source: .settings
        )

        let conflict = PersistenceError.revisionConflict(
            expected: .init(rawValue: 1),
            actual: .init(rawValue: 2)
        )
        XCTAssertEqual(outcome, .failed(.persistence(conflict)))
        XCTAssertEqual(store.feedback, .commandFailed(.saveWorkRules, .persistence(conflict)))
        XCTAssertEqual(store.viewState, oldViewState)
        let persistedSettings = await repository.currentSettings()
        XCTAssertEqual(persistedSettings, external)
    }

    func testTodayRevisionConflictKeepsConfirmationAndExternalRecord() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)
        clock.set(ApplicationTestSupport.timestamp(hour: 12))
        _ = await store.send(.requestClockOut, source: .panel)
        let persistedToday = await repository.currentToday()
        let external = try XCTUnwrap(persistedToday)
            .replacingRevision(.init(rawValue: 2))
        await repository.replaceTodayExternally(external)

        let outcome = await store.send(.confirmClockOut, source: .panel)

        let conflict = PersistenceError.revisionConflict(
            expected: .init(rawValue: 1),
            actual: .init(rawValue: 2)
        )
        XCTAssertEqual(outcome, .failed(.persistence(conflict)))
        XCTAssertEqual(
            store.feedback,
            .commandFailed(.confirmClockOut, .persistence(conflict))
        )
        XCTAssertNotNil(store.confirmation)
        XCTAssertEqual(store.viewState?.state, .earning)
        let todayAfterConflict = await repository.currentToday()
        XCTAssertEqual(todayAfterConflict, external)
    }

    func testClockOutOnNextAndMultipleDaysIsCommittedAgainstFrozenTodaySnapshot() async throws {
        for day in [14, 17] {
            let repository = BusinessRecordRepositorySpy(
                settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
            )
            let clock = MutableTestClock(ApplicationTestSupport.timestamp(day: 13, hour: 10))
            let store = try makeStore(repository: repository, clock: clock)
            await store.restore()
            let clockIn = await store.send(.clockIn, source: .panel)
            XCTAssertEqual(clockIn, .committed)

            let later = ApplicationTestSupport.timestamp(day: day, hour: 8)
            clock.set(later)
            let clockOut = await store.send(.requestClockOut, source: .panel)
            XCTAssertEqual(clockOut, .committed)
            XCTAssertEqual(store.viewState?.state, .completed)
            XCTAssertEqual(store.viewState?.todayDateKey, "2026-08-13")
            XCTAssertEqual(store.viewState?.todayTimeZoneIdentifier,
                           ApplicationTestSupport.timeZoneIdentifier)
            XCTAssertTrue(store.viewState?.isPreviousWorkday ?? false)
            XCTAssertEqual(store.viewState?.clockOutDateKey,
                           String(format: "2026-08-%02d", day))
            let today = await repository.currentToday()
            XCTAssertEqual(today?.dateKey, "2026-08-13")
            XCTAssertEqual(today?.clockOutAtMs, later.rawValue)
        }
    }

    func testStartTodayScheduleFailureKeepsCompletedTodayAndPerformsZeroWrites() async throws {
        let zone = "America/New_York"
        let settings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 2 * 60 + 30,
            endMinuteOfDay: 4 * 60
        ).replacingRevision(.init(rawValue: 1))
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: zone)
        let proposed = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 3, day: 7, hour: 3
            )
        )
        let completed = TodayRecord(
            schemaVersion: proposed.schemaVersion,
            revision: .init(rawValue: 1),
            dateKey: proposed.dateKey,
            clockInAtMs: proposed.clockInAtMs,
            clockOutAtMs: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 3, day: 7, hour: 4
            ).rawValue,
            settingsSnapshot: proposed.settingsSnapshot,
            scheduledStartAtMs: proposed.scheduledStartAtMs,
            scheduledEndAtMs: proposed.scheduledEndAtMs,
            notificationScheduledDateKey: proposed.notificationScheduledDateKey,
            notificationRequestIdentifier: proposed.notificationRequestIdentifier,
            updatedAtMs: proposed.updatedAtMs
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(completed, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 3, day: 8, hour: 12
            )),
            timeZoneIdentifier: zone
        )
        await store.restore()
        let oldState = store.viewState
        let requestStart = await store.send(.requestStartToday, source: .panel)
        XCTAssertEqual(requestStart, .confirmationPresented)
        let outcome = await store.send(.confirmStartToday, source: .panel)

        XCTAssertEqual(outcome, .failed(.scheduleTime(.nonexistentLocalTime(
            boundary: .start,
            dateKey: "2026-03-08",
            timeZoneIdentifier: zone
        ))))
        XCTAssertEqual(store.viewState, oldState)
        let todayAfterFailure = await repository.currentToday()
        let resetCount = await repository.resetTodayCount
        XCTAssertEqual(todayAfterFailure, completed)
        XCTAssertEqual(resetCount, 0)
    }

    func testStartTodayFoldFailureKeepsCompletedTodayAndPerformsZeroWrites() async throws {
        let zone = "America/New_York"
        let settings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: 90,
            endMinuteOfDay: 3 * 60
        ).replacingRevision(.init(rawValue: 1))
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: zone)
        let proposed = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 10, day: 31, hour: 2
            )
        )
        let completed = TodayRecord(
            schemaVersion: proposed.schemaVersion,
            revision: .init(rawValue: 1),
            dateKey: proposed.dateKey,
            clockInAtMs: proposed.clockInAtMs,
            clockOutAtMs: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 10, day: 31, hour: 4
            ).rawValue,
            settingsSnapshot: proposed.settingsSnapshot,
            scheduledStartAtMs: proposed.scheduledStartAtMs,
            scheduledEndAtMs: proposed.scheduledEndAtMs,
            notificationScheduledDateKey: nil,
            notificationRequestIdentifier: nil,
            updatedAtMs: proposed.updatedAtMs
        )
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(completed, migration: .current)
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: zone, year: 2026, month: 11, day: 1, hour: 12
            )),
            timeZoneIdentifier: zone
        )
        await store.restore()
        let oldState = store.viewState
        _ = await store.send(.requestStartToday, source: .panel)

        let outcome = await store.send(.confirmStartToday, source: .panel)

        XCTAssertEqual(outcome, .failed(.scheduleTime(.ambiguousLocalTime(
            boundary: .start,
            dateKey: "2026-11-01",
            timeZoneIdentifier: zone
        ))))
        XCTAssertEqual(store.viewState, oldState)
        let todayAfterFailure = await repository.currentToday()
        let resetCount = await repository.resetTodayCount
        XCTAssertEqual(todayAfterFailure, completed)
        XCTAssertEqual(resetCount, 0)
    }

    func testSettingsAndTodayDoubleDamageHasDeterministicResetOrders() async throws {
        let settingsDamage = DamagedRecordResult(
            kind: .settings, issue: .decodingFailed, disposition: .requireSettingsRecovery
        )
        let todayDamage = DamagedRecordResult(
            kind: .today, issue: .validationFailed, disposition: .requireTodayReset
        )

        let settingsFirstRepository = BusinessRecordRepositorySpy(
            settings: .damaged(settingsDamage), today: .damaged(todayDamage)
        )
        let settingsFirst = try makeStore(
            repository: settingsFirstRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await settingsFirst.restore()
        XCTAssertEqual(settingsFirst.viewState?.state, .recoveryRequired)
        XCTAssertEqual(settingsFirst.settingsReadErrorViewState?.isBlocking, false)
        _ = await settingsFirst.send(.requestSettingsReset, source: .settings)
        let settingsResetFirst = await settingsFirst.send(.confirmSettingsReset, source: .settings)
        XCTAssertEqual(settingsResetFirst, .committed)
        XCTAssertEqual(settingsFirst.viewState?.state, .recoveryRequired)
        XCTAssertNil(settingsFirst.settingsReadErrorViewState)
        _ = await settingsFirst.send(.requestTodayReset, source: .settings)
        let todayResetSecond = await settingsFirst.send(.confirmTodayReset, source: .settings)
        XCTAssertEqual(todayResetSecond, .committed)
        XCTAssertEqual(settingsFirst.viewState?.state, .unconfigured)

        let todayFirstRepository = BusinessRecordRepositorySpy(
            settings: .damaged(settingsDamage), today: .damaged(todayDamage)
        )
        let todayFirst = try makeStore(
            repository: todayFirstRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await todayFirst.restore()
        _ = await todayFirst.send(.requestTodayReset, source: .settings)
        let todayResetFirst = await todayFirst.send(.confirmTodayReset, source: .settings)
        XCTAssertEqual(todayResetFirst, .committed)
        XCTAssertNil(todayFirst.viewState)
        XCTAssertEqual(todayFirst.settingsReadErrorViewState?.isBlocking, true)
        _ = await todayFirst.send(.requestSettingsReset, source: .settings)
        let settingsResetSecond = await todayFirst.send(.confirmSettingsReset, source: .settings)
        XCTAssertEqual(settingsResetSecond, .committed)
        XCTAssertEqual(todayFirst.viewState?.state, .unconfigured)

        let replaceRepository = BusinessRecordRepositorySpy(
            settings: .damaged(settingsDamage), today: .damaged(todayDamage)
        )
        let replaceStore = try makeStore(
            repository: replaceRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await replaceStore.restore()
        let replace = await replaceStore.send(
            .saveWorkRules(ApplicationTestSupport.workRules()), source: .settings
        )
        XCTAssertEqual(replace, .committed)
        XCTAssertEqual(replaceStore.viewState?.state, .recoveryRequired)
        XCTAssertNil(replaceStore.settingsReadErrorViewState)
        XCTAssertNotNil(settingsSaveReceipt(from: replaceStore.feedback))
        let replacedSettings = await replaceRepository.currentSettings()
        let retainedTodayDamage = await replaceRepository.loadTodayForBusiness()
        XCTAssertNotNil(replacedSettings)
        guard case .damaged = retainedTodayDamage else {
            return XCTFail("Expected damaged Today token to remain after Settings replacement")
        }
    }

    func testTodayRestoreNeverInvokesLocalScheduleResolver() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let today = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(hour: 10)
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current)
        )
        let resolver = CountingScheduleResolver(allowedCalls: 0)
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                identifier: ApplicationTestSupport.timeZoneIdentifier
            ),
            scheduleResolver: resolver
        )

        await store.restore()

        XCTAssertEqual(store.viewState?.state, .earning)
        XCTAssertEqual(resolver.callCount, 0)
        XCTAssertEqual(store.viewState?.todayDateKey, "2026-08-13")
        XCTAssertEqual(store.viewState?.todayTimeZoneIdentifier,
                       ApplicationTestSupport.timeZoneIdentifier)
    }

    func testSameStoreResamplesTimezoneOncePerCommandAndFreezesEachContext() async throws {
        let instant = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: "UTC",
            year: 2026, month: 8, day: 13, hour: 12
        )
        let clock = MutableTestClock(instant)
        let zones = MutableTestTimeZoneIdentifierProvider("Pacific/Kiritimati")
        let repository = BusinessRecordRepositorySpy()
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifierProvider: zones
        )
        await store.restore()
        clock.resetSampleCount()
        zones.resetSampleCount()

        let eastOutcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()), source: .settings
        )
        XCTAssertEqual(eastOutcome, .committed)
        let east = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertEqual(east.context.commandDateKey.rawValue, "2026-08-14")
        XCTAssertEqual(east.context.commandTimeZoneIdentifier, "Pacific/Kiritimati")
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zones.sampleCount, 1)

        zones.set("Pacific/Honolulu")
        clock.resetSampleCount()
        zones.resetSampleCount()
        let westOutcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 31_000)),
            source: .settings
        )
        XCTAssertEqual(westOutcome, .committed)
        let west = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertEqual(west.context.commandDateKey.rawValue, "2026-08-13")
        XCTAssertEqual(west.context.commandTimeZoneIdentifier, "Pacific/Honolulu")
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zones.sampleCount, 1)
        XCTAssertNotEqual(east.context.commandID, west.context.commandID)
    }

    func testRestoreClockInAndClockOutEachSampleClockAndTimezoneExactlyOnce() async throws {
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)
        )
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let zones = MutableTestTimeZoneIdentifierProvider(
            ApplicationTestSupport.timeZoneIdentifier
        )
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifierProvider: zones
        )

        await store.restore()
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zones.sampleCount, 1)

        clock.resetSampleCount()
        zones.resetSampleCount()
        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zones.sampleCount, 1)

        clock.set(ApplicationTestSupport.timestamp(hour: 19))
        clock.resetSampleCount()
        zones.resetSampleCount()
        let clockOut = await store.send(.requestClockOut, source: .panel)
        XCTAssertEqual(clockOut, .committed)
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(zones.sampleCount, 1)
        XCTAssertEqual(store.viewState?.clockOutDateKey, "2026-08-13")
    }

    func testConfirmedTodayResetDeletesBeforeGapOrFoldRecoveryDerivation() async throws {
        let damage = DamagedRecordResult(
            kind: .today,
            issue: .validationFailed,
            disposition: .requireTodayReset
        )
        let cases: [(String, Int, Int, ScheduleTimeError)] = [
            ("2026-03-08", 2 * 60 + 30, 4 * 60, .nonexistentLocalTime(
                boundary: .start, dateKey: "2026-03-08", timeZoneIdentifier: "America/New_York"
            )),
            ("2026-11-01", 90, 3 * 60, .ambiguousLocalTime(
                boundary: .start, dateKey: "2026-11-01", timeZoneIdentifier: "America/New_York"
            ))
        ]
        for item in cases {
            let components = item.0.split(separator: "-").compactMap { Int($0) }
            let settings = ApplicationTestSupport.proposedSettings(
                startMinuteOfDay: item.1,
                endMinuteOfDay: item.2
            ).replacingRevision(.init(rawValue: 1))
            let repository = BusinessRecordRepositorySpy(
                settings: .loaded(settings, migration: .current),
                today: .damaged(damage)
            )
            let store = try BusinessStore(
                repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                    timeZoneIdentifier: "America/New_York",
                    year: components[0], month: components[1], day: components[2], hour: 12
                )),
                timeZoneIdentifier: "America/New_York"
            )
            await store.restore()
            XCTAssertEqual(store.viewState?.state, .recoveryRequired)
            _ = await store.send(.requestTodayReset, source: .settings)

            let outcome = await store.send(.confirmTodayReset, source: .settings)

            XCTAssertEqual(outcome, .committed)
            let persistedToday = await repository.currentToday()
            let resetCount = await repository.resetTodayCount
            XCTAssertNil(persistedToday)
            XCTAssertEqual(resetCount, 1)
            XCTAssertNil(store.viewState)
            XCTAssertEqual(store.scheduleTimeErrorViewState?.error, item.3)
            XCTAssertEqual(store.feedback, .todayResetSucceeded)
        }
    }

    func testStartTodayWithMissingSettingsCommitsUnconfiguredAndSameDayIsRejected() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let proposed = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(day: 13, hour: 10)
        )
        let completed = TodayRecord(
            schemaVersion: proposed.schemaVersion,
            revision: .init(rawValue: 1),
            dateKey: proposed.dateKey,
            clockInAtMs: proposed.clockInAtMs,
            clockOutAtMs: ApplicationTestSupport.timestamp(day: 13, hour: 11).rawValue,
            settingsSnapshot: proposed.settingsSnapshot,
            scheduledStartAtMs: proposed.scheduledStartAtMs,
            scheduledEndAtMs: proposed.scheduledEndAtMs,
            notificationScheduledDateKey: nil,
            notificationRequestIdentifier: nil,
            updatedAtMs: ApplicationTestSupport.timestamp(day: 13, hour: 11).rawValue
        )
        let sameDayRepository = BusinessRecordRepositorySpy(
            today: .loaded(completed, migration: .current)
        )
        let sameDay = try makeStore(
            repository: sameDayRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 13, hour: 12))
        )
        await sameDay.restore()
        let sameDayRequest = await sameDay.send(.requestStartToday, source: .panel)
        let sameDayResetCount = await sameDayRepository.resetTodayCount
        XCTAssertEqual(sameDayRequest, .rejected(.invalidWorkdayTransition))
        XCTAssertEqual(sameDayResetCount, 0)

        let nextDayRepository = BusinessRecordRepositorySpy(
            today: .loaded(completed, migration: .current)
        )
        let nextDay = try makeStore(
            repository: nextDayRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )
        await nextDay.restore()
        let nextDayRequest = await nextDay.send(.requestStartToday, source: .panel)
        let nextDayCommit = await nextDay.send(.confirmStartToday, source: .panel)
        XCTAssertEqual(nextDayRequest, .confirmationPresented)
        XCTAssertEqual(nextDayCommit, .committed)
        XCTAssertEqual(nextDay.viewState?.state, .unconfigured)
        let nextDayToday = await nextDayRepository.currentToday()
        XCTAssertNil(nextDayToday)
    }

    func testTodaySnapshotTimezoneWinsAfterEastAndWestSystemTimezoneChanges() async throws {
        let settings = ApplicationTestSupport.committedSettings()

        let shanghai = try BusinessWorkdayCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let westToday = try shanghai.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "Asia/Shanghai",
                year: 2026, month: 8, day: 13, hour: 10
            )
        ).replacingRevision(.init(rawValue: 1))
        let westRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(westToday, migration: .current)
        )
        let westStore = try BusinessStore(
            repository: westRepository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "UTC", year: 2026, month: 8, day: 13, hour: 20
            )),
            timeZoneIdentifier: "Pacific/Honolulu"
        )
        await westStore.restore()
        XCTAssertEqual(westStore.viewState?.state, .awaitingClockOut)
        XCTAssertEqual(westStore.viewState?.todayDateKey, "2026-08-13")
        XCTAssertEqual(westStore.viewState?.todayTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertTrue(westStore.viewState?.isPreviousWorkday ?? false)

        let honolulu = try BusinessWorkdayCalendar(timeZoneIdentifier: "Pacific/Honolulu")
        let eastToday = try honolulu.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "Pacific/Honolulu",
                year: 2026, month: 8, day: 13, hour: 10
            )
        ).replacingRevision(.init(rawValue: 1))
        let eastRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(eastToday, migration: .current)
        )
        let eastStore = try BusinessStore(
            repository: eastRepository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "UTC", year: 2026, month: 8, day: 14, hour: 1
            )),
            timeZoneIdentifier: "Pacific/Kiritimati"
        )
        await eastStore.restore()
        XCTAssertEqual(eastStore.viewState?.state, .earning)
        XCTAssertEqual(eastStore.viewState?.todayDateKey, "2026-08-13")
        XCTAssertEqual(eastStore.viewState?.todayTimeZoneIdentifier, "Pacific/Honolulu")
        XCTAssertFalse(eastStore.viewState?.isPreviousWorkday ?? true)
    }

    func testSameCommandTimestampDerivesPreviousCurrentAndFutureFromTodaySnapshotTimezones() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let commandTimestamp = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: "UTC",
            year: 2026,
            month: 8,
            day: 13,
            hour: 12
        )

        let previousCalendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: "Pacific/Kiritimati"
        )
        let previousToday = try previousCalendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "Pacific/Kiritimati",
                year: 2026,
                month: 8,
                day: 13,
                hour: 10
            )
        ).replacingRevision(.init(rawValue: 1))
        let previousCurrentDateKey = try previousCalendar.currentDateKey(at: commandTimestamp)
        let previousRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(previousToday, migration: .current)
        )
        let previousClock = MutableTestClock(commandTimestamp)
        let previousStore = try BusinessStore(
            repository: previousRepository,
            nowProvider: previousClock,
            timeZoneIdentifier: "Pacific/Honolulu"
        )

        await previousStore.restore()

        XCTAssertEqual(previousClock.sampleCount, 1)
        XCTAssertEqual(previousToday.dateKey, "2026-08-13")
        XCTAssertEqual(previousCurrentDateKey.rawValue, "2026-08-14")
        XCTAssertLessThan(
            try WorkdayKey(validating: previousToday.dateKey),
            previousCurrentDateKey
        )
        XCTAssertEqual(previousStore.viewState?.state, .awaitingClockOut)
        XCTAssertNil(previousStore.viewState?.recoveryReason)
        XCTAssertEqual(previousStore.viewState?.todayDateKey, previousToday.dateKey)
        XCTAssertEqual(
            previousStore.viewState?.todayTimeZoneIdentifier,
            "Pacific/Kiritimati"
        )
        XCTAssertTrue(previousStore.viewState?.isPreviousWorkday ?? false)

        let currentCalendar = try BusinessWorkdayCalendar(timeZoneIdentifier: "UTC")
        let currentToday = try currentCalendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "UTC",
                year: 2026,
                month: 8,
                day: 13,
                hour: 10
            )
        ).replacingRevision(.init(rawValue: 1))
        let currentDateKey = try currentCalendar.currentDateKey(at: commandTimestamp)
        let currentRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(currentToday, migration: .current)
        )
        let currentClock = MutableTestClock(commandTimestamp)
        let currentStore = try BusinessStore(
            repository: currentRepository,
            nowProvider: currentClock,
            timeZoneIdentifier: "Pacific/Kiritimati"
        )

        await currentStore.restore()

        XCTAssertEqual(currentClock.sampleCount, 1)
        XCTAssertEqual(currentToday.dateKey, "2026-08-13")
        XCTAssertEqual(currentDateKey.rawValue, "2026-08-13")
        XCTAssertEqual(try WorkdayKey(validating: currentToday.dateKey), currentDateKey)
        XCTAssertEqual(currentStore.viewState?.state, .earning)
        XCTAssertNil(currentStore.viewState?.recoveryReason)
        XCTAssertEqual(currentStore.viewState?.todayDateKey, currentToday.dateKey)
        XCTAssertEqual(currentStore.viewState?.todayTimeZoneIdentifier, "UTC")
        XCTAssertFalse(currentStore.viewState?.isPreviousWorkday ?? true)

        let futureCalendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: "Pacific/Honolulu"
        )
        let futureToday = try futureCalendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(
                timeZoneIdentifier: "Pacific/Honolulu",
                year: 2026,
                month: 8,
                day: 14,
                hour: 10
            )
        ).replacingRevision(.init(rawValue: 1))
        let futureCurrentDateKey = try futureCalendar.currentDateKey(at: commandTimestamp)
        let futureRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(futureToday, migration: .current)
        )
        let futureClock = MutableTestClock(commandTimestamp)
        let futureStore = try BusinessStore(
            repository: futureRepository,
            nowProvider: futureClock,
            timeZoneIdentifier: "Pacific/Kiritimati"
        )

        await futureStore.restore()

        XCTAssertEqual(futureClock.sampleCount, 1)
        XCTAssertEqual(futureToday.dateKey, "2026-08-14")
        XCTAssertEqual(futureCurrentDateKey.rawValue, "2026-08-13")
        XCTAssertGreaterThan(
            try WorkdayKey(validating: futureToday.dateKey),
            futureCurrentDateKey
        )
        XCTAssertEqual(futureStore.viewState?.state, .recoveryRequired)
        XCTAssertEqual(
            futureStore.viewState?.recoveryReason,
            .futureDatedTodayRecord
        )
        XCTAssertEqual(futureStore.viewState?.todayDateKey, futureToday.dateKey)
        XCTAssertEqual(
            futureStore.viewState?.todayTimeZoneIdentifier,
            "Pacific/Honolulu"
        )
        XCTAssertFalse(futureStore.viewState?.isPreviousWorkday ?? true)
    }

    func testEverySettingsPlanCheckpointFailsBeforeRepositoryForOrdinaryAndDamagedSave() async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        for isDamaged in [false, true] {
            for checkpoint in SaveSettingsPlanCheckpoint.allCases {
                let initial = ApplicationTestSupport.committedSettings()
                let repository = BusinessRecordRepositorySpy(settings: isDamaged
                    ? .damaged(damage)
                    : .loaded(initial, migration: .current))
                let store = try BusinessStore(
                    repository: repository,
                    nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)),
                    timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                        identifier: ApplicationTestSupport.timeZoneIdentifier
                    ),
                    saveSettingsPlanFaultInjector: FailingSaveSettingsPlanFaultInjector(
                        failingCheckpoint: checkpoint
                    )
                )
                await store.restore()
                let oldViewState = store.viewState
                let oldSettingsError = store.settingsReadErrorViewState
                let oldGeneration = store.stateGeneration

                let outcome = await store.send(
                    .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 90_000)),
                    source: .settings
                )
                let saveCount = await repository.settingsSaveCount

                XCTAssertEqual(outcome, .failed(.invalidCalendar), "\(isDamaged)-\(checkpoint)")
                XCTAssertEqual(saveCount, 0, "\(isDamaged)-\(checkpoint)")
                XCTAssertEqual(store.viewState, oldViewState, "\(isDamaged)-\(checkpoint)")
                XCTAssertEqual(store.settingsReadErrorViewState, oldSettingsError,
                               "\(isDamaged)-\(checkpoint)")
                XCTAssertEqual(store.stateGeneration, oldGeneration, "\(isDamaged)-\(checkpoint)")
                XCTAssertNil(settingsSaveReceipt(from: store.feedback), "\(isDamaged)-\(checkpoint)")
                let persisted = await repository.loadSettingsForBusiness()
                if isDamaged {
                    guard case .damaged = persisted else {
                        return XCTFail("Damaged Settings must survive \(checkpoint)")
                    }
                } else {
                    let currentSettings = await repository.currentSettings()
                    XCTAssertEqual(currentSettings, initial)
                }
            }
        }
    }

    func testSaveSettingsPreflightInputValidationFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .inputValidation)
    }

    func testSaveSettingsPreflightCommittedRecordValidationFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .committedRecordValidation)
    }

    func testSaveSettingsPreflightSettingsTypedLoadFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .settingsTypedLoad)
    }

    func testSaveSettingsPreflightTodayTypedLoadFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .todayTypedLoad)
    }

    func testSaveSettingsPreflightDSTGapFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertScheduleSaveSettingsPreflightFailure(
            date: (year: 2026, month: 3, day: 8),
            initial: ApplicationTestSupport.proposedSettings(
                startMinuteOfDay: 60,
                endMinuteOfDay: 4 * 60
            ).replacingRevision(.init(rawValue: 1)),
            input: ApplicationTestSupport.workRules(
                startMinuteOfDay: 2 * 60 + 30,
                endMinuteOfDay: 3 * 60 + 30
            ),
            expected: .nonexistentLocalTime(
                boundary: .start,
                dateKey: "2026-03-08",
                timeZoneIdentifier: "America/New_York"
            )
        )
    }

    func testSaveSettingsPreflightDSTFoldFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertScheduleSaveSettingsPreflightFailure(
            date: (year: 2026, month: 11, day: 1),
            initial: ApplicationTestSupport.proposedSettings(
                startMinuteOfDay: 30,
                endMinuteOfDay: 3 * 60
            ).replacingRevision(.init(rawValue: 1)),
            input: ApplicationTestSupport.workRules(
                startMinuteOfDay: 90,
                endMinuteOfDay: 3 * 60
            ),
            expected: .ambiguousLocalTime(
                boundary: .start,
                dateKey: "2026-11-01",
                timeZoneIdentifier: "America/New_York"
            )
        )
    }

    func testSaveSettingsPreflightTargetBusinessStateConstructionFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .targetBusinessStateConstruction)
    }

    func testSaveSettingsPreflightAmountAndTimeDerivationFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .amountAndTimeDerivation)
    }

    func testSaveSettingsPreflightTargetBusinessViewStateConstructionFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .targetBusinessViewStateConstruction)
    }

    func testSaveSettingsPreflightSuccessEventConstructionFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .successEventConstruction)
    }

    func testSaveSettingsPreflightEncodingFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .encoding)
    }

    func testSaveSettingsPreflightCommitIntentConstructionFailurePreservesOrdinaryAndDamagedState() async throws {
        try await assertInjectedSaveSettingsPreflightFailure(at: .commitIntentConstruction)
    }

    func testInvalidSettingsInputFailsValidationBeforeRepository() async throws {
        let initial = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )
        await store.restore()
        let oldState = store.viewState

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 0)),
            source: .settings
        )
        let saveCount = await repository.settingsSaveCount
        let currentSettings = await repository.currentSettings()

        XCTAssertEqual(outcome, .failed(.invalidCalendar))
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(currentSettings, initial)
        XCTAssertEqual(store.viewState, oldState)
        XCTAssertNil(settingsSaveReceipt(from: store.feedback))
    }

    func testStartTodayDamageFutureAndDeleteFailureAllPreserveToday() async throws {
        let settings = ApplicationTestSupport.committedSettings()
        let previousCompleted = try completedToday(settings: settings, day: 13)
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        let damagedRepository = BusinessRecordRepositorySpy(
            settings: .damaged(damage),
            today: .loaded(previousCompleted, migration: .current)
        )
        let damagedStore = try makeStore(
            repository: damagedRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )
        await damagedStore.restore()
        let damagedRequest = await damagedStore.send(.requestStartToday, source: .panel)
        let damagedResetCount = await damagedRepository.resetTodayCount
        let retainedDamagedToday = await damagedRepository.currentToday()
        XCTAssertEqual(damagedRequest, .rejected(.invalidWorkdayTransition))
        XCTAssertEqual(damagedResetCount, 0)
        XCTAssertEqual(retainedDamagedToday, previousCompleted)

        let futureCompleted = try completedToday(settings: settings, day: 15)
        let futureRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(futureCompleted, migration: .current)
        )
        let futureStore = try makeStore(
            repository: futureRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )
        await futureStore.restore()
        let futureRequest = await futureStore.send(.requestStartToday, source: .panel)
        let futureResetCount = await futureRepository.resetTodayCount
        let retainedFutureToday = await futureRepository.currentToday()
        XCTAssertEqual(futureRequest, .rejected(.invalidWorkdayTransition))
        XCTAssertEqual(futureResetCount, 0)
        XCTAssertEqual(retainedFutureToday, futureCompleted)

        let deleteRepository = BusinessRecordRepositorySpy(
            settings: .loaded(settings, migration: .current),
            today: .loaded(previousCompleted, migration: .current)
        )
        let deleteStore = try makeStore(
            repository: deleteRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )
        await deleteStore.restore()
        let oldViewState = deleteStore.viewState
        let deleteRequest = await deleteStore.send(.requestStartToday, source: .panel)
        XCTAssertEqual(deleteRequest, .confirmationPresented)
        await deleteRepository.failNextReset(with: .deleteFailed)
        let deleteOutcome = await deleteStore.send(.confirmStartToday, source: .panel)
        let retainedAfterDeleteFailure = await deleteRepository.currentToday()
        XCTAssertEqual(deleteOutcome, .failed(.persistence(.deleteFailed)))
        XCTAssertEqual(retainedAfterDeleteFailure, previousCompleted)
        XCTAssertEqual(deleteStore.viewState, oldViewState)
        XCTAssertNil(settingsSaveReceipt(from: deleteStore.feedback))
    }

    func testHeldSettingsSaveRejectsNewCommandAndPublishesOnlyOriginalReceipt() async throws {
        let repository = BusinessRecordRepositorySpy()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        await repository.holdNextSettingsSave()
        let first = Task { @MainActor in
            await store.send(
                .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 80_000)),
                source: .settings
            )
        }
        await repository.waitUntilSettingsSaveIsHeld()

        clock.set(ApplicationTestSupport.timestamp(hour: 9))
        let second = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 90_000)),
            source: .settings
        )
        XCTAssertEqual(second, .rejected(.commandInFlight))
        await repository.resumeHeldSettingsSave()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .committed)

        let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        let committedSettings = await repository.currentSettings()
        let saveCount = await repository.settingsSaveCount
        XCTAssertEqual(receipt.context.timestampMs, ApplicationTestSupport.timestamp(hour: 8))
        XCTAssertEqual(receipt.committedRevision, .init(rawValue: 1))
        XCTAssertEqual(committedSettings?.dailyWageCents, 80_000)
        XCTAssertEqual(saveCount, 1)
    }

    func testDamagedSettingsDSTFailureThenSuccessfulReplacementUsesFreshContextForEveryTodayState() async throws {
        for fold in [false, true] {
            for todayKind in ["missing", "valid", "damaged"] {
                let month = fold ? 11 : 3
                let day = fold ? 1 : 8
                let now = ApplicationTestSupport.timestamp(timeZoneIdentifier: "America/New_York",
                    year: 2026, month: month, day: day, hour: 12)
                let initial = ApplicationTestSupport.committedSettings()
                let today = try preflightTodayFixture(kind: todayKind, settings: initial,
                    at: ApplicationTestSupport.timestamp(timeZoneIdentifier: "America/New_York",
                        year: 2026, month: month, day: day, hour: 0), timeZoneIdentifier: "America/New_York")
                let repository = BusinessRecordRepositorySpy(settings: .damaged(.init(kind: .settings,
                    issue: .decodingFailed, disposition: .requireSettingsRecovery)), today: today)
                let clock = MutableTestClock(now)
                let contexts = CapturingSaveSettingsCommandContextObserver()
                let store = try BusinessStore(repository: repository, nowProvider: clock,
                    timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(identifier: "America/New_York"),
                    saveSettingsCommandContextObserver: contexts)
                await store.restore()
                let before = try await saveSettingsPreflightObservation(store: store, repository: repository)
                let result = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(
                    startMinuteOfDay: fold ? 90 : 150, endMinuteOfDay: 4 * 60)), source: .settings)
                let expected: ScheduleTimeError = fold
                    ? .ambiguousLocalTime(boundary: .start, dateKey: "2026-11-01", timeZoneIdentifier: "America/New_York")
                    : .nonexistentLocalTime(boundary: .start, dateKey: "2026-03-08", timeZoneIdentifier: "America/New_York")
                XCTAssertEqual(result, .failed(.scheduleTime(expected)))
                let afterFailure = try await saveSettingsPreflightObservation(store: store, repository: repository)
                assertSaveSettingsPreflightPreserved(before: before, after: afterFailure,
                    expectedScheduleTimeError: .init(error: expected, context: .proposedSettings),
                    isDamaged: true, label: "damaged-DST-\(fold)-\(todayKind)", file: #filePath, line: #line)
                clock.set(.init(rawValue: now.rawValue + 1_000))
                let success = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(
                    startMinuteOfDay: 4 * 60, endMinuteOfDay: 5 * 60)), source: .settings)
                XCTAssertEqual(success, .committed)
                let entries = contexts.observations.filter { $0.consumer == .commandEntry }.map(\.context)
                XCTAssertEqual(entries.count, 2)
                let first = try XCTUnwrap(entries.first)
                let last = try XCTUnwrap(entries.last)
                XCTAssertNotEqual(first.commandID, last.commandID)
                XCTAssertEqual(first.timestampMs, now)
                XCTAssertEqual(last.timestampMs.rawValue, now.rawValue + 1_000)
                let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
                XCTAssertEqual(receipt.context, last)
                let record = await repository.currentSettings()
                XCTAssertEqual(record?.revision, receipt.committedRevision)
                XCTAssertEqual(record?.updatedAtMs, last.timestampMs.rawValue)
                XCTAssertNil(store.scheduleTimeErrorViewState)
                XCTAssertNil(store.settingsReadErrorViewState)
                let writes = await repository.settingsSuccessfulWriteCount
                let retainedToday = try await repository.currentTodayCanonicalBytes()
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(retainedToday, before.repositoryTodayBytes)
                let expectedState: WorkdayState = todayKind == "missing" ? .ready : (todayKind == "valid" ? .earning : .recoveryRequired)
                XCTAssertEqual(store.viewState?.state, expectedState)
            }
        }
    }

    func testDamagedSettingsCommitConflictsAndIOFailuresPreserveAllThreeTodayStates() async throws {
        let settingsDamage = DamagedRecordResult(kind: .settings, issue: .decodingFailed,
            disposition: .requireSettingsRecovery)
        for todayKind in ["missing", "valid", "damaged"] {
            for fault in ["conflict", "io"] {
                let label = "damaged-\(todayKind)-\(fault)"
                let initial = ApplicationTestSupport.committedSettings()
                let today = try preflightTodayFixture(kind: todayKind, settings: initial,
                    at: ApplicationTestSupport.timestamp(hour: 7),
                    timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                let repository = BusinessRecordRepositorySpy(settings: .damaged(settingsDamage), today: today)
                let store = try makeStore(repository: repository,
                    clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)))
                await store.restore()
                let todayBytes = try await repository.currentTodayCanonicalBytes()
                if fault == "conflict" {
                    let external = ApplicationTestSupport.proposedSettings(wageCents: 84_000)
                        .replacingRevision(.init(rawValue: 1))
                    try await assertHeldSettingsConflictPreservesCompleteMatrix(store: store,
                        repository: repository, expectedStaleToken: .damaged(Data([0x44])),
                        externalRecord: external, expectedConflict: .revisionConflict(expected: nil,
                            actual: .init(rawValue: 1)), label: label)
                } else {
                    let before = try await settingsCommitFailureObservation(store: store, repository: repository)
                    await repository.failNextSettingsSave(with: .atomicWriteFailed)
                    let result = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)), source: .settings)
                    XCTAssertEqual(result, .failed(.persistence(.atomicWriteFailed)), label)
                    let after = try await settingsCommitFailureObservation(store: store, repository: repository)
                    assertSettingsCommitFailurePreserved(beforeCommand: before, protectedRepositoryState: before,
                        afterCommand: after, expectedFailure: .persistence(.atomicWriteFailed),
                        expectedExternalWriteDelta: 0, label: label)
                }
                let retainedTodayBytes = try await repository.currentTodayCanonicalBytes()
                let todaySaves = await repository.todaySaveCount
                let todayDeletes = await repository.resetTodayCount
                XCTAssertEqual(retainedTodayBytes, todayBytes, label)
                XCTAssertEqual(todaySaves, 0, label)
                XCTAssertEqual(todayDeletes, 0, label)
            }
        }
    }

    func testDamagedSettingsCommitSuccessPublishesOnceWithoutAnyPostCommitDerivationForAllTodayStates() async throws {
        for todayKind in ["missing", "valid", "damaged"] {
            let initial = ApplicationTestSupport.committedSettings()
            let today = try preflightTodayFixture(kind: todayKind, settings: initial,
                at: ApplicationTestSupport.timestamp(hour: 7),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            let repository = BusinessRecordRepositorySpy(settings: .damaged(.init(kind: .settings,
                issue: .decodingFailed, disposition: .requireSettingsRecovery)), today: today)
            let observer = FailOnPostCommitSaveSettingsExecutionObserver()
            let resolver = CommitAwareScheduleResolver()
            await repository.observeSettingsCommitSuccess {
                observer.markRepositoryCommitSucceeded()
                resolver.markCommitted()
            }
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
                timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(identifier: ApplicationTestSupport.timeZoneIdentifier),
                scheduleResolver: resolver, saveSettingsExecutionObserver: observer)
            await store.restore()
            let todayBytes = try await repository.currentTodayCanonicalBytes()
            let token = store.todayTokenForValidation
            let result = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)), source: .settings)
            XCTAssertEqual(result, .committed, todayKind)
            let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
            let loadedRecord = await repository.currentSettings()
            let record = try XCTUnwrap(loadedRecord)
            XCTAssertEqual(record.revision, receipt.committedRevision, todayKind)
            XCTAssertEqual(record.dailyWageCents, 88_000, todayKind)
            XCTAssertEqual(store.settingsRecordForValidation, record, todayKind)
            XCTAssertEqual(store.todayTokenForValidation, token, todayKind)
            XCTAssertNil(store.settingsReadErrorViewState, todayKind)
            XCTAssertEqual(observer.observation.postCommitStateDerivationCount, 0, todayKind)
            XCTAssertEqual(observer.observation.postCommitEarningsCalculationCount, 0, todayKind)
            XCTAssertEqual(observer.observation.postCommitViewStateConstructionCount, 0, todayKind)
            XCTAssertEqual(observer.observation.successPublicationCount, 1, todayKind)
            XCTAssertEqual(observer.observation.prematureSuccessPublicationCount, 0, todayKind)
            XCTAssertEqual(observer.postCommitParsingCount, 0, todayKind)
            XCTAssertEqual(observer.postCommitReconcileCount, 0, todayKind)
            XCTAssertEqual(resolver.postCommitCalls, 0, todayKind)
            XCTAssertGreaterThan(resolver.preCommitCalls, 0, todayKind)
            let retainedToday = try await repository.currentTodayCanonicalBytes()
            XCTAssertEqual(retainedToday, todayBytes, todayKind)
            let writes = await repository.settingsSuccessfulWriteCount
            let temps = await repository.settingsTemporaryWriteCount
            let todayWrites = await repository.todaySaveCount
            let deletes = await repository.resetTodayCount
            XCTAssertEqual(writes, 1, todayKind); XCTAssertEqual(temps, 1, todayKind)
            XCTAssertEqual(todayWrites, 0, todayKind); XCTAssertEqual(deletes, 0, todayKind)
            let expected: WorkdayState = todayKind == "missing" ? .ready : (todayKind == "valid" ? .earning : .recoveryRequired)
            XCTAssertEqual(store.viewState?.state, expected, todayKind)
            if todayKind == "damaged" { XCTAssertEqual(store.viewState?.amount, .hidden) }
        }
    }

    func testDamagedSettingsReplacementSuccessHasNoPostCommitResolverCall() async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        let repository = BusinessRecordRepositorySpy(settings: .damaged(damage))
        let resolver = CountingScheduleResolver(allowedCalls: 2)
        let store = try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)),
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                identifier: ApplicationTestSupport.timeZoneIdentifier
            ),
            scheduleResolver: resolver
        )
        await store.restore()
        XCTAssertEqual(resolver.callCount, 0)

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(resolver.callCount, 2)
        XCTAssertEqual(store.viewState?.state, .ready)
        let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        let persisted = await repository.currentSettings()
        XCTAssertEqual(persisted?.revision, receipt.committedRevision)
        XCTAssertNil(store.settingsReadErrorViewState)
    }

    func testHeldStaleSettingsConflictCannotOverwriteExternalRevisionOrViewState() async throws {
        let initial = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )
        await store.restore()
        let oldViewState = store.viewState
        await repository.holdNextSettingsSave()
        let save = Task { @MainActor in
            await store.send(
                .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 80_000)),
                source: .settings
            )
        }
        await repository.waitUntilSettingsSaveIsHeld()
        let external = ApplicationTestSupport.proposedSettings(wageCents: 95_000)
            .replacingRevision(.init(rawValue: 2))
        await repository.replaceSettingsExternally(external)
        await repository.resumeHeldSettingsSave()

        let outcome = await save.value
        let persisted = await repository.currentSettings()
        XCTAssertEqual(outcome, .failed(.persistence(.revisionConflict(
            expected: .init(rawValue: 1), actual: .init(rawValue: 2)
        ))))
        XCTAssertEqual(persisted, external)
        XCTAssertEqual(store.viewState, oldViewState)
        XCTAssertNil(settingsSaveReceipt(from: store.feedback))
    }

    func testSaveSettingsLoadedRevisionConflictPreservesCompleteBusinessStoreMatrix() async throws {
        let initial = ApplicationTestSupport.committedSettings(wageCents: 30_000)
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        let external = ApplicationTestSupport.proposedSettings(wageCents: 95_000)
            .replacingRevision(.init(rawValue: 2))
        let conflict = PersistenceError.revisionConflict(
            expected: .init(rawValue: 1),
            actual: .init(rawValue: 2)
        )

        try await assertHeldSettingsConflictPreservesCompleteMatrix(
            store: store,
            repository: repository,
            expectedStaleToken: .loaded(.init(rawValue: 1)),
            externalRecord: external,
            expectedConflict: conflict,
            label: "loaded-revision-conflict"
        )
    }

    func testSaveSettingsStaleMissingTokenConflictPreservesExternalRecordAndCompleteBusinessStoreMatrix() async throws {
        let repository = BusinessRecordRepositorySpy()
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        let external = ApplicationTestSupport.proposedSettings(wageCents: 72_000)
            .replacingRevision(.init(rawValue: 1))
        let conflict = PersistenceError.revisionConflict(
            expected: nil,
            actual: .init(rawValue: 1)
        )

        try await assertHeldSettingsConflictPreservesCompleteMatrix(
            store: store,
            repository: repository,
            expectedStaleToken: .missing,
            externalRecord: external,
            expectedConflict: conflict,
            label: "stale-missing-token-conflict"
        )
    }

    func testSaveSettingsStaleDamageTokenConflictPreservesExternalRecordAndCompleteBusinessStoreMatrix() async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        let repository = BusinessRecordRepositorySpy(settings: .damaged(damage))
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        let staleDamageTokenA = SettingsRecordToken.damaged(Data([0x44]))
        let externalRecordB = ApplicationTestSupport.proposedSettings(wageCents: 84_000)
            .replacingRevision(.init(rawValue: 1))
        let conflict = PersistenceError.revisionConflict(
            expected: nil,
            actual: .init(rawValue: 1)
        )

        try await assertHeldSettingsConflictPreservesCompleteMatrix(
            store: store,
            repository: repository,
            expectedStaleToken: staleDamageTokenA,
            externalRecord: externalRecordB,
            expectedConflict: conflict,
            label: "stale-damage-token-A-to-external-record-B-conflict"
        )
    }

    func testSaveSettingsAtomicWriteFailurePreservesCompleteBusinessStoreMatrix() async throws {
        let initial = ApplicationTestSupport.committedSettings(wageCents: 30_000)
        let repository = BusinessRecordRepositorySpy(
            settings: .loaded(initial, migration: .current)
        )
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        )
        await store.restore()
        let before = try await settingsCommitFailureObservation(
            store: store,
            repository: repository
        )
        await repository.failNextSettingsSave(with: .atomicWriteFailed)

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)),
            source: .settings
        )
        let after = try await settingsCommitFailureObservation(
            store: store,
            repository: repository
        )
        let failure = BusinessFailure.persistence(.atomicWriteFailed)

        XCTAssertEqual(outcome, .failed(failure))
        assertSettingsCommitFailurePreserved(
            beforeCommand: before,
            protectedRepositoryState: before,
            afterCommand: after,
            expectedFailure: failure,
            expectedExternalWriteDelta: 0,
            label: "atomic-write-I/O-failure"
        )
    }

    func testResultGuardRejectsStaleFailureAndCommittedBindings() {
        let commandA = UUID()
        let commandB = UUID()

        XCTAssertTrue(BusinessCommandResultGuard.accepts(
            commandID: commandA,
            expectedStoreGeneration: 4,
            activeCommandID: commandA,
            currentStoreGeneration: 4
        ))
        XCTAssertFalse(BusinessCommandResultGuard.accepts(
            commandID: commandA,
            expectedStoreGeneration: 4,
            activeCommandID: commandB,
            currentStoreGeneration: 4
        ))
        XCTAssertFalse(BusinessCommandResultGuard.accepts(
            commandID: commandA,
            expectedStoreGeneration: 4,
            activeCommandID: commandA,
            currentStoreGeneration: 5
        ))
    }

    func testSettingsCommitRestoresTargetAndRevisionAfterProcessRestart() async throws {
        let repository = BusinessRecordRepositorySpy()
        let firstStore = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )
        await firstStore.restore()
        let outcome = await firstStore.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)),
            source: .settings
        )
        let firstReceipt = try XCTUnwrap(settingsSaveReceipt(from: firstStore.feedback))
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(firstReceipt.committedRevision, .init(rawValue: 1))

        let restarted = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        )
        await restarted.restore()
        let persisted = await repository.currentSettings()

        XCTAssertEqual(persisted?.revision, firstReceipt.committedRevision)
        XCTAssertEqual(persisted?.dailyWageCents, 88_000)
        XCTAssertEqual(restarted.viewState?.state, .ready)
        XCTAssertNil(restarted.feedback)
        XCTAssertNil(restarted.scheduleTimeErrorViewState)
    }

    func testHeldSettingsSaveFreezesClockAndTimeZoneAcrossEveryContextConsumer() async throws {
        let originalTimestamp = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: "Asia/Shanghai",
            year: 2026,
            month: 9,
            day: 2,
            hour: 8
        )
        let changedTimestamp = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: "Pacific/Honolulu",
            year: 2026,
            month: 9,
            day: 3,
            hour: 10
        )
        let repository = BusinessRecordRepositorySpy()
        let clock = MutableTestClock(originalTimestamp)
        let timeZone = MutableTestTimeZoneIdentifierProvider("Asia/Shanghai")
        let observer = CapturingSaveSettingsCommandContextObserver()
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifierProvider: timeZone,
            saveSettingsCommandContextObserver: observer
        )
        await store.restore()
        clock.resetSampleCount()
        timeZone.resetSampleCount()
        await repository.holdNextSettingsSave()

        let save = Task { @MainActor in
            await store.send(
                .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 81_000)),
                source: .settings
            )
        }
        await repository.waitUntilSettingsSaveIsHeld()
        clock.set(changedTimestamp)
        timeZone.set("Pacific/Honolulu")
        await repository.resumeHeldSettingsSave()

        let saveOutcome = await save.value
        XCTAssertEqual(saveOutcome, .committed)
        XCTAssertEqual(clock.sampleCount, 1)
        XCTAssertEqual(timeZone.sampleCount, 1)
        let observations = observer.observations
        let entry = try XCTUnwrap(observations.first { $0.consumer == .commandEntry })
        XCTAssertEqual(entry.context.timestampMs, originalTimestamp)
        XCTAssertEqual(entry.context.commandTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(entry.context.commandDateKey.rawValue, "2026-09-02")
        XCTAssertNotEqual(entry.context.timestampMs, changedTimestamp)
        XCTAssertNotEqual(entry.context.commandTimeZoneIdentifier, "Pacific/Honolulu")
        XCTAssertEqual(Set(observations.map(\.consumer)), Set(SaveSettingsContextConsumer.allCases))
        for consumer in SaveSettingsContextConsumer.allCases {
            let matches = observations.filter { $0.consumer == consumer }
            XCTAssertEqual(matches.count, 1, "consumer=\(consumer)")
            XCTAssertEqual(matches.first?.context, entry.context, "consumer=\(consumer)")
        }
        let receipt = try XCTUnwrap(settingsSaveReceipt(from: store.feedback))
        XCTAssertEqual(receipt.context, entry.context)
        let currentSettings = await repository.currentSettings()
        let persisted = try XCTUnwrap(currentSettings)
        XCTAssertEqual(persisted.updatedAtMs, entry.context.timestampMs.rawValue)
        XCTAssertEqual(persisted.dailyWageCents, 81_000)
    }

    func testDelayedSettingsValidationCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .validation
        )
    }

    func testDelayedSettingsErrorCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .error
        )
    }

    func testDelayedSettingsConflictCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .conflict
        )
    }

    func testDelayedSettingsIOFailureCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .ioFailure
        )
    }

    func testDelayedSettingsCommittedRevisionCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .committedRevision
        )
    }

    func testDelayedSettingsSuccessCannotOverwriteAcceptedNewCommand() async throws {
        try await assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
            scenario: .success
        )
    }

    private enum DelayedSettingsResultScenario: String {
        case validation
        case error
        case conflict
        case ioFailure
        case committedRevision
        case success
    }

    private struct T013ProtectedState: Equatable {
        let repositorySettings: SettingsRecord?
        let repositoryToken: SettingsRecordToken
        let repositorySaveCount: Int
        let repositorySuccessfulWriteCount: Int
        let repositoryTemporaryWriteCount: Int
        let storeSettings: SettingsRecord?
        let storeToken: SettingsRecordToken
        let workRules: WorkRuleSettingsInput?
        let viewState: BusinessViewState?
        let settingsReadError: SettingsReadErrorViewState?
        let scheduleTimeError: ScheduleTimeErrorViewState?
        let confirmation: BusinessConfirmation?
        let feedback: BusinessFeedback?
        let receipt: SettingsSaveReceipt?
        let stateGeneration: UInt64
        let commandPhase: BusinessCommandPhase
        let isCommandInFlight: Bool
    }

    private func assertDelayedSettingsResultCannotOverwriteAcceptedNewCommand(
        scenario: DelayedSettingsResultScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let usesDSTValidation = scenario == .validation
        let timeZoneIdentifier = usesDSTValidation ? "America/New_York" : "Asia/Shanghai"
        let initialTimestamp = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: timeZoneIdentifier,
            year: 2026,
            month: usesDSTValidation ? 3 : 9,
            day: usesDSTValidation ? 8 : 2,
            hour: usesDSTValidation ? 12 : 8
        )
        let initialSettings = ApplicationTestSupport.proposedSettings(
            startMinuteOfDay: usesDSTValidation ? 60 : 9 * 60,
            endMinuteOfDay: usesDSTValidation ? 4 * 60 : 18 * 60
        ).replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(
            settings: usesDSTValidation ? .loaded(initialSettings, migration: .current) : .missing
        )
        let clock = MutableTestClock(initialTimestamp)
        let deliveryController = HoldingSaveSettingsResultDeliveryController()
        let faultInjector: any SaveSettingsPlanFaultInjecting = scenario == .error
            ? FailNextSaveSettingsPlanFaultInjector(
                failingCheckpoint: .targetBusinessStateConstruction
            )
            : NoSaveSettingsPlanFaultInjector()
        let store = try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                identifier: timeZoneIdentifier
            ),
            saveSettingsPlanFaultInjector: faultInjector,
            saveSettingsResultDeliveryController: deliveryController
        )
        await store.restore()
        deliveryController.holdNext()

        let conflict = PersistenceError.revisionConflict(
            expected: nil,
            actual: .init(rawValue: 1)
        )
        let externalRecord = ApplicationTestSupport.proposedSettings(
            wageCents: 55_000,
            updatedAtMs: initialTimestamp.rawValue + 1
        ).replacingRevision(.init(rawValue: 1))
        switch scenario {
        case .conflict:
            await repository.failNextSettingsSave(
                with: conflict,
                thenReplaceSettingsWith: externalRecord
            )
        case .ioFailure:
            await repository.failNextSettingsSave(with: .atomicWriteFailed)
        default:
            break
        }

        let oldInput = usesDSTValidation
            ? ApplicationTestSupport.workRules(
                wageCents: 70_000,
                startMinuteOfDay: 2 * 60 + 30,
                endMinuteOfDay: 3 * 60 + 30
            )
            : ApplicationTestSupport.workRules(wageCents: 70_000)
        let oldOutcome = await store.send(.saveWorkRules(oldInput), source: .settings)
        let expectedDeliveryKind: SaveSettingsResultDeliveryKind
        switch scenario {
        case .validation:
            expectedDeliveryKind = .validationFailure
            XCTAssertEqual(oldOutcome, .failed(.scheduleTime(.nonexistentLocalTime(
                boundary: .start,
                dateKey: "2026-03-08",
                timeZoneIdentifier: "America/New_York"
            ))), file: file, line: line)
        case .error:
            expectedDeliveryKind = .errorFailure
            XCTAssertEqual(oldOutcome, .failed(.invalidCalendar), file: file, line: line)
        case .conflict:
            expectedDeliveryKind = .conflictFailure
            XCTAssertEqual(oldOutcome, .failed(.persistence(conflict)), file: file, line: line)
        case .ioFailure:
            expectedDeliveryKind = .ioFailure
            XCTAssertEqual(oldOutcome, .failed(.persistence(.atomicWriteFailed)), file: file, line: line)
        case .committedRevision, .success:
            expectedDeliveryKind = .committed
            XCTAssertEqual(oldOutcome, .committed, file: file, line: line)
        }
        let held = try XCTUnwrap(deliveryController.heldDelivery, file: file, line: line)
        XCTAssertEqual(held.kind, expectedDeliveryKind, file: file, line: line)
        XCTAssertFalse(store.isCommandInFlight, file: file, line: line)
        XCTAssertEqual(store.commandPhase, .idle, file: file, line: line)

        if scenario == .conflict || scenario == .committedRevision || scenario == .success {
            await store.restore()
        }
        let nextTimestamp = ApplicationTestSupport.timestamp(
            timeZoneIdentifier: timeZoneIdentifier,
            year: 2026,
            month: usesDSTValidation ? 3 : 9,
            day: usesDSTValidation ? 8 : 2,
            hour: usesDSTValidation ? 13 : 9
        )
        clock.set(nextTimestamp)
        let newOutcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(
                wageCents: 90_000,
                startMinuteOfDay: usesDSTValidation ? 4 * 60 : 9 * 60,
                endMinuteOfDay: usesDSTValidation ? 5 * 60 : 18 * 60
            )),
            source: .settings
        )
        XCTAssertEqual(newOutcome, .committed, scenario.rawValue, file: file, line: line)
        let acceptedReceipt = try XCTUnwrap(
            settingsSaveReceipt(from: store.feedback),
            file: file,
            line: line
        )
        XCTAssertNotEqual(acceptedReceipt.context.commandID, held.context.commandID,
                          scenario.rawValue, file: file, line: line)
        XCTAssertEqual(acceptedReceipt.context.timestampMs, nextTimestamp,
                       scenario.rawValue, file: file, line: line)
        let protected = await t013ProtectedState(store: store, repository: repository)

        deliveryController.releaseHeld()
        let afterOldDelivery = await t013ProtectedState(store: store, repository: repository)

        XCTAssertEqual(afterOldDelivery, protected, scenario.rawValue, file: file, line: line)
        XCTAssertEqual(afterOldDelivery.repositorySettings?.dailyWageCents, 90_000,
                       scenario.rawValue, file: file, line: line)
        XCTAssertEqual(afterOldDelivery.storeSettings?.revision, acceptedReceipt.committedRevision,
                       scenario.rawValue, file: file, line: line)
        XCTAssertEqual(afterOldDelivery.receipt, acceptedReceipt,
                       scenario.rawValue, file: file, line: line)
        XCTAssertEqual(deliveryController.deliveredKinds, [expectedDeliveryKind, .committed],
                       scenario.rawValue, file: file, line: line)
    }

    private func t013ProtectedState(
        store: BusinessStore,
        repository: BusinessRecordRepositorySpy
    ) async -> T013ProtectedState {
        T013ProtectedState(
            repositorySettings: await repository.currentSettings(),
            repositoryToken: await repository.currentSettingsToken(),
            repositorySaveCount: await repository.settingsSaveCount,
            repositorySuccessfulWriteCount: await repository.settingsSuccessfulWriteCount,
            repositoryTemporaryWriteCount: await repository.settingsTemporaryWriteCount,
            storeSettings: store.settingsRecordForValidation,
            storeToken: store.settingsTokenForValidation,
            workRules: store.currentWorkRules,
            viewState: store.viewState,
            settingsReadError: store.settingsReadErrorViewState,
            scheduleTimeError: store.scheduleTimeErrorViewState,
            confirmation: store.confirmation,
            feedback: store.feedback,
            receipt: settingsSaveReceipt(from: store.feedback),
            stateGeneration: store.stateGeneration,
            commandPhase: store.commandPhase,
            isCommandInFlight: store.isCommandInFlight
        )
    }

    private struct SettingsCommitFailureObservation {
        let repositorySettings: SettingsRecord?
        let repositorySettingsToken: SettingsRecordToken
        let repositorySettingsBytes: Data?
        let repositoryCommitAttemptCount: Int
        let repositorySuccessfulWriteCount: Int
        let repositoryTemporaryWriteCount: Int
        let repositoryExternalWriteCount: Int
        let storeSettingsRecord: SettingsRecord?
        let storeSettingsToken: SettingsRecordToken
        let workRules: WorkRuleSettingsInput?
        let hasDamagedSettings: Bool
        let viewState: BusinessViewState?
        let settingsReadError: SettingsReadErrorViewState?
        let scheduleTimeError: ScheduleTimeErrorViewState?
        let confirmation: BusinessConfirmation?
        let feedback: BusinessFeedback?
        let stateGeneration: UInt64
    }

    private func assertHeldSettingsConflictPreservesCompleteMatrix(
        store: BusinessStore,
        repository: BusinessRecordRepositorySpy,
        expectedStaleToken: SettingsRecordToken,
        externalRecord: SettingsRecord,
        expectedConflict: PersistenceError,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let beforeCommand = try await settingsCommitFailureObservation(
            store: store,
            repository: repository
        )
        XCTAssertEqual(beforeCommand.storeSettingsToken, expectedStaleToken,
                       label, file: file, line: line)
        XCTAssertEqual(beforeCommand.repositorySettingsToken, expectedStaleToken,
                       label, file: file, line: line)
        await repository.holdNextSettingsSave()
        let save = Task { @MainActor in
            await store.send(
                .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 99_000)),
                source: .settings
            )
        }
        await repository.waitUntilSettingsSaveIsHeld()

        await repository.replaceSettingsExternally(externalRecord)
        let afterExternalWriter = try await settingsCommitFailureObservation(
            store: store,
            repository: repository
        )
        XCTAssertEqual(afterExternalWriter.repositorySettings, externalRecord,
                       label, file: file, line: line)
        XCTAssertEqual(afterExternalWriter.repositorySettingsToken, .loaded(externalRecord.revision),
                       label, file: file, line: line)
        XCTAssertEqual(afterExternalWriter.repositoryExternalWriteCount,
                       beforeCommand.repositoryExternalWriteCount + 1,
                       label, file: file, line: line)
        XCTAssertEqual(afterExternalWriter.repositorySuccessfulWriteCount,
                       beforeCommand.repositorySuccessfulWriteCount,
                       label, file: file, line: line)
        XCTAssertEqual(afterExternalWriter.repositoryTemporaryWriteCount,
                       beforeCommand.repositoryTemporaryWriteCount,
                       label, file: file, line: line)
        await repository.resumeHeldSettingsSave()

        let outcome = await save.value
        let afterCommand = try await settingsCommitFailureObservation(
            store: store,
            repository: repository
        )
        let failure = BusinessFailure.persistence(expectedConflict)
        XCTAssertEqual(outcome, .failed(failure), label, file: file, line: line)
        assertSettingsCommitFailurePreserved(
            beforeCommand: beforeCommand,
            protectedRepositoryState: afterExternalWriter,
            afterCommand: afterCommand,
            expectedFailure: failure,
            expectedExternalWriteDelta: 1,
            label: label,
            file: file,
            line: line
        )
    }

    private func settingsCommitFailureObservation(
        store: BusinessStore,
        repository: BusinessRecordRepositorySpy
    ) async throws -> SettingsCommitFailureObservation {
        SettingsCommitFailureObservation(
            repositorySettings: await repository.currentSettings(),
            repositorySettingsToken: await repository.currentSettingsToken(),
            repositorySettingsBytes: try await repository.currentSettingsCanonicalBytes(),
            repositoryCommitAttemptCount: await repository.settingsSaveCount,
            repositorySuccessfulWriteCount: await repository.settingsSuccessfulWriteCount,
            repositoryTemporaryWriteCount: await repository.settingsTemporaryWriteCount,
            repositoryExternalWriteCount: await repository.settingsExternalWriteCount,
            storeSettingsRecord: store.settingsRecordForValidation,
            storeSettingsToken: store.settingsTokenForValidation,
            workRules: store.currentWorkRules,
            hasDamagedSettings: store.hasDamagedSettings,
            viewState: store.viewState,
            settingsReadError: store.settingsReadErrorViewState,
            scheduleTimeError: store.scheduleTimeErrorViewState,
            confirmation: store.confirmation,
            feedback: store.feedback,
            stateGeneration: store.stateGeneration
        )
    }

    private func assertSettingsCommitFailurePreserved(
        beforeCommand: SettingsCommitFailureObservation,
        protectedRepositoryState: SettingsCommitFailureObservation,
        afterCommand: SettingsCommitFailureObservation,
        expectedFailure: BusinessFailure,
        expectedExternalWriteDelta: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(afterCommand.repositoryCommitAttemptCount,
                       beforeCommand.repositoryCommitAttemptCount + 1,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositorySuccessfulWriteCount,
                       beforeCommand.repositorySuccessfulWriteCount,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositorySuccessfulWriteCount, 0,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositoryTemporaryWriteCount,
                       beforeCommand.repositoryTemporaryWriteCount,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositoryTemporaryWriteCount, 0,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositoryExternalWriteCount,
                       beforeCommand.repositoryExternalWriteCount + expectedExternalWriteDelta,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositoryExternalWriteCount,
                       protectedRepositoryState.repositoryExternalWriteCount,
                       label, file: file, line: line)

        XCTAssertEqual(afterCommand.repositorySettings,
                       protectedRepositoryState.repositorySettings,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositorySettingsToken,
                       protectedRepositoryState.repositorySettingsToken,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositorySettingsBytes,
                       protectedRepositoryState.repositorySettingsBytes,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.repositorySettings?.revision,
                       protectedRepositoryState.repositorySettings?.revision,
                       label, file: file, line: line)

        XCTAssertEqual(afterCommand.storeSettingsRecord, beforeCommand.storeSettingsRecord,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.storeSettingsRecord?.revision,
                       beforeCommand.storeSettingsRecord?.revision,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.storeSettingsToken, beforeCommand.storeSettingsToken,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.workRules, beforeCommand.workRules,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.hasDamagedSettings, beforeCommand.hasDamagedSettings,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.viewState, beforeCommand.viewState,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.settingsReadError, beforeCommand.settingsReadError,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.scheduleTimeError, beforeCommand.scheduleTimeError,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.confirmation, beforeCommand.confirmation,
                       label, file: file, line: line)
        XCTAssertEqual(afterCommand.stateGeneration, beforeCommand.stateGeneration,
                       label, file: file, line: line)

        XCTAssertEqual(afterCommand.feedback,
                       .commandFailed(.saveWorkRules, expectedFailure),
                       label, file: file, line: line)
        XCTAssertNil(settingsSaveReceipt(from: afterCommand.feedback),
                     label, file: file, line: line)
    }

    private struct SaveSettingsPreflightObservation {
        let repositorySettings: SettingsRecord?
        let repositorySettingsToken: SettingsRecordToken
        let repositorySettingsBytes: Data?
        let repositoryToday: TodayRecord?
        let repositoryTodayToken: TodayRecordToken
        let repositoryTodayBytes: Data?
        let repositoryTodaySaveCount: Int
        let repositoryTodayDeleteCount: Int
        let repositorySettingsLoadCount: Int
        let repositoryTodayLoadCount: Int
        let repositorySaveCount: Int
        let repositoryTemporaryWriteCount: Int
        let storeSettingsRecord: SettingsRecord?
        let storeSettingsToken: SettingsRecordToken
        let storeTodayRecord: TodayRecord?
        let storeTodayToken: TodayRecordToken
        let workRules: WorkRuleSettingsInput?
        let hasDamagedSettings: Bool
        let viewState: BusinessViewState?
        let settingsReadError: SettingsReadErrorViewState?
        let scheduleTimeError: ScheduleTimeErrorViewState?
        let confirmation: BusinessConfirmation?
        let saveReceipt: SettingsSaveReceipt?
        let stateGeneration: UInt64
        let savingPhaseCount: Int
        let commandPhase: BusinessCommandPhase
        let isCommandInFlight: Bool
    }

    private func assertInjectedSaveSettingsPreflightFailure(
        at checkpoint: SaveSettingsPlanCheckpoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        for isDamaged in [false, true] {
          for todayKind in ["missing", "valid", "damaged"] {
            let initial = ApplicationTestSupport.committedSettings()
            let today = try preflightTodayFixture(kind: todayKind, settings: initial,
                at: ApplicationTestSupport.timestamp(hour: 7),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            let repository = BusinessRecordRepositorySpy(settings: isDamaged
                ? .damaged(damage)
                : .loaded(initial, migration: .current), today: today)
            let store = try BusinessStore(
                repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)),
                timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(
                    identifier: ApplicationTestSupport.timeZoneIdentifier
                ),
                saveSettingsPlanFaultInjector: FailingSaveSettingsPlanFaultInjector(
                    failingCheckpoint: checkpoint
                )
            )
            await store.restore()
            await repository.resetBusinessLoadCountsForValidation()
            let before = try await saveSettingsPreflightObservation(
                store: store,
                repository: repository
            )

            let outcome = await store.send(
                .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 90_000)),
                source: .settings
            )
            let after = try await saveSettingsPreflightObservation(
                store: store,
                repository: repository
            )
            let label = "\(isDamaged ? "damaged" : "ordinary")-today-\(todayKind)-\(checkpoint)"

            XCTAssertEqual(outcome, .failed(.invalidCalendar), label, file: file, line: line)
            XCTAssertEqual(
                store.feedback,
                .commandFailed(.saveWorkRules, .invalidCalendar),
                label,
                file: file,
                line: line
            )
            switch checkpoint {
            case .settingsTypedLoad:
                XCTAssertEqual(after.repositorySettingsLoadCount, 0, label, file: file, line: line)
            case .todayTypedLoad:
                XCTAssertEqual(after.repositoryTodayLoadCount, 0, label, file: file, line: line)
            default:
                break
            }
            assertSaveSettingsPreflightPreserved(
                before: before,
                after: after,
                expectedScheduleTimeError: before.scheduleTimeError,
                isDamaged: isDamaged,
                label: label,
                file: file,
                line: line
            )
          }
        }
    }

    private func assertScheduleSaveSettingsPreflightFailure(
        date: (year: Int, month: Int, day: Int),
        initial: SettingsRecord,
        input: WorkRuleSettingsInput,
        expected: ScheduleTimeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let damage = DamagedRecordResult(
            kind: .settings,
            issue: .decodingFailed,
            disposition: .requireSettingsRecovery
        )
        for isDamaged in [false, true] {
          for todayKind in ["missing", "valid", "damaged"] {
            let today = try preflightTodayFixture(kind: todayKind, settings: initial,
                at: ApplicationTestSupport.timestamp(timeZoneIdentifier: "America/New_York",
                    year: date.year, month: date.month, day: date.day, hour: 0),
                timeZoneIdentifier: "America/New_York")
            let repository = BusinessRecordRepositorySpy(settings: isDamaged
                ? .damaged(damage)
                : .loaded(initial, migration: .current), today: today)
            let store = try BusinessStore(
                repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(
                    timeZoneIdentifier: "America/New_York",
                    year: date.year,
                    month: date.month,
                    day: date.day,
                    hour: 12
                )),
                timeZoneIdentifier: "America/New_York"
            )
            await store.restore()
            await repository.resetBusinessLoadCountsForValidation()
            let before = try await saveSettingsPreflightObservation(
                store: store,
                repository: repository
            )

            let outcome = await store.send(.saveWorkRules(input), source: .settings)
            let after = try await saveSettingsPreflightObservation(
                store: store,
                repository: repository
            )
            let label = "\(isDamaged ? "damaged" : "ordinary")-today-\(todayKind)-\(expected)"

            XCTAssertEqual(outcome, .failed(.scheduleTime(expected)), label, file: file, line: line)
            XCTAssertNil(store.feedback, label, file: file, line: line)
            XCTAssertFalse(store.hasBlockingScheduleError,
                "Ordinary valid state stays visible; damaged Settings retain their own recovery surface", file: file, line: line)
            assertSaveSettingsPreflightPreserved(
                before: before,
                after: after,
                expectedScheduleTimeError: .init(error: expected, context: .proposedSettings),
                isDamaged: isDamaged,
                label: label,
                file: file,
                line: line
            )
          }
        }
    }

    private func saveSettingsPreflightObservation(
        store: BusinessStore,
        repository: BusinessRecordRepositorySpy
    ) async throws -> SaveSettingsPreflightObservation {
        SaveSettingsPreflightObservation(
            repositorySettings: await repository.currentSettings(),
            repositorySettingsToken: await repository.currentSettingsToken(),
            repositorySettingsBytes: try await repository.currentSettingsCanonicalBytes(),
            repositoryToday: await repository.currentToday(),
            repositoryTodayToken: await repository.currentTodayToken(),
            repositoryTodayBytes: try await repository.currentTodayCanonicalBytes(),
            repositoryTodaySaveCount: await repository.todaySaveCount,
            repositoryTodayDeleteCount: await repository.resetTodayCount,
            repositorySettingsLoadCount: await repository.settingsLoadCount,
            repositoryTodayLoadCount: await repository.todayLoadCount,
            repositorySaveCount: await repository.settingsSaveCount,
            repositoryTemporaryWriteCount: await repository.settingsTemporaryWriteCount,
            storeSettingsRecord: store.settingsRecordForValidation,
            storeSettingsToken: store.settingsTokenForValidation,
            storeTodayRecord: store.todayRecordForValidation,
            storeTodayToken: store.todayTokenForValidation,
            workRules: store.currentWorkRules,
            hasDamagedSettings: store.hasDamagedSettings,
            viewState: store.viewState,
            settingsReadError: store.settingsReadErrorViewState,
            scheduleTimeError: store.scheduleTimeErrorViewState,
            confirmation: store.confirmation,
            saveReceipt: settingsSaveReceipt(from: store.feedback),
            stateGeneration: store.stateGeneration,
            savingPhaseCount: store.commandPhaseHistory.reduce(into: 0) { count, phase in
                if case .saving = phase { count += 1 }
            },
            commandPhase: store.commandPhase,
            isCommandInFlight: store.isCommandInFlight
        )
    }

    private func assertSaveSettingsPreflightPreserved(
        before: SaveSettingsPreflightObservation,
        after: SaveSettingsPreflightObservation,
        expectedScheduleTimeError: ScheduleTimeErrorViewState?,
        isDamaged: Bool,
        label: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(after.repositorySaveCount, before.repositorySaveCount, label, file: file, line: line)
        XCTAssertEqual(after.repositorySaveCount, 0, label, file: file, line: line)
        XCTAssertEqual(after.repositoryTemporaryWriteCount, before.repositoryTemporaryWriteCount,
                       label, file: file, line: line)
        XCTAssertEqual(after.repositoryTemporaryWriteCount, 0, label, file: file, line: line)
        XCTAssertEqual(after.repositorySettings, before.repositorySettings, label, file: file, line: line)
        XCTAssertEqual(after.repositorySettingsToken, before.repositorySettingsToken,
                       label, file: file, line: line)
        XCTAssertEqual(after.repositorySettingsBytes, before.repositorySettingsBytes,
                       label, file: file, line: line)
        XCTAssertEqual(after.repositoryToday, before.repositoryToday, label, file: file, line: line)
        XCTAssertEqual(after.repositoryTodayBytes, before.repositoryTodayBytes, label, file: file, line: line)
        XCTAssertEqual(after.repositoryTodaySaveCount, 0, label, file: file, line: line)
        XCTAssertEqual(after.repositoryTodayDeleteCount, 0, label, file: file, line: line)
        XCTAssertEqual(after.repositoryTodayToken, before.repositoryTodayToken,
                       label, file: file, line: line)
        XCTAssertEqual(after.storeSettingsRecord, before.storeSettingsRecord, label, file: file, line: line)
        XCTAssertEqual(after.storeSettingsToken, before.storeSettingsToken, label, file: file, line: line)
        XCTAssertEqual(after.storeTodayRecord, before.storeTodayRecord, label, file: file, line: line)
        XCTAssertEqual(after.storeTodayToken, before.storeTodayToken, label, file: file, line: line)
        XCTAssertEqual(after.workRules, before.workRules, label, file: file, line: line)
        XCTAssertEqual(after.hasDamagedSettings, before.hasDamagedSettings, label, file: file, line: line)
        XCTAssertEqual(after.viewState, before.viewState, label, file: file, line: line)
        XCTAssertEqual(after.settingsReadError, before.settingsReadError, label, file: file, line: line)
        XCTAssertEqual(after.scheduleTimeError, expectedScheduleTimeError, label, file: file, line: line)
        XCTAssertEqual(after.confirmation, before.confirmation, label, file: file, line: line)
        XCTAssertEqual(after.saveReceipt, before.saveReceipt, label, file: file, line: line)
        XCTAssertNil(after.saveReceipt, label, file: file, line: line)
        XCTAssertEqual(after.stateGeneration, before.stateGeneration, label, file: file, line: line)
        XCTAssertEqual(after.savingPhaseCount, before.savingPhaseCount, label, file: file, line: line)
        XCTAssertEqual(after.savingPhaseCount, 0, label, file: file, line: line)
        XCTAssertEqual(after.commandPhase, .idle, label, file: file, line: line)
        XCTAssertFalse(after.isCommandInFlight, label, file: file, line: line)
        XCTAssertFalse(isDamaged ? before.repositorySettings != nil : before.repositorySettings == nil,
                       label, file: file, line: line)
        if isDamaged {
            XCTAssertNil(before.repositorySettings?.revision, label, file: file, line: line)
            XCTAssertNil(after.repositorySettings?.revision, label, file: file, line: line)
        } else {
            XCTAssertEqual(after.repositorySettings?.revision, before.repositorySettings?.revision,
                           label, file: file, line: line)
        }
    }

    private func preflightTodayFixture(kind: String, settings: SettingsRecord,
                                       at time: TimestampMilliseconds,
                                       timeZoneIdentifier: String) throws -> RecordLoadResult<TodayRecord> {
        switch kind {
        case "missing": return .missing
        case "damaged": return .damaged(.init(kind: .today, issue: .decodingFailed,
                                               disposition: .requireTodayReset))
        case "valid":
            let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: timeZoneIdentifier)
            let today = try calendar.proposedToday(from: settings, at: time)
                .replacingRevision(.init(rawValue: 1))
            try today.validated()
            return .loaded(today, migration: .current)
        default: throw PersistenceError.invalidProposedRecord
        }
    }

    func testStartTodayEveryPreflightFailurePreservesRecordsAndSuccessOrdersBeforeDelete() async throws {
        let points: [StartTodayPreflightPoint] = [.commandContext, .typedLoads, .currentWorkday,
            .settingsClassification, .schedule, .targetViewState, .commitIntent]
        for failurePoint in points.map(Optional.some) + [nil] {
            let label = failurePoint?.rawValue ?? "success"
            let settings = ApplicationTestSupport.committedSettings()
            let today = try completedToday(settings: settings, day: 13)
            let oldBytes = try CanonicalRecordEncoder.encode(today)
            let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
                today: .loaded(today, migration: .current))
            let probe = StartTodayPreflightProbe(failure: failurePoint)
            await repository.observeStartTodayCommit { probe.recordDelete() }
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8)),
                timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(identifier: ApplicationTestSupport.timeZoneIdentifier),
                startTodayPreflightObserver: probe)
            await store.restore()
            let oldView = store.viewState
            let oldSettingsToken = store.settingsTokenForValidation
            let oldTodayToken = store.todayTokenForValidation
            let request = await store.send(.requestStartToday, source: .panel)
            XCTAssertEqual(request, .confirmationPresented, label)
            let outcome = await store.send(.confirmStartToday, source: .panel)
            let savedSettings = await repository.currentSettings()
            let retainedToday = await repository.currentToday()
            let settingsSaves = await repository.settingsSaveCount
            let todaySaves = await repository.todaySaveCount
            let temporaryWrites = await repository.settingsTemporaryWriteCount
            let deletes = await repository.resetTodayCount
            XCTAssertEqual(settingsSaves, 0, label)
            XCTAssertEqual(todaySaves, 0, label)
            XCTAssertEqual(temporaryWrites, 0, label)
            XCTAssertEqual(savedSettings, settings, label)
            XCTAssertEqual(store.settingsRecordForValidation, settings, label)
            XCTAssertEqual(store.settingsTokenForValidation, oldSettingsToken, label)
            XCTAssertFalse(store.isCommandInFlight, label)
            XCTAssertEqual(store.commandPhase, .idle, label)
            XCTAssertFalse(probe.contexts.isEmpty, label)
            XCTAssertTrue(probe.contexts.allSatisfy { $0 == probe.contexts.first }, label)
            if let failurePoint {
                XCTAssertEqual(outcome, .failed(.persistence(.invalidProposedRecord)), label)
                XCTAssertEqual(deletes, 0, label)
                XCTAssertEqual(retainedToday, today, label)
                XCTAssertEqual(try CanonicalRecordEncoder.encode(XCTUnwrap(retainedToday)), oldBytes, label)
                XCTAssertEqual(store.todayRecordForValidation, today, label)
                XCTAssertEqual(store.todayTokenForValidation, oldTodayToken, label)
                XCTAssertEqual(store.viewState, oldView, label)
                XCTAssertEqual(store.confirmation, .startToday, label)
                let end = try XCTUnwrap(points.firstIndex(of: failurePoint))
                XCTAssertEqual(probe.events, points[...end].map(\.rawValue), label)
            } else {
                XCTAssertEqual(outcome, .committed, label)
                XCTAssertEqual(deletes, 1, label)
                XCTAssertNil(retainedToday, label)
                XCTAssertEqual(store.viewState?.state, .ready, label)
                XCTAssertEqual(probe.events, points.map(\.rawValue) + ["repositoryDelete"], label)
            }
        }
    }

    private func makeStore(
        repository: any BusinessRecordRepository,
        clock: any NowProvider
    ) throws -> BusinessStore {
        try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
    }

    private func completedToday(settings: SettingsRecord, day: Int) throws -> TodayRecord {
        let calendar = try BusinessWorkdayCalendar(
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
        let proposed = try calendar.proposedToday(
            from: settings,
            at: ApplicationTestSupport.timestamp(day: day, hour: 10)
        )
        return TodayRecord(
            schemaVersion: proposed.schemaVersion,
            revision: .init(rawValue: 1),
            dateKey: proposed.dateKey,
            clockInAtMs: proposed.clockInAtMs,
            clockOutAtMs: ApplicationTestSupport.timestamp(day: day, hour: 11).rawValue,
            settingsSnapshot: proposed.settingsSnapshot,
            scheduledStartAtMs: proposed.scheduledStartAtMs,
            scheduledEndAtMs: proposed.scheduledEndAtMs,
            notificationScheduledDateKey: proposed.notificationScheduledDateKey,
            notificationRequestIdentifier: proposed.notificationRequestIdentifier,
            updatedAtMs: ApplicationTestSupport.timestamp(day: day, hour: 11).rawValue
        )
    }

    private func clockOutEstimate(
        from confirmation: BusinessConfirmation?
    ) -> ClockOutEstimate? {
        guard case let .clockOut(estimate) = confirmation else { return nil }
        return estimate
    }

    private func settingsSaveReceipt(
        from feedback: BusinessFeedback?
    ) -> SettingsSaveReceipt? {
        guard case let .settingsSaved(receipt) = feedback else { return nil }
        return receipt
    }

    private func assertScheduleError<T>(
        _ expected: ScheduleTimeError,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? ScheduleTimeError, expected)
        }
    }
}

private final class StartTodayPreflightProbe: StartTodayPreflightObserving, @unchecked Sendable {
    let failure: StartTodayPreflightPoint?
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    @MainActor private(set) var contexts: [BusinessCommandContext] = []
    init(failure: StartTodayPreflightPoint?) { self.failure = failure }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recordedEvents }
    @MainActor func check(_ point: StartTodayPreflightPoint, context: BusinessCommandContext) throws {
        lock.lock(); recordedEvents.append(point.rawValue); lock.unlock()
        contexts.append(context)
        if failure == point { throw PersistenceError.invalidProposedRecord }
    }
    func recordDelete() {
        lock.lock(); recordedEvents.append("repositoryDelete"); lock.unlock()
    }
}

private final class CommitAwareScheduleResolver: LocalScheduleResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var committed = false
    private var before = 0
    private var after = 0
    var preCommitCalls: Int { lock.lock(); defer { lock.unlock() }; return before }
    var postCommitCalls: Int { lock.lock(); defer { lock.unlock() }; return after }
    func markCommitted() { lock.lock(); committed = true; lock.unlock() }
    func resolve(dateKey: WorkdayKey, timeZoneIdentifier: String,
                 startMinuteOfDay: Int, endMinuteOfDay: Int) throws -> WorkdaySchedule {
        lock.lock()
        let forbidden = committed
        if forbidden { after += 1 } else { before += 1 }
        lock.unlock()
        if forbidden {
            XCTFail("Forbidden post-commit LocalScheduleResolver call")
            throw BusinessCalendarError.inconsistentSchedule
        }
        return try LocalScheduleResolver().resolve(dateKey: dateKey, timeZoneIdentifier: timeZoneIdentifier,
            startMinuteOfDay: startMinuteOfDay, endMinuteOfDay: endMinuteOfDay)
    }
}
