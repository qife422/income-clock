import Foundation

enum PersistenceRecordKind: String, CaseIterable, Hashable, Sendable {
    case settings
    case today
    case themePreferences
}

enum RecordRecoveryDisposition: Equatable, Sendable {
    case requireSettingsRecovery
    case requireTodayReset
    case useDefaultThemePreferences
}

enum RecordDamageIssue: Equatable, Sendable {
    case readFailed
    case invalidSchemaEnvelope
    case unsupportedSchemaVersion(Int)
    case decodingFailed
    case validationFailed
    case migrationFailed(sourceSchemaVersion: Int)
    case migrationCommitFailed(sourceSchemaVersion: Int)
}

struct DamagedRecordResult: Equatable, Sendable {
    let kind: PersistenceRecordKind
    let issue: RecordDamageIssue
    let disposition: RecordRecoveryDisposition
}

enum RecordMigrationStatus: Equatable, Sendable {
    case current
    case migrated(fromSchemaVersion: Int)
}

enum RecordLoadResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case missing
    case loaded(Value, migration: RecordMigrationStatus)
    case damaged(DamagedRecordResult)
}

enum SettingsRecordToken: Equatable, Sendable {
    case missing
    case loaded(RecordRevision)
    case damaged(Data)
    case unreadableDamage
}

enum SettingsTypedLoadResult: Equatable, Sendable {
    case missing(SettingsRecordToken)
    case loaded(SettingsRecord, token: SettingsRecordToken)
    case damaged(DamagedRecordResult, token: SettingsRecordToken)

    var token: SettingsRecordToken {
        switch self {
        case let .missing(token), let .loaded(_, token), let .damaged(_, token):
            token
        }
    }
}

enum TodayRecordToken: Equatable, Sendable {
    case missing
    case loaded(RecordRevision)
    case damaged(Data)
    case unreadableDamage
}

enum TodayTypedLoadResult: Equatable, Sendable {
    case missing(TodayRecordToken)
    case loaded(TodayRecord, token: TodayRecordToken)
    case damaged(DamagedRecordResult, token: TodayRecordToken)

    var token: TodayRecordToken {
        switch self {
        case let .missing(token), let .loaded(_, token), let .damaged(_, token): token
        }
    }
}

struct SettingsCommitIntent: Equatable, Sendable {
    let commandID: UUID
    let expectedToken: SettingsRecordToken
    let committedRecord: SettingsRecord
    let canonicalBytes: Data
}

struct SettingsCommitResult: Equatable, Sendable {
    let commandID: UUID
    let record: SettingsRecord
}

struct StartTodayCommitIntent: Equatable, Sendable {
    let commandID: UUID
    let expectedTodayRevision: RecordRevision
    let expectedSettingsToken: SettingsRecordToken
}

struct StartTodayCommitResult: Equatable, Sendable {
    let commandID: UUID
}

enum CanonicalRecordEncoder {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw PersistenceError.invalidProposedRecord
        }
    }
}

enum PersistenceError: Error, Equatable, Sendable {
    case revisionConflict(expected: RecordRevision?, actual: RecordRevision?)
    case revisionOverflow
    case damagedRecordRequiresRecovery(PersistenceRecordKind)
    case atomicWriteFailed
    case deleteFailed
    case diagnosticBackupFailed
    case invalidProposedRecord
}
