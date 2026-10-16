import Foundation
import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import IncomeClock

@MainActor
final class BusinessStoreIntegrationTests: XCTestCase {
    private struct SettingsCommitRestartEvidence {
        let record: SettingsRecord
        let bytes: Data
        let receipt: SettingsSaveReceipt
    }

    func testChangedWorkRulesEnterOnlyNextDayClockInSnapshot() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        let paths = RecordRepositoryPaths(root: root)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: RecordRepositoryActor(paths: paths), clock: clock)
        await store.restore()
        _ = await store.send(.saveWorkRules(ApplicationTestSupport.workRules()), source: .settings)
        _ = await store.send(.clockIn, source: .panel)
        let original = try Data(contentsOf: paths.today)
        let saved = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(
            wageCents: 60_000, startMinuteOfDay: 10 * 60, endMinuteOfDay: 17 * 60)), source: .settings)
        XCTAssertEqual(saved, .committed)
        XCTAssertEqual(try Data(contentsOf: paths.today), original)
        _ = await store.send(.requestClockOut, source: .panel)
        _ = await store.send(.confirmClockOut, source: .panel)
        let next = try makeStore(repository: RecordRepositoryActor(paths: paths),
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 10)))
        await next.restore()
        _ = await next.send(.requestStartToday, source: .panel)
        let started = await next.send(.confirmStartToday, source: .panel)
        XCTAssertEqual(started, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
        let clockedIn = await next.send(.clockIn, source: .panel)
        XCTAssertEqual(clockedIn, .committed)
        let today = try JSONDecoder().decode(TodayRecord.self, from: Data(contentsOf: paths.today))
        XCTAssertEqual(today.settingsSnapshot.dailyWageCents, 60_000)
        XCTAssertEqual(today.settingsSnapshot.workStartMinuteOfDay, 10 * 60)
        XCTAssertEqual(today.settingsSnapshot.workEndMinuteOfDay, 17 * 60)
        XCTAssertEqual(today.scheduledStartAtMs, ApplicationTestSupport.timestamp(day: 14, hour: 10).rawValue)
        XCTAssertEqual(today.scheduledEndAtMs, ApplicationTestSupport.timestamp(day: 14, hour: 17).rawValue)
        XCTAssertEqual(today.clockInAtMs, ApplicationTestSupport.timestamp(day: 14, hour: 10).rawValue)
        XCTAssertNil(today.clockOutAtMs)
    }

    func testMissingOrDamagedSettingsRestoreWithTodayAndExplicitResetPreservesSnapshot() async throws {
        for damagedSettings in [false, true] {
            for damagedToday in [false, true] {
                let root = try ApplicationTestSupport.makeTemporaryRoot()
                let paths = RecordRepositoryPaths(root: root)
                let repo = RecordRepositoryActor(paths: paths)
                let fixture = try makeStore(repository: repo,
                    clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)))
                await fixture.restore()
                _ = await fixture.send(.saveWorkRules(ApplicationTestSupport.workRules()), source: .settings)
                _ = await fixture.send(.clockIn, source: .panel)
                let snapshot = try Data(contentsOf: paths.today)
                // Only isolated fixture files are changed before a fresh restore.
                try FileManager.default.removeItem(at: paths.settings)
                if damagedSettings { try Data("{broken-settings".utf8).write(to: paths.settings) }
                if damagedToday { try Data("{broken-today".utf8).write(to: paths.today) }
                let beforeSettings = try? Data(contentsOf: paths.settings)
                let beforeToday = try Data(contentsOf: paths.today)
                let restored = try makeStore(repository: RecordRepositoryActor(paths: paths),
                    clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)))
                await restored.restore()
                XCTAssertEqual(restored.viewState?.state, damagedToday ? .recoveryRequired : .earning)
                XCTAssertEqual(restored.settingsReadErrorViewState?.isBlocking, damagedSettings ? false : nil)
                if damagedToday { XCTAssertEqual(restored.viewState?.amount, .hidden) }
                else {
                    XCTAssertEqual(restored.todayRecordForValidation?.settingsSnapshot.dailyWageCents, 30_000)
                    XCTAssertEqual(beforeToday, snapshot)
                }
                XCTAssertEqual(try? Data(contentsOf: paths.settings), beforeSettings)
                XCTAssertEqual(try Data(contentsOf: paths.today), beforeToday)
                if damagedSettings && !damagedToday {
                    let oldView = restored.viewState
                    let oldToday = restored.todayRecordForValidation
                    _ = await restored.send(.requestSettingsReset, source: .settings)
                    _ = await restored.send(.cancelConfirmation, source: .settings)
                    XCTAssertEqual(try? Data(contentsOf: paths.settings), beforeSettings)
                    XCTAssertEqual(try Data(contentsOf: paths.today), beforeToday)
                    _ = await restored.send(.requestSettingsReset, source: .settings)
                    let reset = await restored.send(.confirmSettingsReset, source: .settings)
                    XCTAssertEqual(reset, .committed)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path))
                    XCTAssertEqual(try Data(contentsOf: paths.today), beforeToday)
                    XCTAssertEqual(restored.viewState?.state, oldView?.state)
                    XCTAssertEqual(restored.viewState?.amount, oldView?.amount)
                    XCTAssertEqual(restored.viewState?.earnedDuration, oldView?.earnedDuration)
                    XCTAssertEqual(restored.todayRecordForValidation, oldToday)
                    XCTAssertNil(restored.settingsReadErrorViewState)
                    XCTAssertEqual(restored.todayRecordForValidation?.settingsSnapshot.dailyWageCents, 30_000)
                }
            }
        }
    }

    func testSettingsCommitSurvivesFileBackedProcessRestartWithoutTodayOrStaleSuccess() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RecordRepositoryPaths(root: root)

        // Returning from this helper drops every reference to the first repository and Store.
        let committed = try await commitSettingsForRestartEvidence(paths: paths)

        let bytesBeforeRestart = try Data(contentsOf: paths.settings)
        XCTAssertEqual(bytesBeforeRestart, committed.bytes)

        let restartedRepository = RecordRepositoryActor(paths: paths)
        let restartedLoad = await restartedRepository.loadSettingsForBusiness()
        guard case let .loaded(restartedRecord, token) = restartedLoad else {
            return XCTFail("Expected the second file-backed repository to load committed Settings")
        }
        XCTAssertEqual(restartedRecord, committed.record)
        XCTAssertEqual(restartedRecord.revision, committed.receipt.committedRevision)
        XCTAssertEqual(token, .loaded(committed.receipt.committedRevision))
        XCTAssertEqual(try CanonicalRecordEncoder.encode(restartedRecord), committed.bytes)

        let todayBeforeRestore = await restartedRepository.loadToday()
        XCTAssertEqual(todayBeforeRestore, .missing)

        let restartedStore = try makeStore(
            repository: restartedRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 9))
        )
        await restartedStore.restore()

        XCTAssertEqual(restartedStore.viewState?.state, .ready)
        XCTAssertEqual(restartedStore.viewState?.amount, .rounded(try .init(validating: 0)))
        XCTAssertNil(restartedStore.viewState?.recoveryReason)
        XCTAssertNil(restartedStore.settingsReadErrorViewState)
        XCTAssertNil(restartedStore.scheduleTimeErrorViewState)
        XCTAssertNil(restartedStore.feedback)
        XCTAssertEqual(restartedStore.commandPhaseHistory, [.idle])

        let todayAfterRestore = await restartedRepository.loadToday()
        XCTAssertEqual(todayAfterRestore, .missing)
        XCTAssertEqual(try Data(contentsOf: paths.settings), committed.bytes)
    }

    func testRestartRestoresEarningFromTemporaryApplicationSupport() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepository = RecordRepositoryActor(paths: .init(root: root))
        let firstClock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let firstStore = try makeStore(repository: firstRepository, clock: firstClock)
        await firstStore.restore()
        let saveOutcome = await firstStore.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )
        XCTAssertEqual(saveOutcome, .committed)
        let clockInOutcome = await firstStore.send(.clockIn, source: .panel)
        XCTAssertEqual(clockInOutcome, .committed)

        let restartedRepository = RecordRepositoryActor(paths: .init(root: root))
        let restartedStore = try makeStore(
            repository: restartedRepository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12))
        )
        await restartedStore.restore()

        XCTAssertEqual(restartedStore.viewState?.state, .earning)
        guard case let .live(amount) = restartedStore.viewState?.amount else {
            return XCTFail("Expected live restored amount")
        }
        XCTAssertGreaterThan(amount.rawValue, 0)
        XCTAssertEqual(restartedStore.viewState?.clockInAt, ApplicationTestSupport.timestamp(hour: 10))
    }

    func testCompletedPreviousDayIsRetainedThenAtomicallyClearedByStartToday() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = RecordRepositoryActor(paths: .init(root: root))
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try makeStore(repository: repository, clock: clock)
        await store.restore()
        _ = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules()),
            source: .settings
        )
        _ = await store.send(.clockIn, source: .panel)
        clock.set(ApplicationTestSupport.timestamp(hour: 11))
        _ = await store.send(.requestClockOut, source: .panel)
        _ = await store.send(.confirmClockOut, source: .panel)
        XCTAssertEqual(store.viewState?.state, .completed)

        let nextDayRepository = RecordRepositoryActor(paths: .init(root: root))
        let nextDayStore = try makeStore(
            repository: nextDayRepository,
            clock: MutableTestClock(
                ApplicationTestSupport.timestamp(day: 14, hour: 8)
            )
        )
        await nextDayStore.restore()

        XCTAssertEqual(nextDayStore.viewState?.state, .completed)
        XCTAssertTrue(nextDayStore.viewState?.canRequestStartToday ?? false)
        let loadedToday = await nextDayRepository.loadToday()
        guard case .loaded = loadedToday else {
            return XCTFail("Expected completed prior-day Today to remain")
        }

        let request = await nextDayStore.send(.requestStartToday, source: .panel)
        XCTAssertEqual(request, .confirmationPresented)
        let commit = await nextDayStore.send(.confirmStartToday, source: .panel)
        XCTAssertEqual(commit, .committed)
        XCTAssertEqual(nextDayStore.viewState?.state, .ready)
        let todayAfterStart = await nextDayRepository.loadToday()
        XCTAssertEqual(todayAfterStart, .missing)
        let loadedSettings = await nextDayRepository.loadSettings()
        guard case let .loaded(settings, _) = loadedSettings else {
            return XCTFail("Expected settings to remain after cross-day cleanup")
        }
        XCTAssertEqual(settings.revision, .init(rawValue: 1))
    }

    func testDamagedTodayIsNeverAutomaticallyDeletedDuringRestore() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let corrupted = Data("untrusted-today".utf8)
        try corrupted.write(to: paths.today)
        let repository = RecordRepositoryActor(paths: paths)
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 8))
        )

        await store.restore()

        XCTAssertEqual(store.viewState?.state, .recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: paths.today), corrupted)
    }

    func testRecoveryBootstrapRejectsMissingMalformedExpiredAndEscapingRequestsBeforeEnvironmentCreation() throws {
        let original = ["UNCHANGED_NORMAL_PROCESS": "preserved"]
        XCTAssertEqual(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(original, requireIsolation: false), original)
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(original, requireIsolation: true))
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(
            ["INCOMECLOCK_TEST_ROOT": ""], requireIsolation: true))
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(
            ["INCOMECLOCK_TEST_ROOT": "/Users/ffq/Library/Application Support/com.ffq.incomeclock"], requireIsolation: true))
        let xctest = ["XCTestConfigurationFilePath": "/isolated-test-session.xctestconfiguration"]
        XCTAssertEqual(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(xctest, requireIsolation: true), xctest)
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("IncomeClockRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let now = Date().timeIntervalSince1970
        // LaunchServices may give the XCTest host PPID 1. This pure structural
        // validator needs an eligible non-self PID, not the host's real parent;
        // resolveEnvironment separately verifies the live same-bundle parent.
        let fixtureParentPID = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 1 && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }).processIdentifier
        let valid = Stage9RecoveryBootstrap.Request(schema: 1, root: root.path,
            output: root.appendingPathComponent("result.json").path, bundle: bundle.path,
            parentPID: fixtureParentPID, nonce: UUID().uuidString, mode: "theme-restore", time: 123,
            createdAt: now - 1, expiresAt: now + 30)
        XCTAssertNoThrow(try Stage9RecoveryBootstrap.validate(valid, now: now, temporary: temporary, bundle: bundle))
        let explicit = ["INCOMECLOCK_TEST_ROOT": root.path]
        XCTAssertEqual(try Stage9RecoveryBootstrap.environmentWhenMarkerMissing(explicit, requireIsolation: true), explicit)
        let malformed = root.appendingPathComponent("malformed-bootstrap.json")
        try Data("{".utf8).write(to: malformed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformed.path)
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.readRequest(at: malformed))
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.readRequest(at: root.appendingPathComponent("missing.json")))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let variants: [(String, Any)] = [
            ("schema", 99), ("nonce", "not-a-UUID"), ("parentPID", ProcessInfo.processInfo.processIdentifier),
            ("expiresAt", now - 0.5), ("expiresAt", now + 120), ("createdAt", now + 10),
            ("root", temporary.path), ("output", temporary.appendingPathComponent("escape.json").path),
            ("bundle", "/Applications/Unrelated.app"), ("mode", "production")
        ]
        for (field, value) in variants {
            var object = encoded
            object[field] = value
            let invalid = try JSONDecoder().decode(Stage9RecoveryBootstrap.Request.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try Stage9RecoveryBootstrap.validate(invalid, now: now,
                temporary: temporary, bundle: bundle), "Reject \(field)=\(value)")
        }
        let link = root.appendingPathComponent("bootstrap-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: malformed)
        XCTAssertThrowsError(try Stage9RecoveryBootstrap.readRequest(at: link), "No-follow must reject even same-root symlinks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Themes").path))
        // No production environment or fixed launch marker is touched by this validation test.
    }

    func testSettingsCommitSurvivesSIGKILLBeforePublicationAndRecoveryMakesZeroWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockRecovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = RecordRepositoryPaths(root: root)
        let committedOutput = root.appendingPathComponent("commit.json")
        let restoredOutput = root.appendingPathComponent("restore.json")
        let writer = try await Stage9IsolatedApplicationProcess.launch(root: root, mode: "commit",
            output: committedOutput, time: ApplicationTestSupport.timestamp(hour: 8))
        defer { writer.terminateIfRunning() }
        let committed = try await writer.readResult()
        XCTAssertEqual(committed["heldCommittedPublication"] as? Bool, true)
        XCTAssertEqual(committed["feedbackNil"] as? Bool, true)
        XCTAssertEqual(committed["writes"] as? Int, 1)
        XCTAssertEqual(committed["saveCommandEntries"] as? Int, 1)
        XCTAssertEqual(committed["repositoryWriteAttempts"] as? Int, 1)
        XCTAssertEqual(committed["revision"] as? Int, 1)
        let bytes = try Data(contentsOf: paths.settings)
        XCTAssertTrue(writer.isRunning, "Committed result remains held in a live independent process")
        let signalReceipt = try await writer.requestSelfSIGKILLAndWait()
        XCTAssertFalse(writer.isRunning)
        // The isolated writer emits a pre-syscall receipt and sends SIGKILL to
        // itself. Parent-to-LaunchServices signals are denied by App Sandbox.
        let reader = try await Stage9IsolatedApplicationProcess.launch(root: root, mode: "restore",
            output: restoredOutput, time: ApplicationTestSupport.timestamp(hour: 8))
        defer { reader.terminateIfRunning() }
        let restored = try await reader.readResult()
        try await reader.waitForTermination()
        XCTAssertNotEqual(committed["pid"] as? Int, restored["pid"] as? Int)
        XCTAssertEqual(restored["revision"] as? Int, committed["revision"] as? Int)
        XCTAssertEqual(restored["wage"] as? Int, 88_000)
        XCTAssertEqual(restored["writes"] as? Int, 0, "All file mutation entrypoints counted, including equal-byte rewrites")
        XCTAssertEqual(restored["saveCommandEntries"] as? Int, 0, "No automatic Settings save retry")
        XCTAssertEqual(restored["repositoryWriteAttempts"] as? Int, 0, "No attempt with a stale expected revision")
        for key in ["ready", "feedbackNil", "readErrorNil", "scheduleErrorNil", "todayMissing"] {
            XCTAssertEqual(restored[key] as? Bool, true, key)
        }
        XCTAssertEqual(try Data(contentsOf: paths.settings), bytes)
        print("T014 PROCESS EVIDENCE commit=\(committed) restore=\(restored) selfSignalReceipt=\(signalReceipt) terminated=\(!writer.isRunning) parentKillNotAttempted=true waitpidStatus=unavailable")
        // Kept as bounded ephemeral evidence for parent collection; cleanup needs authorization.
    }

    func testEarningSurvivesRealProcessTerminationAndScheduledEndRecoveryStopsGrowth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockRecovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = RecordRepositoryPaths(root: root)
        var children: [Stage9IsolatedApplicationProcess] = []
        defer { for child in children { child.terminateIfRunning() } }

        func run(_ mode: String, day: Int = 13, hour: Int) async throws -> ([String: Any], Stage9IsolatedApplicationProcess) {
            let result = root.appendingPathComponent("\(mode)-\(day)-\(hour).json")
            let child = try await Stage9IsolatedApplicationProcess.launch(root: root, mode: mode,
                output: result, time: ApplicationTestSupport.timestamp(day: day, hour: hour))
            children.append(child)
            return (try await child.readResult(), child)
        }
        let (committed, writer) = try await run("earning-commit", hour: 10)
        XCTAssertEqual(committed["state"] as? String, "EARNING")
        XCTAssertEqual(committed["writes"] as? Int, 2)
        let settingsBytes = try Data(contentsOf: paths.settings)
        let todayBytes = try Data(contentsOf: paths.today)
        XCTAssertTrue(writer.isRunning, "Committed earning writer remains alive until SIGKILL")
        let signalReceipt = try await writer.requestSelfSIGKILLAndWait()
        XCTAssertFalse(writer.isRunning)
        print("EARNING PROCESS TERMINATION pid=\(writer.processIdentifier) selfSignalReceipt=\(signalReceipt) terminated=\(!writer.isRunning) parentKillNotAttempted=true waitpidStatus=unavailable")

        var observations: [[String: Any]] = []
        for hour in [12, 18, 20] {
            let (restored, child) = try await run("earning-restore", hour: hour)
            try await child.waitForTermination()
            XCTAssertFalse(child.isRunning)
            XCTAssertNotEqual(restored["pid"] as? Int, committed["pid"] as? Int)
            XCTAssertEqual(restored["revision"] as? Int, 1)
            XCTAssertEqual(restored["writes"] as? Int, 0)
            XCTAssertEqual(restored["saveCommandEntries"] as? Int, 0)
            XCTAssertEqual(restored["repositoryWriteAttempts"] as? Int, 0)
            XCTAssertEqual(restored["clockInAt"] as? Int64, ApplicationTestSupport.timestamp(hour: 10).rawValue)
            XCTAssertEqual(restored["feedbackNil"] as? Bool, true)
            XCTAssertEqual(restored["todayMissing"] as? Bool, false)
            XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
            XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)
            observations.append(restored)
        }
        XCTAssertEqual(observations[0]["state"] as? String, "EARNING")
        XCTAssertEqual(observations[0]["amountKind"] as? String, "live")
        XCTAssertEqual(observations[0]["earnedDuration"] as? Int, 7_200_000)
        XCTAssertGreaterThan(try XCTUnwrap(observations[0]["amountRaw"] as? Int), 0)
        for stopped in observations[1...] {
            XCTAssertEqual(stopped["state"] as? String, "AWAITING_CLOCK_OUT")
            XCTAssertEqual(stopped["amountKind"] as? String, "rounded")
            XCTAssertEqual(stopped["earnedDuration"] as? Int, 28_800_000)
            XCTAssertEqual(stopped["amountRaw"] as? Int, 78_222)
        }
        XCTAssertEqual(observations[1]["amountRaw"] as? Int, observations[2]["amountRaw"] as? Int)
        // Restore the uncompleted old workday in another actual process at midnight
        // and next morning; system wall clock and timezone remain untouched.
        for hour in [0, 8] {
            let (oldDay, child) = try await run("prior-day-restore", day: 14, hour: hour)
            try await child.waitForTermination()
            XCTAssertFalse(child.isRunning)
            XCTAssertNotEqual(oldDay["pid"] as? Int, committed["pid"] as? Int)
            XCTAssertEqual(oldDay["workDate"] as? String, "2026-08-13")
            XCTAssertEqual(oldDay["isPreviousWorkday"] as? Bool, true)
            XCTAssertEqual(oldDay["state"] as? String, "AWAITING_CLOCK_OUT")
            XCTAssertEqual(oldDay["canClockIn"] as? Bool, false)
            XCTAssertEqual(oldDay["newClockInWasRejected"] as? Bool, true)
            XCTAssertEqual(oldDay["amountKind"] as? String, "rounded")
            XCTAssertEqual(oldDay["amountRaw"] as? Int, 78_222)
            XCTAssertEqual(oldDay["earnedDuration"] as? Int, 28_800_000)
            XCTAssertEqual(oldDay["clockInAt"] as? Int64, ApplicationTestSupport.timestamp(hour: 10).rawValue)
            XCTAssertEqual(oldDay["writes"] as? Int, 0)
            XCTAssertEqual(oldDay["saveCommandEntries"] as? Int, 0)
            XCTAssertEqual(oldDay["repositoryWriteAttempts"] as? Int, 0)
            XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)
            XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
            print("P22-018 PRIOR-DAY PROCESS RECOVERY hour=\(hour) result=\(oldDay)")
        }
        print("PROCESS EARNING RECOVERY committed=\(committed) recoveries=\(observations)")
    }

    func testRunningSettingsPresentationObservesOnlyPersistedCommittedSuccess() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let store = try makeStore(repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8)))
        await store.restore()
        var observed: [(BusinessFeedback, String, Bool, SettingsRecord)] = []
        let observation = expectation(description: "Real WorkRulesSettingsView onChange consumes committed feedback")
        let view = WorkRulesSettingsView(businessStore: store, messageObserver: { feedback, text, isError in
            do {
                let persisted = try JSONDecoder().decode(SettingsRecord.self, from: Data(contentsOf: paths.settings))
                observed.append((feedback, text, isError, persisted))
                observation.fulfill()
            } catch { XCTFail("Presentation observed feedback before persisted Settings: \(error)") }
        })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        try await Task.sleep(nanoseconds: 100_000_000)
        let outcome = await store.send(.saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)), source: .settings)
        XCTAssertEqual(outcome, .committed)
        await fulfillment(of: [observation], timeout: 3)
        XCTAssertEqual(observed.count, 1)
        let result = try XCTUnwrap(observed.first)
        guard case let .settingsSaved(receipt) = result.0 else { return XCTFail("Expected committed success") }
        XCTAssertEqual(receipt.committedRevision, result.3.revision)
        XCTAssertEqual(result.3.dailyWageCents, 88_000)
        XCTAssertEqual(result.1, "设置已保存")
        XCTAssertFalse(result.2)
        XCTAssertEqual(store.viewState?.state, .ready)
    }

    func testDamagedSettingsWithoutTodayResetConfirmationSurvivesRefreshCancelsAndCommits() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(at: paths.recordsDirectory, withIntermediateDirectories: true)
        let damaged = Data("{invalid-settings".utf8)
        try damaged.write(to: paths.settings)
        let repository = RecordRepositoryActor(paths: paths)
        let store = try makeStore(repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)))
        await store.restore()
        XCTAssertNil(store.viewState)
        XCTAssertEqual(store.settingsReadErrorViewState?.isBlocking, true)
        // Recovery cancellation is permitted only for an existing Settings
        // reset confirmation; other commands remain blocked without a state.
        let noConfirmation = await store.send(.cancelConfirmation, source: .panel)
        XCTAssertEqual(noConfirmation, .rejected(.storeNotRestored))
        let requested = await store.send(.requestSettingsReset, source: .panel)
        XCTAssertEqual(requested, .confirmationPresented)
        await store.refresh()
        XCTAssertEqual(store.confirmation, .resetSettings)
        XCTAssertNil(store.viewState)
        XCTAssertEqual(try Data(contentsOf: paths.settings), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
        for command in [BusinessCommand.clockIn, .requestClockOut, .requestTodayReset, .requestStartToday] {
            let rejected = await store.send(command, source: .panel)
            XCTAssertEqual(rejected, .rejected(.storeNotRestored))
            XCTAssertEqual(store.confirmation, .resetSettings)
        }
        let cancelled = await store.send(.cancelConfirmation, source: .panel)
        XCTAssertEqual(cancelled, .confirmationCancelled)
        await store.refresh()
        XCTAssertNil(store.confirmation)
        XCTAssertNil(store.viewState)
        XCTAssertEqual(store.settingsReadErrorViewState?.isBlocking, true)
        XCTAssertEqual(try Data(contentsOf: paths.settings), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
        let requestedAgain = await store.send(.requestSettingsReset, source: .panel)
        XCTAssertEqual(requestedAgain, .confirmationPresented)
        await store.refresh()
        XCTAssertEqual(store.confirmation, .resetSettings)
        let committed = await store.send(.confirmSettingsReset, source: .panel)
        XCTAssertEqual(committed, .committed)
        await store.refresh()
        XCTAssertEqual(store.viewState?.state, .unconfigured)
        XCTAssertNil(store.confirmation)
        XCTAssertNil(store.settingsReadErrorViewState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
        let persisted = await repository.loadSettingsForBusiness()
        guard case .missing = persisted else { return XCTFail("Confirmed reset must persist missing Settings") }
        // Retain the isolated fixture; no cleanup authorization is inferred.
    }

    func testDoubleDamageFileBytesSurviveCancellationAndBothResetAndReplacementOrders() async throws {
        // T-018: actual independent temporary files, with byte identity at every transition.
        for order in ["settings-first", "today-first", "replace-first"] {
            let root = try ApplicationTestSupport.makeTemporaryRoot()
            let paths = RecordRepositoryPaths(root: root)
            try FileManager.default.createDirectory(at: paths.recordsDirectory, withIntermediateDirectories: true)
            let badSettings = Data("broken-settings-\(order)".utf8)
            let badToday = Data("broken-today-\(order)".utf8)
            try badSettings.write(to: paths.settings)
            try badToday.write(to: paths.today)
            let repository = RecordRepositoryActor(paths: paths)
            let store = try makeStore(repository: repository,
                clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)))
            await store.restore()
            XCTAssertEqual(store.viewState?.state, .recoveryRequired)
            XCTAssertEqual(store.viewState?.amount, .hidden)
            XCTAssertEqual(store.settingsReadErrorViewState?.isBlocking, false)
            XCTAssertEqual(try Data(contentsOf: paths.settings), badSettings)
            XCTAssertEqual(try Data(contentsOf: paths.today), badToday)
            for request in [BusinessCommand.requestSettingsReset, .requestTodayReset] {
                _ = await store.send(request, source: .settings)
                _ = await store.send(.cancelConfirmation, source: .settings)
                XCTAssertEqual(try Data(contentsOf: paths.settings), badSettings)
                XCTAssertEqual(try Data(contentsOf: paths.today), badToday)
                XCTAssertEqual(store.viewState?.state, .recoveryRequired)
                XCTAssertNil(store.confirmation)
            }
            if order == "today-first" {
                _ = await store.send(.requestTodayReset, source: .settings)
                let first = await store.send(.confirmTodayReset, source: .settings)
                XCTAssertEqual(first, .committed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
                XCTAssertEqual(try Data(contentsOf: paths.settings), badSettings)
                XCTAssertNil(store.viewState)
                XCTAssertEqual(store.settingsReadErrorViewState?.isBlocking, true)
                _ = await store.send(.requestSettingsReset, source: .settings)
                let second = await store.send(.confirmSettingsReset, source: .settings)
                XCTAssertEqual(second, .committed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path))
                XCTAssertEqual(store.viewState?.state, .unconfigured)
            } else {
                if order == "settings-first" {
                    _ = await store.send(.requestSettingsReset, source: .settings)
                    let first = await store.send(.confirmSettingsReset, source: .settings)
                    XCTAssertEqual(first, .committed)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.settings.path))
                } else {
                    let first = await store.send(.saveWorkRules(ApplicationTestSupport.workRules()), source: .settings)
                    XCTAssertEqual(first, .committed)
                    let saved = try JSONDecoder().decode(SettingsRecord.self, from: Data(contentsOf: paths.settings))
                    XCTAssertEqual(saved.dailyWageCents, 30_000)
                }
                XCTAssertEqual(try Data(contentsOf: paths.today), badToday)
                XCTAssertEqual(store.viewState?.state, .recoveryRequired)
                XCTAssertEqual(store.viewState?.amount, .hidden)
                XCTAssertNil(store.settingsReadErrorViewState)
                let settingsAfterFirst = try? Data(contentsOf: paths.settings)
                _ = await store.send(.requestTodayReset, source: .settings)
                let second = await store.send(.confirmTodayReset, source: .settings)
                XCTAssertEqual(second, .committed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.today.path))
                XCTAssertEqual(try? Data(contentsOf: paths.settings), settingsAfterFirst)
                XCTAssertEqual(store.viewState?.state, order == "replace-first" ? .ready : .unconfigured)
            }
            XCTAssertNil(store.settingsReadErrorViewState)
            XCTAssertFalse(store.isCommandInFlight)
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

    private func commitSettingsForRestartEvidence(
        paths: RecordRepositoryPaths
    ) async throws -> SettingsCommitRestartEvidence {
        let repository = RecordRepositoryActor(paths: paths)
        let store = try makeStore(
            repository: repository,
            clock: MutableTestClock(ApplicationTestSupport.timestamp(hour: 8))
        )
        await store.restore()

        let outcome = await store.send(
            .saveWorkRules(ApplicationTestSupport.workRules(wageCents: 88_000)),
            source: .settings
        )
        XCTAssertEqual(outcome, .committed)
        guard case let .settingsSaved(receipt) = store.feedback else {
            throw PersistenceError.invalidProposedRecord
        }

        let loaded = await repository.loadSettingsForBusiness()
        guard case let .loaded(record, token) = loaded else {
            throw PersistenceError.invalidProposedRecord
        }
        XCTAssertEqual(token, .loaded(receipt.committedRevision))
        XCTAssertEqual(record.revision, receipt.committedRevision)
        XCTAssertEqual(record.dailyWageCents, 88_000)

        let today = await repository.loadToday()
        XCTAssertEqual(today, .missing)
        let bytes = try Data(contentsOf: paths.settings)
        XCTAssertEqual(bytes, try CanonicalRecordEncoder.encode(record))
        return .init(record: record, bytes: bytes, receipt: receipt)
    }
}
