import Foundation
import XCTest
@testable import IncomeClock

@MainActor
final class Stage6NotificationTests: XCTestCase {
    func testOrdinaryRestoreAndClockInNeverRequestPermissionWhenDisabled() async throws {
        let notification = FakeNotificationService(authorization: .notDetermined)
        let repository = BusinessRecordRepositorySpy(settings: .loaded(
            ApplicationTestSupport.proposedSettings().replacingRevision(.init(rawValue: 1)),
            migration: .current
        ))
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()
        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)

        let operations = await notification.operationLog()
        XCTAssertFalse(operations.contains(.requestAuthorization))
        XCTAssertFalse(operations.contains { if case .add = $0 { true } else { false } })
    }

    func testExplicitEnableRequestsUndeterminedPermissionThenSchedulesActiveToday() async throws {
        let notification = FakeNotificationService(authorization: .notDetermined)
        await notification.setRequestAuthorizationResult(.authorized)
        let repository = try await clockedInRepository(notificationsEnabled: false)
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let enable = await store.setNotificationsEnabled(true)
        XCTAssertEqual(enable, .committed)
        XCTAssertTrue(store.notificationsEnabled)
        let operations = await notification.operationLog()
        XCTAssertTrue(operations.contains(.authorizationStatus))
        XCTAssertTrue(operations.contains(.requestAuthorization))
        XCTAssertTrue(operations.contains(.add("workday-end-2026-08-13")))
        XCTAssertGreaterThanOrEqual(operations.filter { $0 == .pending }.count, 2)
        let today = await repository.currentToday()
        XCTAssertEqual(today?.notificationRequestIdentifier, "workday-end-2026-08-13")
    }

    func testDeniedPermissionKeepsOriginalDisabledValue() async throws {
        let denied = FakeNotificationService(authorization: .denied)
        let deniedRepository = try await clockedInRepository(notificationsEnabled: false)
        let deniedStore = try makeStore(repository: deniedRepository, notification: denied)
        await deniedStore.restore()
        let deniedOutcome = await deniedStore.setNotificationsEnabled(true)
        XCTAssertEqual(deniedOutcome, .failed)
        XCTAssertFalse(deniedStore.notificationsEnabled)
        XCTAssertEqual(deniedStore.notificationPreferenceError, .permissionDenied)
        let deniedOperations = await denied.operationLog()
        XCTAssertFalse(deniedOperations.contains(.requestAuthorization))
    }

    func testPermissionQueryFailureKeepsOriginalValueAndMapsPrecisely() async throws {
        let notification = FakeNotificationService(authorization: .notDetermined)
        await notification.enqueueError(.permissionQueryFailed, for: .authorizationStatus)
        let repository = try await clockedInRepository(notificationsEnabled: false)
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let outcome = await store.setNotificationsEnabled(true)
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertEqual(store.notificationPreferenceError, .permissionQueryFailed)
        let operations = await notification.operationLog()
        XCTAssertFalse(operations.contains(.requestAuthorization))
    }

    func testPermissionRequestFailureKeepsOriginalValueAndMapsPrecisely() async throws {
        let notification = FakeNotificationService(authorization: .notDetermined)
        await notification.enqueueError(.permissionRequestFailed, for: .requestAuthorization)
        let repository = try await clockedInRepository(notificationsEnabled: false)
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let outcome = await store.setNotificationsEnabled(true)
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertEqual(store.notificationPreferenceError, .permissionRequestFailed)
        let operations = await notification.operationLog()
        XCTAssertTrue(operations.contains(.requestAuthorization))
    }

    func testAuthorizedPermissionEnablesWithoutRequestingPermissionAgain() async throws {
        let notification = FakeNotificationService(authorization: .authorized)
        let repository = try await clockedInRepository(notificationsEnabled: false)
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let outcome = await store.setNotificationsEnabled(true)
        XCTAssertEqual(outcome, .committed)
        XCTAssertTrue(store.notificationsEnabled)
        let operations = await notification.operationLog()
        XCTAssertFalse(operations.contains(.requestAuthorization))
    }

    func testClockInSchedulesWithStableIdentifierAndConfirmsBeforeMarker() async throws {
        let notification = FakeNotificationService(authorization: .authorized)
        let settings = ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
            .replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)

        let operations = await notification.operationLog()
        XCTAssertEqual(operations, [
            .pending,
            .add("workday-end-2026-08-13"),
            .pending
        ])
        let today = await repository.currentToday()
        XCTAssertEqual(today?.notificationScheduledDateKey, "2026-08-13")
        XCTAssertEqual(today?.notificationRequestIdentifier, "workday-end-2026-08-13")
    }

    func testExistingPendingRequestIsIdempotentAndBackfillsMarkerWithoutAdd() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        let notification = FakeNotificationService(
            authorization: .authorized,
            pendingIdentifiers: ["workday-end-2026-08-13"]
        )
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()

        let today = await repository.currentToday()
        let operations = await notification.operationLog()
        XCTAssertEqual(today?.notificationRequestIdentifier, "workday-end-2026-08-13")
        XCTAssertFalse(operations.contains {
            if case .add = $0 { true } else { false }
        })
    }

    func testExistingMarkerAndPendingRequestRemainIdempotentWithoutAdd() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        try await installNotificationMarker(in: repository)
        let notification = FakeNotificationService(
            authorization: .authorized,
            pendingIdentifiers: ["workday-end-2026-08-13"]
        )
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()

        let operations = await notification.operationLog()
        let today = await repository.currentToday()
        XCTAssertEqual(operations, [.pending])
        XCTAssertEqual(today?.notificationRequestIdentifier,
            "workday-end-2026-08-13")
    }

    func testExistingMarkerWithMissingPendingRequestReaddsAndConfirmsStableIdentifier() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        try await installNotificationMarker(in: repository)
        let notification = FakeNotificationService(authorization: .authorized)
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()

        let operations = await notification.operationLog()
        let today = await repository.currentToday()
        XCTAssertEqual(operations, [
            .pending,
            .add("workday-end-2026-08-13"),
            .pending
        ])
        XCTAssertEqual(today?.notificationRequestIdentifier,
            "workday-end-2026-08-13")
    }

    func testExistingMarkerWithMissingPendingDoesNotReaddWhenNotificationsDisabled() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: false)
        try await installNotificationMarker(in: repository)
        let notification = FakeNotificationService(authorization: .authorized)
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()

        let operations = await notification.operationLog()
        XCTAssertEqual(operations, [.pending])
    }

    func testExistingMarkerDoesNotReaddAfterScheduledEndOrCompletedToday() async throws {
        let endedRepository = try await clockedInRepository(notificationsEnabled: true)
        try await installNotificationMarker(in: endedRepository)
        let endedNotification = FakeNotificationService(authorization: .authorized)
        let endedStore = try makeStore(repository: endedRepository,
            notification: endedNotification,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 19)))
        await endedStore.restore()
        let endedOperations = await endedNotification.operationLog()
        XCTAssertFalse(endedOperations.contains {
            if case .add = $0 { true } else { false }
        })

        let completedRepository = try await completedRepositoryWithMarker()
        let completedNotification = FakeNotificationService(authorization: .authorized)
        let completedStore = try makeStore(repository: completedRepository,
            notification: completedNotification,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)))
        await completedStore.restore()
        XCTAssertEqual(completedStore.viewState?.state, .completed)
        let completedOperations = await completedNotification.operationLog()
        XCTAssertFalse(completedOperations.contains {
            if case .add = $0 { true } else { false }
        })
    }

    func testMarkerWriteFailureRecoversFromPendingWithoutCreatingDuplicate() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        await repository.failNextTodaySave(with: .atomicWriteFailed)
        let notification = FakeNotificationService(
            authorization: .authorized,
            pendingIdentifiers: ["workday-end-2026-08-13"]
        )
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()
        let firstToday = await repository.currentToday()
        XCTAssertNil(firstToday?.notificationRequestIdentifier)
        XCTAssertEqual(store.viewState?.state, .earning)
        await store.restore()

        let recoveredToday = await repository.currentToday()
        let operations = await notification.operationLog()
        XCTAssertEqual(recoveredToday?.notificationRequestIdentifier, "workday-end-2026-08-13")
        XCTAssertFalse(operations.contains {
            if case .add = $0 { true } else { false }
        })
    }

    func testAddSuccessWithMarkerWriteFailureRecoversWithoutSecondAdd() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        await repository.failNextTodaySave(with: .atomicWriteFailed)
        let notification = FakeNotificationService(authorization: .authorized)
        let store = try makeStore(repository: repository, notification: notification)

        await store.restore()
        let firstToday = await repository.currentToday()
        XCTAssertNil(firstToday?.notificationRequestIdentifier)
        await store.restore()

        let recovered = await repository.currentToday()
        let operations = await notification.operationLog()
        XCTAssertEqual(recovered?.notificationRequestIdentifier, "workday-end-2026-08-13")
        XCTAssertEqual(operations.filter {
            if case .add("workday-end-2026-08-13") = $0 { true } else { false }
        }.count, 1)
    }

    func testScheduledEndAlreadyPassedDoesNotScheduleWhenEnabled() async throws {
        let repository = try await clockedInRepository(notificationsEnabled: false)
        let notification = FakeNotificationService(authorization: .authorized)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 19))
        let store = try makeStore(repository: repository, notification: notification, clock: clock)
        await store.restore()

        let enable = await store.setNotificationsEnabled(true)
        let operations = await notification.operationLog()
        XCTAssertEqual(enable, .committed)
        XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
        XCTAssertFalse(operations.contains {
            if case .add = $0 { true } else { false }
        })
    }

    func testEarlyClockOutCancelsAndFailureNeverChangesCompletedBusinessState() async throws {
        let successNotification = FakeNotificationService(authorization: .authorized)
        let successRepository = BusinessRecordRepositorySpy(settings: .loaded(
            ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
                .replacingRevision(.init(rawValue: 1)), migration: .current
        ))
        let successClock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let successStore = try makeStore(repository: successRepository,
            notification: successNotification, clock: successClock)
        await successStore.restore()
        _ = await successStore.send(.clockIn, source: .panel)
        successClock.set(ApplicationTestSupport.timestamp(hour: 11))
        _ = await successStore.send(.requestClockOut, source: .panel)
        let successClockOut = await successStore.send(.confirmClockOut, source: .panel)
        let successOperations = await successNotification.operationLog()
        XCTAssertEqual(successClockOut, .committed)
        XCTAssertEqual(successStore.viewState?.state, .completed)
        XCTAssertTrue(successOperations.contains(.remove("workday-end-2026-08-13")))

        let failingNotification = FakeNotificationService(authorization: .authorized)
        await failingNotification.enqueueError(.cancellationFailed,
            for: .remove("workday-end-2026-08-13"))
        let failingRepository = BusinessRecordRepositorySpy(settings: .loaded(
            ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
                .replacingRevision(.init(rawValue: 1)), migration: .current
        ))
        let failingClock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let failingStore = try makeStore(repository: failingRepository,
            notification: failingNotification, clock: failingClock)
        await failingStore.restore()
        _ = await failingStore.send(.clockIn, source: .panel)
        failingClock.set(ApplicationTestSupport.timestamp(hour: 11))
        _ = await failingStore.send(.requestClockOut, source: .panel)
        let expectedAmount = failingStore.confirmation.flatMap {
            confirmation -> BusinessEarnedAmount? in
            guard case let .clockOut(estimate) = confirmation else { return nil }
            return .rounded(estimate.roundedEarnedCents)
        }
        let failingClockOut = await failingStore.send(.confirmClockOut, source: .panel)
        XCTAssertEqual(failingClockOut, .committed)
        XCTAssertEqual(failingStore.viewState?.state, .completed)
        XCTAssertEqual(failingStore.viewState?.amount, expectedAmount)
        XCTAssertEqual(failingStore.notificationDiagnostics.last,
            .cancellation(.cancellationFailed, identifier: "workday-end-2026-08-13"))
        XCTAssertEqual(failingStore.notificationPreferenceError, .cancellationFailed)
        let failedToday = await failingRepository.currentToday()
        XCTAssertNotNil(failedToday?.clockOutAtMs)
        XCTAssertEqual(notificationInlineErrorText(.cancellationFailed),
            "下班已完成，但系统通知取消失败；不影响最终金额。")
    }

    func testCancellationPendingQueryFailureIsTypedVisibleAndPreservesCompletion() async throws {
        let notification = FakeNotificationService(authorization: .authorized)
        let repository = notificationEnabledRepository()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, notification: notification, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)
        clock.set(ApplicationTestSupport.timestamp(hour: 11))
        _ = await store.send(.requestClockOut, source: .panel)
        let expectedAmount = store.confirmation.flatMap { confirmation -> BusinessEarnedAmount? in
            guard case let .clockOut(estimate) = confirmation else { return nil }
            return .rounded(estimate.roundedEarnedCents)
        }
        await notification.enqueueError(.pendingQueryFailed, for: .pending)

        let clockOut = await store.send(.confirmClockOut, source: .panel)
        XCTAssertEqual(clockOut, .committed)
        XCTAssertEqual(store.viewState?.state, .completed)
        XCTAssertEqual(store.viewState?.amount, expectedAmount)
        let today = await repository.currentToday()
        XCTAssertNotNil(today?.clockOutAtMs)
        XCTAssertEqual(store.notificationDiagnostics.last,
            .cancellation(.cancellationPendingQueryFailed,
                identifier: "workday-end-2026-08-13"))
        XCTAssertEqual(store.notificationPreferenceError, .cancellationPendingQueryFailed)
        XCTAssertEqual(notificationInlineErrorText(.cancellationPendingQueryFailed),
            "下班已完成，但无法确认系统通知已取消；不影响最终金额。")
    }

    func testCancellationStillPendingIsTypedVisibleAndPreservesCompletion() async throws {
        let notification = FakeNotificationService(authorization: .authorized)
        let repository = notificationEnabledRepository()
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, notification: notification, clock: clock)
        await store.restore()
        _ = await store.send(.clockIn, source: .panel)
        clock.set(ApplicationTestSupport.timestamp(hour: 11))
        _ = await store.send(.requestClockOut, source: .panel)
        let expectedAmount = store.confirmation.flatMap { confirmation -> BusinessEarnedAmount? in
            guard case let .clockOut(estimate) = confirmation else { return nil }
            return .rounded(estimate.roundedEarnedCents)
        }
        await notification.retainNextRemovedIdentifier()

        let clockOut = await store.send(.confirmClockOut, source: .panel)
        XCTAssertEqual(clockOut, .committed)
        XCTAssertEqual(store.viewState?.state, .completed)
        XCTAssertEqual(store.viewState?.amount, expectedAmount)
        let today = await repository.currentToday()
        XCTAssertNotNil(today?.clockOutAtMs)
        XCTAssertEqual(store.notificationDiagnostics.last,
            .cancellation(.cancellationNotConfirmed,
                identifier: "workday-end-2026-08-13"))
        XCTAssertEqual(store.notificationPreferenceError, .cancellationNotConfirmed)
        XCTAssertEqual(notificationInlineErrorText(.cancellationNotConfirmed),
            "下班已完成，但系统通知仍在等待列表；不影响最终金额。")
    }

    func testSchedulingFailureAndNextDaySettingsChangeDoNotAlterTodayBusinessState() async throws {
        let notification = FakeNotificationService(authorization: .authorized)
        await notification.enqueueError(.addFailed, for: .add("workday-end-2026-08-13"))
        let settings = ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
            .replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current))
        let store = try makeStore(repository: repository, notification: notification)
        await store.restore()

        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)
        XCTAssertEqual(store.viewState?.state, .earning)
        let loadedTodayBefore = await repository.currentToday()
        let todayBefore = try XCTUnwrap(loadedTodayBefore)
        let save = await store.send(.saveWorkRules(.init(
            dailyWageCents: 50_000,
            workStartMinuteOfDay: 8 * 60,
            workEndMinuteOfDay: 17 * 60
        )), source: .settings)
        XCTAssertEqual(save, .committed)
        let loadedTodayAfter = await repository.currentToday()
        let todayAfter = try XCTUnwrap(loadedTodayAfter)
        XCTAssertEqual(todayAfter.settingsSnapshot, todayBefore.settingsSnapshot)
        XCTAssertEqual(todayAfter.scheduledEndAtMs, todayBefore.scheduledEndAtMs)
        XCTAssertEqual(store.viewState?.state, .earning)
    }

    private func makeStore(
        repository: any BusinessRecordRepository,
        notification: any NotificationServicing,
        clock: MutableTestClock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
    ) throws -> BusinessStore {
        try BusinessStore(
            repository: repository,
            nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
            notificationService: notification
        )
    }

    private func clockedInRepository(notificationsEnabled: Bool) async throws
        -> BusinessRecordRepositorySpy {
        let baseSettings = ApplicationTestSupport.proposedSettings(notificationsEnabled: false)
            .replacingRevision(.init(rawValue: 1))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(baseSettings, migration: .current))
        let store = try makeStore(
            repository: repository,
            notification: FakeNotificationService(authorization: .authorized)
        )
        await store.restore()
        let clockIn = await store.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)
        if notificationsEnabled {
            let changed = ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
                .replacingRevision(baseSettings.revision)
            await repository.replaceSettingsExternally(changed)
        }
        return repository
    }

    private func notificationEnabledRepository() -> BusinessRecordRepositorySpy {
        BusinessRecordRepositorySpy(settings: .loaded(
            ApplicationTestSupport.proposedSettings(notificationsEnabled: true)
                .replacingRevision(.init(rawValue: 1)),
            migration: .current
        ))
    }

    private func installNotificationMarker(
        in repository: BusinessRecordRepositorySpy
    ) async throws {
        let loaded = await repository.currentToday()
        let current = try XCTUnwrap(loaded)
        await repository.replaceTodayExternally(TodayRecord(
            schemaVersion: TodayRecord.currentSchemaVersion,
            revision: current.revision,
            dateKey: current.dateKey,
            clockInAtMs: current.clockInAtMs,
            clockOutAtMs: current.clockOutAtMs,
            settingsSnapshot: current.settingsSnapshot,
            scheduledStartAtMs: current.scheduledStartAtMs,
            scheduledEndAtMs: current.scheduledEndAtMs,
            notificationScheduledDateKey: current.dateKey,
            notificationRequestIdentifier: "workday-end-\(current.dateKey)",
            updatedAtMs: current.updatedAtMs
        ))
    }

    private func completedRepositoryWithMarker() async throws -> BusinessRecordRepositorySpy {
        let repository = try await clockedInRepository(notificationsEnabled: true)
        try await installNotificationMarker(in: repository)
        let loaded = await repository.currentToday()
        let current = try XCTUnwrap(loaded)
        await repository.replaceTodayExternally(TodayRecord(
            schemaVersion: TodayRecord.currentSchemaVersion,
            revision: current.revision,
            dateKey: current.dateKey,
            clockInAtMs: current.clockInAtMs,
            clockOutAtMs: ApplicationTestSupport.timestamp(hour: 11).rawValue,
            settingsSnapshot: current.settingsSnapshot,
            scheduledStartAtMs: current.scheduledStartAtMs,
            scheduledEndAtMs: current.scheduledEndAtMs,
            notificationScheduledDateKey: current.notificationScheduledDateKey,
            notificationRequestIdentifier: current.notificationRequestIdentifier,
            updatedAtMs: ApplicationTestSupport.timestamp(hour: 11).rawValue
        ))
        return repository
    }
}

@MainActor
final class Stage6LoginItemTests: XCTestCase {
    func testEnabledDisabledAndRequiresApprovalUseSystemReadback() async throws {
        let repository = configuredRepository()
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .disabled)
        let controller = LoginItemController(service: service, businessStore: store)

        await controller.setEnabled(true)
        let enabledSettings = await repository.currentSettings()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(enabledSettings?.launchAtLogin == true)
        await controller.setEnabled(false)
        let disabledSettings = await repository.currentSettings()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(disabledSettings?.launchAtLogin == false)

        let approvalService = FakeLoginItemService(status: .disabled)
        await approvalService.enqueueStatus(.disabled)
        await approvalService.enqueueStatus(.requiresApproval)
        let approvalController = LoginItemController(service: approvalService, businessStore: store)
        await approvalController.setEnabled(true)
        XCTAssertEqual(approvalController.status, .requiresApproval)
        XCTAssertEqual(approvalController.error, .denied)
    }

    func testSystemFailureAndSettingsWriteFailurePreserveOldFinalState() async throws {
        let repository = configuredRepository()
        let store = try makeStore(repository)
        await store.restore()
        let deniedService = FakeLoginItemService(status: .disabled)
        await deniedService.enqueueError(.denied, for: .register)
        let deniedController = LoginItemController(service: deniedService, businessStore: store)
        await deniedController.setEnabled(true)
        XCTAssertFalse(deniedController.isEnabled)
        XCTAssertEqual(deniedController.error, .denied)

        let rollbackService = FakeLoginItemService(status: .disabled)
        let rollbackController = LoginItemController(service: rollbackService, businessStore: store)
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        await rollbackController.setEnabled(true)
        let rolledBackSettings = await repository.currentSettings()
        XCTAssertFalse(rollbackController.isEnabled)
        XCTAssertEqual(rollbackController.error, .settingsPersistenceFailed)
        XCTAssertFalse(rolledBackSettings?.launchAtLogin ?? true)
        let operations = await rollbackService.operationLog()
        XCTAssertTrue(operations.contains(.register))
        XCTAssertTrue(operations.contains(.unregister))
    }

    func testRapidCommandsSerializeAndStaleEnableCannotOverrideLatestDisable() async throws {
        let repository = configuredRepository()
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .disabled)
        await service.holdNextRegister()
        let controller = LoginItemController(service: service, businessStore: store)

        let old = Task { await controller.setEnabled(true) }
        await service.waitUntilRegisterIsHeld()
        let latest = Task { await controller.setEnabled(false) }
        await service.releaseHeldRegister()
        await old.value
        await latest.value

        let finalSettings = await repository.currentSettings()
        let finalSystemStatus = try await service.status()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(finalSettings?.launchAtLogin ?? true)
        XCTAssertEqual(finalSystemStatus, .disabled)
    }

    func testHeldRegisterTransactionCannotBeInterruptedByConcurrentRefresh() async throws {
        let repository = configuredRepository()
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .disabled)
        await service.holdNextRegister()
        let controller = LoginItemController(service: service, businessStore: store)

        let mutation = Task { await controller.setEnabled(true) }
        await service.waitUntilRegisterIsHeld()
        let refresh = Task { await controller.refresh() }
        await yieldSeveralTimes()
        let heldOperations = await service.operationLog()
        XCTAssertEqual(heldOperations, [.status, .register])

        await service.releaseHeldRegister()
        await mutation.value
        await refresh.value

        let finalSettings = await repository.currentSettings()
        let finalSystem = try await service.status()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(finalSettings?.launchAtLogin == true)
        XCTAssertEqual(finalSystem, .enabled)
    }

    func testHeldUnregisterTransactionCannotBeInterruptedByConcurrentRefresh() async throws {
        let repository = configuredRepository(launchAtLogin: true)
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .enabled)
        await service.holdNextUnregister()
        let controller = LoginItemController(service: service, businessStore: store)

        let mutation = Task { await controller.setEnabled(false) }
        await service.waitUntilUnregisterIsHeld()
        let refresh = Task { await controller.refresh() }
        await yieldSeveralTimes()
        let heldOperations = await service.operationLog()
        XCTAssertEqual(heldOperations, [.status, .unregister])

        await service.releaseHeldUnregister()
        await mutation.value
        await refresh.value

        let finalSettings = await repository.currentSettings()
        let finalSystem = try await service.status()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(finalSettings?.launchAtLogin ?? true)
        XCTAssertEqual(finalSystem, .disabled)
    }

    func testSettingsWriteFailureTransactionCannotBeInterruptedByConcurrentRefresh() async throws {
        let repository = configuredRepository()
        await repository.holdNextSettingsSave()
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .disabled)
        let controller = LoginItemController(service: service, businessStore: store)

        let mutation = Task { await controller.setEnabled(true) }
        await repository.waitUntilSettingsSaveIsHeld()
        let refresh = Task { await controller.refresh() }
        await yieldSeveralTimes()
        let heldOperations = await service.operationLog()
        XCTAssertEqual(heldOperations, [.status, .register, .status])

        await repository.resumeHeldSettingsSave()
        await mutation.value
        await refresh.value

        let finalSettings = await repository.currentSettings()
        let finalSystem = try await service.status()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(finalSettings?.launchAtLogin ?? true)
        XCTAssertEqual(controller.error, .settingsPersistenceFailed)
        XCTAssertEqual(finalSystem, .disabled)
    }

    func testRollbackCannotRaceWithConcurrentRefresh() async throws {
        let repository = configuredRepository()
        await repository.failNextSettingsSave(with: .atomicWriteFailed)
        let store = try makeStore(repository)
        await store.restore()
        let service = FakeLoginItemService(status: .disabled)
        await service.holdNextUnregister()
        let controller = LoginItemController(service: service, businessStore: store)

        let mutation = Task { await controller.setEnabled(true) }
        await service.waitUntilUnregisterIsHeld()
        let refresh = Task { await controller.refresh() }
        await yieldSeveralTimes()
        let heldOperations = await service.operationLog()
        XCTAssertEqual(heldOperations, [.status, .register, .status, .unregister])

        await service.releaseHeldUnregister()
        await mutation.value
        await refresh.value

        let finalSettings = await repository.currentSettings()
        let finalSystem = try await service.status()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(finalSettings?.launchAtLogin ?? true)
        XCTAssertEqual(controller.error, .settingsPersistenceFailed)
        XCTAssertEqual(finalSystem, .disabled)
    }

    func testEnvironmentExposesOneSharedLoginController() async throws {
        let repository = configuredRepository()
        let store = try makeStore(repository)
        let service = FakeLoginItemService(status: .enabled)
        let environment = AppEnvironment(
            businessStore: store,
            panelController: PanelControllerSpy(),
            loginItemService: service
        )
        await environment.loginItemController.refresh()
        XCTAssertTrue(environment.loginItemController.isEnabled)
        XCTAssertTrue(environment.businessStore === store)
    }

    private func configuredRepository(
        launchAtLogin: Bool = false
    ) -> BusinessRecordRepositorySpy {
        BusinessRecordRepositorySpy(settings: .loaded(
            ApplicationTestSupport.proposedSettings(launchAtLogin: launchAtLogin)
                .replacingRevision(.init(rawValue: 1)),
            migration: .current
        ))
    }

    private func makeStore(_ repository: any BusinessRecordRepository) throws -> BusinessStore {
        try BusinessStore(
            repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier
        )
    }

    private func yieldSeveralTimes() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
