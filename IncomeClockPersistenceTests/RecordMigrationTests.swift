import Foundation
import XCTest
@testable import IncomeClock

final class RecordMigrationTests: XCTestCase {
    private struct LegacySettingsFixture: Codable {
        let schemaVersion: Int
        let revision: String
        let wageCents: Int64
        let startMinute: Int
        let endMinute: Int
    }

    private struct LegacyRecordFixture: Codable {
        let schemaVersion: Int
        let revision: String
    }

    func testExplicitFixtureMigrationIsAtomicRepeatableAndRestartReadable() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let legacy = LegacySettingsFixture(
            schemaVersion: 0,
            revision: "7",
            wageCents: 45_000,
            startMinute: 8 * 60,
            endMinute: 17 * 60
        )
        try JSONEncoder().encode(legacy).write(to: paths.settings)

        let migrator = RecordMigrator<SettingsRecord>(sourceSchemaVersion: 0) { data in
            let source = try JSONDecoder().decode(LegacySettingsFixture.self, from: data)
            return SettingsRecord(
                schemaVersion: SettingsRecord.currentSchemaVersion,
                revision: RecordRevision(rawValue: UInt64(source.revision)!),
                dailyWageCents: source.wageCents,
                workStartMinuteOfDay: source.startMinute,
                workEndMinuteOfDay: source.endMinute,
                notificationsEnabled: false,
                alwaysOnTop: true,
                lockPanelPosition: false,
                hideInFullScreen: true,
                launchAtLogin: false,
                panelVisible: true,
                panelPlacement: nil,
                updatedAtMs: 10
            )
        }
        let registry = RecordMigrationRegistry(settings: [migrator])
        let repository = RecordRepositoryActor(paths: paths, migrations: registry)

        let first = await repository.loadSettings()
        guard case let .loaded(migrated, status) = first else {
            return XCTFail("Expected migrated settings")
        }
        XCTAssertEqual(status, .migrated(fromSchemaVersion: 0))
        XCTAssertEqual(migrated.revision, RecordRevision(rawValue: 7))
        XCTAssertEqual(migrated.dailyWageCents, 45_000)

        let restartedRepository = RecordRepositoryActor(paths: paths, migrations: registry)
        let second = await restartedRepository.loadSettings()
        XCTAssertEqual(second, .loaded(migrated, migration: .current))
    }

    func testMigrationCommitFailurePreservesLegacyBytesAndReturnsRecoveryResult() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let legacyData = try JSONEncoder().encode(LegacySettingsFixture(
            schemaVersion: 0,
            revision: "2",
            wageCents: 30_000,
            startMinute: 540,
            endMinute: 1_080
        ))
        try legacyData.write(to: paths.settings)

        let migrator = RecordMigrator<SettingsRecord>(sourceSchemaVersion: 0) { _ in
            PersistenceTestSupport.proposedSettings().replacingRevision(.init(rawValue: 2))
        }
        let fileStore = ControllableRecordFileStore()
        fileStore.failNextCommit()
        let repository = RecordRepositoryActor(
            paths: paths,
            fileStore: fileStore,
            migrations: RecordMigrationRegistry(settings: [migrator])
        )

        let result = await repository.loadSettings()

        XCTAssertEqual(
            result,
            .damaged(DamagedRecordResult(
                kind: .settings,
                issue: .migrationCommitFailed(sourceSchemaVersion: 0),
                disposition: .requireSettingsRecovery
            ))
        )
        XCTAssertEqual(try Data(contentsOf: paths.settings), legacyData)
    }

    func testTodayAndThemeUseTheSameExplicitMigrationPipeline() async throws {
        let root = try PersistenceTestSupport.makeTemporaryRoot()
        defer { PersistenceTestSupport.removeTemporaryRoot(root) }
        let paths = RecordRepositoryPaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recordsDirectory,
            withIntermediateDirectories: true
        )
        let legacyData = try JSONEncoder().encode(LegacyRecordFixture(
            schemaVersion: 0,
            revision: "4"
        ))
        try legacyData.write(to: paths.today)
        try legacyData.write(to: paths.themePreferences)

        let todayMigrator = RecordMigrator<TodayRecord>(sourceSchemaVersion: 0) { _ in
            PersistenceTestSupport.proposedToday().replacingRevision(.init(rawValue: 4))
        }
        let themeMigrator = RecordMigrator<ThemePreferencesRecord>(sourceSchemaVersion: 0) { _ in
            PersistenceTestSupport.proposedThemePreferences().replacingRevision(.init(rawValue: 4))
        }
        let repository = RecordRepositoryActor(
            paths: paths,
            migrations: RecordMigrationRegistry(
                today: [todayMigrator],
                themePreferences: [themeMigrator]
            )
        )

        let today = await repository.loadToday()
        let theme = await repository.loadThemePreferences()

        guard case let .loaded(todayRecord, todayStatus) = today,
              case let .loaded(themeRecord, themeStatus) = theme else {
            return XCTFail("Expected both record types to migrate")
        }
        XCTAssertEqual(todayStatus, .migrated(fromSchemaVersion: 0))
        XCTAssertEqual(themeStatus, .migrated(fromSchemaVersion: 0))
        XCTAssertEqual(todayRecord.revision, RecordRevision(rawValue: 4))
        XCTAssertEqual(themeRecord.revision, RecordRevision(rawValue: 4))
    }
}
