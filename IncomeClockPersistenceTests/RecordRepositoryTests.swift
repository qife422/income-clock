import Foundation
import XCTest
@testable import IncomeClock

final class RecordRepositoryTests: XCTestCase {
    func testMissingFilesReturnMissingWithoutCreatingRealOrTemporaryRecords() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let repository = RecordRepositoryActor(paths: .init(root: root))

        let settings = await repository.loadSettings()
        let today = await repository.loadToday()
        let themePreferences = await repository.loadThemePreferences()
        XCTAssertEqual(settings, .missing)
        XCTAssertEqual(today, .missing)
        XCTAssertEqual(themePreferences, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records").path))
    }

    func testSaveReturnsOnlyAfterAtomicCommitAndNewRepositoryReadsPersistedRecord() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let fileStore = ControllableRecordFileStore()
        let repository = RecordRepositoryActor(paths: paths, fileStore: fileStore)

        let committed = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(),
            expectedRevision: nil
        )

        XCTAssertEqual(committed.revision, RecordRevision(rawValue: 1))
        XCTAssertEqual(fileStore.events.last, .commitFinished("settings.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.settings.path))

        let restartedRepository = RecordRepositoryActor(paths: paths)
        let restartedSettings = await restartedRepository.loadSettings()
        XCTAssertEqual(
            restartedSettings,
            .loaded(committed, migration: .current)
        )
    }

    func testThreeRecordTypesPersistIndependentlyAcrossRestart() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)

        let settings = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(), expectedRevision: nil
        )
        let today = try await repository.saveToday(
            PersistenceTestSupport.proposedToday(), expectedRevision: nil
        )
        let theme = try await repository.saveThemePreferences(
            PersistenceTestSupport.proposedThemePreferences(), expectedRevision: nil
        )

        let restarted = RecordRepositoryActor(paths: paths)
        let restartedSettings = await restarted.loadSettings()
        let restartedToday = await restarted.loadToday()
        let restartedTheme = await restarted.loadThemePreferences()
        XCTAssertEqual(restartedSettings, .loaded(settings, migration: .current))
        XCTAssertEqual(restartedToday, .loaded(today, migration: .current))
        XCTAssertEqual(restartedTheme, .loaded(theme, migration: .current))
    }

    func testCorruptedTodayIsPreservedRequiresResetAndCannotBeOverwritten() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let committedSettings = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(),
            expectedRevision: nil
        )
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let corrupted = Data("not-json-and-untrusted-income".utf8)
        try corrupted.write(to: paths.today)

        let damagedToday = await repository.loadToday()
        XCTAssertEqual(
            damagedToday,
            .damaged(DamagedRecordResult(
                kind: .today,
                issue: .invalidSchemaEnvelope,
                disposition: .requireTodayReset
            ))
        )
        XCTAssertEqual(try Data(contentsOf: paths.today), corrupted)

        do {
            _ = try await repository.saveToday(
                PersistenceTestSupport.proposedToday(),
                expectedRevision: nil
            )
            XCTFail("Damaged Today must not be overwritten")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .damagedRecordRequiresRecovery(.today)
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.today), corrupted)

        try await repository.resetToday()
        let afterReset = await repository.loadToday()
        let settingsAfterReset = await repository.loadSettings()
        XCTAssertEqual(afterReset, .missing)
        XCTAssertEqual(settingsAfterReset, .loaded(committedSettings, migration: .current))
    }

    func testCorruptSettingsAndThemeReturnTheirIndependentSafeDispositions() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        try Data("{".utf8).write(to: paths.settings)
        try Data("[]".utf8).write(to: paths.themePreferences)
        let repository = RecordRepositoryActor(paths: paths)

        let damagedSettings = await repository.loadSettings()
        let damagedThemePreferences = await repository.loadThemePreferences()
        XCTAssertEqual(
            damagedSettings,
            .damaged(DamagedRecordResult(
                kind: .settings,
                issue: .invalidSchemaEnvelope,
                disposition: .requireSettingsRecovery
            ))
        )
        XCTAssertEqual(
            damagedThemePreferences,
            .damaged(DamagedRecordResult(
                kind: .themePreferences,
                issue: .invalidSchemaEnvelope,
                disposition: .useDefaultThemePreferences
            ))
        )
    }

    func testUnknownSchemaFailsClosedAndLeavesOriginalBytesUnchanged() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let unknown = Data("{\"schemaVersion\":99,\"revision\":\"1\"}".utf8)
        try unknown.write(to: paths.today)
        let repository = RecordRepositoryActor(paths: paths)

        let unknownToday = await repository.loadToday()
        XCTAssertEqual(
            unknownToday,
            .damaged(DamagedRecordResult(
                kind: .today,
                issue: .unsupportedSchemaVersion(99),
                disposition: .requireTodayReset
            ))
        )
        XCTAssertEqual(try Data(contentsOf: paths.today), unknown)
    }

    func testRevisionConflictRejectsStaleCommitWithoutChangingFile() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let first = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(updatedAtMs: 1),
            expectedRevision: nil
        )
        let second = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(updatedAtMs: 2),
            expectedRevision: first.revision
        )
        let bytesBeforeConflict = try Data(contentsOf: paths.settings)

        do {
            _ = try await repository.saveSettings(
                PersistenceTestSupport.proposedSettings(updatedAtMs: 3),
                expectedRevision: first.revision
            )
            XCTFail("Stale revision must fail")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .revisionConflict(expected: first.revision, actual: second.revision)
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.settings), bytesBeforeConflict)
    }

    func testAtomicReplacementFailureKeepsPreviousRecordAndLeavesNoTemporaryFile() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let initialRepository = RecordRepositoryActor(paths: paths)
        let first = try await initialRepository.saveSettings(
            PersistenceTestSupport.proposedSettings(updatedAtMs: 1),
            expectedRevision: nil
        )
        let originalBytes = try Data(contentsOf: paths.settings)
        let failingStore = AtomicRecordFileStore(replacer: FailingAtomicFileReplacer())
        let repository = RecordRepositoryActor(paths: paths, fileStore: failingStore)

        do {
            _ = try await repository.saveSettings(
                PersistenceTestSupport.proposedSettings(updatedAtMs: 2),
                expectedRevision: first.revision
            )
            XCTFail("Injected atomic replacement failure must fail")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .atomicWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: paths.settings), originalBytes)
        let recordFiles = try FileManager.default.contentsOfDirectory(
            at: paths.recordsDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordFiles.map(\.lastPathComponent), ["settings.json"])
        let afterFailure = await repository.loadSettings()
        XCTAssertEqual(afterFailure, .loaded(first, migration: .current))
    }

    func testConcurrentWritesWithSameRevisionProduceOneCommitAndOneConflict() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let repository = RecordRepositoryActor(paths: .init(root: root))
        let first = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(updatedAtMs: 1),
            expectedRevision: nil
        )

        let taskA = Task { () -> Result<SettingsRecord, PersistenceError> in
            do {
                return Result<SettingsRecord, PersistenceError>.success(
                    try await repository.saveSettings(
                        PersistenceTestSupport.proposedSettings(updatedAtMs: 2),
                        expectedRevision: first.revision
                    )
                )
            } catch {
                return .failure(error as? PersistenceError ?? .invalidProposedRecord)
            }
        }
        let taskB = Task { () -> Result<SettingsRecord, PersistenceError> in
            do {
                return Result<SettingsRecord, PersistenceError>.success(
                    try await repository.saveSettings(
                        PersistenceTestSupport.proposedSettings(updatedAtMs: 3),
                        expectedRevision: first.revision
                    )
                )
            } catch {
                return .failure(error as? PersistenceError ?? .invalidProposedRecord)
            }
        }
        let results = await [taskA.value, taskB.value]

        XCTAssertEqual(results.filter(\.isSuccess).count, 1)
        XCTAssertEqual(results.filter(\.isFailure).count, 1)
        let conflict = results.compactMap { result -> PersistenceError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }.first
        XCTAssertEqual(
            conflict,
            .revisionConflict(
                expected: first.revision,
                actual: RecordRevision(rawValue: 2)
            )
        )
    }

    func testExplicitThemeRecoveryBacksUpDamageBeforeReplacingPreferences() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let corrupted = Data("corrupt-theme-preferences".utf8)
        try corrupted.write(to: paths.themePreferences)
        let repository = RecordRepositoryActor(paths: paths)

        let recovered = try await repository.recoverThemePreferences(
            PersistenceTestSupport.proposedThemePreferences()
        )

        XCTAssertEqual(recovered.revision, RecordRevision(rawValue: 1))
        let loadedPreferences = await repository.loadThemePreferences()
        XCTAssertEqual(
            loadedPreferences,
            .loaded(recovered, migration: .current)
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: paths.diagnosticsCorruptDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corrupted)
    }

    func testExplicitSettingsRecoveryBacksUpDamageAndLeavesTodayAndThemeUnchanged() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let committedToday = try await repository.saveToday(
            PersistenceTestSupport.proposedToday(),
            expectedRevision: nil
        )
        let committedTheme = try await repository.saveThemePreferences(
            PersistenceTestSupport.proposedThemePreferences(),
            expectedRevision: nil
        )
        let todayBytesBeforeRecovery = try Data(contentsOf: paths.today)
        let themeBytesBeforeRecovery = try Data(contentsOf: paths.themePreferences)
        let corruptedSettings = Data("corrupt-settings".utf8)
        try corruptedSettings.write(to: paths.settings)

        let recovered = try await repository.recoverSettings(
            PersistenceTestSupport.proposedSettings()
        )

        XCTAssertEqual(recovered.revision, RecordRevision(rawValue: 1))
        let loadedSettings = await repository.loadSettings()
        XCTAssertEqual(loadedSettings, .loaded(recovered, migration: .current))

        let backups = try FileManager.default.contentsOfDirectory(
            at: paths.diagnosticsCorruptDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.hasPrefix("settings-"))
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptedSettings)

        let loadedToday = await repository.loadToday()
        let loadedTheme = await repository.loadThemePreferences()
        XCTAssertEqual(loadedToday, .loaded(committedToday, migration: .current))
        XCTAssertEqual(loadedTheme, .loaded(committedTheme, migration: .current))
        XCTAssertEqual(try Data(contentsOf: paths.today), todayBytesBeforeRecovery)
        XCTAssertEqual(try Data(contentsOf: paths.themePreferences), themeBytesBeforeRecovery)
    }

    func testTypedSettingsLoadDistinguishesMissingLoadedAndDamagedTokens() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)

        let missing = await repository.loadSettingsForBusiness()
        XCTAssertEqual(missing, .missing(.missing))
        let committed = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(), expectedRevision: nil
        )
        let loaded = await repository.loadSettingsForBusiness()
        XCTAssertEqual(loaded, .loaded(committed, token: .loaded(committed.revision)))

        let damagedBytes = Data("damaged-settings-token".utf8)
        try damagedBytes.write(to: paths.settings)
        let damaged = await repository.loadSettingsForBusiness()
        guard case let .damaged(_, token) = damaged else {
            return XCTFail("Expected damaged typed load")
        }
        XCTAssertEqual(token, .damaged(damagedBytes))
    }

    func testCommitSaveSettingsUsesTokenCASAndPreservesBytesOnConflict() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let commandID = UUID()
        let first = PersistenceTestSupport.proposedSettings()
            .replacingRevision(.init(rawValue: 1))
        let firstIntent = SettingsCommitIntent(
            commandID: commandID,
            expectedToken: .missing,
            committedRecord: first,
            canonicalBytes: try CanonicalRecordEncoder.encode(first)
        )
        let firstResult = try await repository.commitSaveSettings(firstIntent)
        XCTAssertEqual(firstResult, .init(commandID: commandID, record: first))
        let bytes = try Data(contentsOf: paths.settings)

        do {
            _ = try await repository.commitSaveSettings(firstIntent)
            XCTFail("Stale missing token must conflict")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .revisionConflict(expected: nil, actual: .init(rawValue: 1))
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.settings), bytes)
    }

    func testCommitStartTodayChecksBothTokensBeforeDeleting() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        let repository = RecordRepositoryActor(paths: paths)
        let settings = try await repository.saveSettings(
            PersistenceTestSupport.proposedSettings(), expectedRevision: nil
        )
        let today = try await repository.saveToday(
            PersistenceTestSupport.proposedToday(
                clockOutAtMs: PersistenceTestSupport.milliseconds(
                    year: 2026, month: 8, day: 14, hour: 8
                )
            ),
            expectedRevision: nil
        )
        let todayBytes = try Data(contentsOf: paths.today)

        do {
            _ = try await repository.commitStartToday(.init(
                commandID: UUID(),
                expectedTodayRevision: today.revision,
                expectedSettingsToken: .missing
            ))
            XCTFail("Settings token conflict must not delete Today")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .revisionConflict(expected: nil, actual: settings.revision)
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)

        // The intent has already captured the preflight tokens. A separate repository
        // acts as an external writer before the real commitStartToday CAS executes.
        let intent = StartTodayCommitIntent(commandID: UUID(), expectedTodayRevision: today.revision,
            expectedSettingsToken: .loaded(settings.revision))
        let settingsBytes = try Data(contentsOf: paths.settings)
        let externalRepository = RecordRepositoryActor(paths: paths)
        let externalToday = try await externalRepository.saveToday(today, expectedRevision: today.revision)
        XCTAssertEqual(externalToday.revision, .init(rawValue: today.revision.rawValue + 1))
        let externalBytes = try Data(contentsOf: paths.today)
        XCTAssertNotEqual(externalBytes, todayBytes)
        do {
            _ = try await repository.commitStartToday(intent)
            XCTFail("Stale Today token must not delete or overwrite the external revision")
        } catch {
            XCTAssertEqual(error as? PersistenceError,
                .revisionConflict(expected: today.revision, actual: externalToday.revision))
        }
        XCTAssertEqual(try Data(contentsOf: paths.today), externalBytes)
        XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
        let preserved = await externalRepository.loadToday()
        XCTAssertEqual(preserved, .loaded(externalToday, migration: .current))

        _ = try await repository.commitStartToday(.init(
            commandID: UUID(),
            expectedTodayRevision: externalToday.revision,
            expectedSettingsToken: .loaded(settings.revision)
        ))
        XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
        let afterStart = await repository.loadToday()
        XCTAssertEqual(afterStart, .missing)
    }

    func testTodayResetUsesDamageTokenCAS() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let original = Data("damaged-today-a".utf8)
        try original.write(to: paths.today)
        let repository = RecordRepositoryActor(paths: paths)
        let firstLoad = await repository.loadTodayForBusiness()
        guard case let .damaged(_, token) = firstLoad else {
            return XCTFail("Expected damaged Today token")
        }

        let replacement = Data("damaged-today-b".utf8)
        try replacement.write(to: paths.today)
        do {
            try await repository.resetToday(expectedToken: token)
            XCTFail("Stale damage token must not delete replacement")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .revisionConflict(expected: nil, actual: nil)
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.today), replacement)

        let secondLoad = await repository.loadTodayForBusiness()
        try await repository.resetToday(expectedToken: secondLoad.token)
        let afterReset = await repository.loadTodayForBusiness()
        XCTAssertEqual(afterReset, .missing(.missing))
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool { !isSuccess }
}
