import Foundation

actor RecordRepositoryActor {
    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private let paths: RecordRepositoryPaths
    private let fileStore: any RecordFileStore
    private let migrations: RecordMigrationRegistry
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var knownRevisions: [PersistenceRecordKind: RecordRevision] = [:]

    init(
        paths: RecordRepositoryPaths,
        fileStore: any RecordFileStore = AtomicRecordFileStore(),
        migrations: RecordMigrationRegistry = .currentOnly
    ) {
        self.paths = paths
        self.fileStore = fileStore
        self.migrations = migrations
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func loadSettings() -> RecordLoadResult<SettingsRecord> {
        observe(
            load(
            SettingsRecord.self,
            kind: .settings,
            from: paths.settings,
            migrators: migrations.settings
            ),
            kind: .settings
        )
    }

    func loadSettingsForBusiness() -> SettingsTypedLoadResult {
        let result = loadSettings()
        switch result {
        case .missing:
            return .missing(.missing)
        case let .loaded(record, _):
            return .loaded(record, token: .loaded(record.revision))
        case let .damaged(damage):
            return .damaged(damage, token: currentDamagedSettingsToken())
        }
    }

    func loadToday() -> RecordLoadResult<TodayRecord> {
        observe(
            load(
            TodayRecord.self,
            kind: .today,
            from: paths.today,
            migrators: migrations.today
            ),
            kind: .today
        )
    }

    func loadTodayForBusiness() -> TodayTypedLoadResult {
        let result = loadToday()
        switch result {
        case .missing: return .missing(.missing)
        case let .loaded(record, _): return .loaded(record, token: .loaded(record.revision))
        case let .damaged(damage): return .damaged(damage, token: currentDamagedTodayToken())
        }
    }

    func loadThemePreferences() -> RecordLoadResult<ThemePreferencesRecord> {
        observe(
            load(
            ThemePreferencesRecord.self,
            kind: .themePreferences,
            from: paths.themePreferences,
            migrators: migrations.themePreferences
            ),
            kind: .themePreferences
        )
    }

    func saveSettings(
        _ proposed: SettingsRecord,
        expectedRevision: RecordRevision?
    ) throws -> SettingsRecord {
        try save(
            proposed,
            expectedRevision: expectedRevision,
            kind: .settings,
            at: paths.settings,
            migrators: migrations.settings
        )
    }

    func saveToday(
        _ proposed: TodayRecord,
        expectedRevision: RecordRevision?
    ) throws -> TodayRecord {
        try save(
            proposed,
            expectedRevision: expectedRevision,
            kind: .today,
            at: paths.today,
            migrators: migrations.today
        )
    }

    func saveThemePreferences(
        _ proposed: ThemePreferencesRecord,
        expectedRevision: RecordRevision?
    ) throws -> ThemePreferencesRecord {
        try save(
            proposed,
            expectedRevision: expectedRevision,
            kind: .themePreferences,
            at: paths.themePreferences,
            migrators: migrations.themePreferences
        )
    }

    func recoverSettings(_ proposed: SettingsRecord) throws -> SettingsRecord {
        try recoverDamaged(
            proposed,
            kind: .settings,
            at: paths.settings
        )
    }

    func commitSaveSettings(_ intent: SettingsCommitIntent) throws -> SettingsCommitResult {
        guard try CanonicalRecordEncoder.encode(intent.committedRecord) == intent.canonicalBytes else {
            throw PersistenceError.invalidProposedRecord
        }
        do {
            try intent.committedRecord.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }

        let current = loadSettingsForBusiness()
        guard current.token == intent.expectedToken else {
            throw settingsConflict(expected: intent.expectedToken, actual: current.token)
        }

        switch intent.expectedToken {
        case let .loaded(revision):
            let expectedNextRevision = try revision.next()
            guard intent.committedRecord.revision == expectedNextRevision else {
                throw PersistenceError.invalidProposedRecord
            }
        case .missing, .damaged, .unreadableDamage:
            guard intent.committedRecord.revision == RecordRevision(rawValue: 1) else {
                throw PersistenceError.invalidProposedRecord
            }
        }

        if case .damaged = current {
            let backupURL = paths.diagnosticsCorruptDirectory.appendingPathComponent(
                "settings-\(UUID().uuidString).json",
                isDirectory: false
            )
            try fileStore.copyItem(at: paths.settings, to: backupURL)
        }
        do {
            try fileStore.commitAtomically(intent.canonicalBytes, to: paths.settings)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.atomicWriteFailed
        }
        knownRevisions[.settings] = intent.committedRecord.revision
        return SettingsCommitResult(commandID: intent.commandID, record: intent.committedRecord)
    }

    func commitStartToday(_ intent: StartTodayCommitIntent) throws -> StartTodayCommitResult {
        let currentSettings = loadSettingsForBusiness()
        guard currentSettings.token == intent.expectedSettingsToken else {
            throw settingsConflict(expected: intent.expectedSettingsToken, actual: currentSettings.token)
        }
        switch loadToday() {
        case let .loaded(record, _):
            guard record.revision == intent.expectedTodayRevision else {
                throw PersistenceError.revisionConflict(
                    expected: intent.expectedTodayRevision,
                    actual: record.revision
                )
            }
        case .missing:
            throw PersistenceError.revisionConflict(
                expected: intent.expectedTodayRevision,
                actual: nil
            )
        case .damaged:
            throw PersistenceError.damagedRecordRequiresRecovery(.today)
        }
        try fileStore.removeItem(at: paths.today)
        knownRevisions.removeValue(forKey: .today)
        return StartTodayCommitResult(commandID: intent.commandID)
    }

    func resetDamagedSettingsToMissing(expectedToken: SettingsRecordToken) throws {
        let current = loadSettingsForBusiness()
        guard current.token == expectedToken else {
            throw settingsConflict(expected: expectedToken, actual: current.token)
        }
        guard case .damaged = current else {
            throw PersistenceError.damagedRecordRequiresRecovery(.settings)
        }
        let backupURL = paths.diagnosticsCorruptDirectory.appendingPathComponent(
            "settings-\(UUID().uuidString).json",
            isDirectory: false
        )
        try fileStore.copyItem(at: paths.settings, to: backupURL)
        try fileStore.removeItem(at: paths.settings)
        knownRevisions.removeValue(forKey: .settings)
    }

    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) throws -> ThemePreferencesRecord {
        try recoverDamaged(
            proposed,
            kind: .themePreferences,
            at: paths.themePreferences
        )
    }

    func resetToday() throws {
        try fileStore.removeItem(at: paths.today)
        knownRevisions.removeValue(forKey: .today)
    }

    func resetToday(expectedToken: TodayRecordToken) throws {
        let current = loadTodayForBusiness()
        guard current.token == expectedToken else {
            let expectedRevision: RecordRevision?
            let actualRevision: RecordRevision?
            if case let .loaded(revision) = expectedToken { expectedRevision = revision }
            else { expectedRevision = nil }
            if case let .loaded(revision) = current.token { actualRevision = revision }
            else { actualRevision = nil }
            throw PersistenceError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        try fileStore.removeItem(at: paths.today)
        knownRevisions.removeValue(forKey: .today)
    }

    private func load<Value: VersionedPersistenceRecord>(
        _ type: Value.Type,
        kind: PersistenceRecordKind,
        from url: URL,
        migrators: [Int: RecordMigrator<Value>]
    ) -> RecordLoadResult<Value> {
        let data: Data
        do {
            guard let existing = try fileStore.readData(at: url) else {
                return .missing
            }
            data = existing
        } catch {
            return .damaged(damage(kind: kind, issue: .readFailed))
        }

        let sourceSchemaVersion: Int
        do {
            sourceSchemaVersion = try decoder.decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            return .damaged(damage(kind: kind, issue: .invalidSchemaEnvelope))
        }

        if sourceSchemaVersion == Value.currentSchemaVersion {
            let record: Value
            do {
                record = try decoder.decode(Value.self, from: data)
            } catch {
                return .damaged(damage(kind: kind, issue: .decodingFailed))
            }
            do {
                try record.validated()
                return .loaded(record, migration: .current)
            } catch {
                return .damaged(damage(kind: kind, issue: .validationFailed))
            }
        }

        guard let migrator = migrators[sourceSchemaVersion] else {
            return .damaged(
                damage(kind: kind, issue: .unsupportedSchemaVersion(sourceSchemaVersion))
            )
        }

        let migrated: Value
        do {
            migrated = try migrator.migrate(data)
            try migrated.validated()
        } catch {
            return .damaged(
                damage(kind: kind, issue: .migrationFailed(sourceSchemaVersion: sourceSchemaVersion))
            )
        }

        do {
            try fileStore.commitAtomically(try canonicalData(for: migrated), to: url)
            return .loaded(
                migrated,
                migration: .migrated(fromSchemaVersion: sourceSchemaVersion)
            )
        } catch {
            return .damaged(
                damage(
                    kind: kind,
                    issue: .migrationCommitFailed(sourceSchemaVersion: sourceSchemaVersion)
                )
            )
        }
    }

    private func save<Value: VersionedPersistenceRecord>(
        _ proposed: Value,
        expectedRevision: RecordRevision?,
        kind: PersistenceRecordKind,
        at url: URL,
        migrators: [Int: RecordMigrator<Value>]
    ) throws -> Value {
        let current = observe(
            load(Value.self, kind: kind, from: url, migrators: migrators),
            kind: kind
        )
        let actualRevision: RecordRevision?
        switch current {
        case .missing:
            actualRevision = nil
        case let .loaded(record, _):
            actualRevision = record.revision
        case .damaged:
            throw PersistenceError.damagedRecordRequiresRecovery(kind)
        }

        guard expectedRevision == actualRevision else {
            throw PersistenceError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }

        let nextRevision = try (actualRevision ?? .proposed).next()
        let committed = proposed.replacingRevision(nextRevision)
        do {
            try committed.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }

        do {
            try fileStore.commitAtomically(try canonicalData(for: committed), to: url)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.atomicWriteFailed
        }
        knownRevisions[kind] = committed.revision
        return committed
    }

    private func recoverDamaged<Value: VersionedPersistenceRecord>(
        _ proposed: Value,
        kind: PersistenceRecordKind,
        at url: URL
    ) throws -> Value {
        let current = observe(
            load(Value.self, kind: kind, from: url, migrators: [:]),
            kind: kind
        )
        guard case .damaged = current else {
            throw PersistenceError.damagedRecordRequiresRecovery(kind)
        }

        let recovered = proposed.replacingRevision(RecordRevision(rawValue: 1))
        do {
            try recovered.validated()
        } catch {
            throw PersistenceError.invalidProposedRecord
        }

        let backupURL = paths.diagnosticsCorruptDirectory.appendingPathComponent(
            "\(kind.rawValue)-\(UUID().uuidString).json",
            isDirectory: false
        )
        try fileStore.copyItem(at: url, to: backupURL)
        do {
            try fileStore.commitAtomically(try canonicalData(for: recovered), to: url)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.atomicWriteFailed
        }
        knownRevisions[kind] = recovered.revision
        return recovered
    }

    private func canonicalData<Value: Encodable>(for value: Value) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw PersistenceError.invalidProposedRecord
        }
    }

    private func currentDamagedSettingsToken() -> SettingsRecordToken {
        do {
            guard let data = try fileStore.readData(at: paths.settings) else {
                return .missing
            }
            return .damaged(data)
        } catch {
            return .unreadableDamage
        }
    }

    private func currentDamagedTodayToken() -> TodayRecordToken {
        do {
            guard let data = try fileStore.readData(at: paths.today) else { return .missing }
            return .damaged(data)
        } catch {
            return .unreadableDamage
        }
    }

    private func settingsConflict(
        expected: SettingsRecordToken,
        actual: SettingsRecordToken
    ) -> PersistenceError {
        let expectedRevision: RecordRevision?
        let actualRevision: RecordRevision?
        if case let .loaded(revision) = expected { expectedRevision = revision } else { expectedRevision = nil }
        if case let .loaded(revision) = actual { actualRevision = revision } else { actualRevision = nil }
        return .revisionConflict(expected: expectedRevision, actual: actualRevision)
    }

    private func damage(
        kind: PersistenceRecordKind,
        issue: RecordDamageIssue
    ) -> DamagedRecordResult {
        let disposition: RecordRecoveryDisposition
        switch kind {
        case .settings:
            disposition = .requireSettingsRecovery
        case .today:
            disposition = .requireTodayReset
        case .themePreferences:
            disposition = .useDefaultThemePreferences
        }
        return DamagedRecordResult(kind: kind, issue: issue, disposition: disposition)
    }

    private func observe<Value: Equatable & Sendable>(
        _ result: RecordLoadResult<Value>,
        kind: PersistenceRecordKind
    ) -> RecordLoadResult<Value> where Value: VersionedPersistenceRecord {
        switch result {
        case let .loaded(record, _):
            knownRevisions[kind] = record.revision
        case .missing, .damaged:
            knownRevisions.removeValue(forKey: kind)
        }
        return result
    }
}
