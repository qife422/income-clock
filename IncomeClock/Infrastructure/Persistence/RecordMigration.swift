import Foundation

struct RecordMigrator<Value: VersionedPersistenceRecord>: Sendable {
    let sourceSchemaVersion: Int
    private let transform: @Sendable (Data) throws -> Value

    init(
        sourceSchemaVersion: Int,
        transform: @escaping @Sendable (Data) throws -> Value
    ) {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.transform = transform
    }

    func migrate(_ data: Data) throws -> Value {
        try transform(data)
    }
}

struct RecordMigrationRegistry: Sendable {
    let settings: [Int: RecordMigrator<SettingsRecord>]
    let today: [Int: RecordMigrator<TodayRecord>]
    let themePreferences: [Int: RecordMigrator<ThemePreferencesRecord>]

    init(
        settings: [RecordMigrator<SettingsRecord>] = [],
        today: [RecordMigrator<TodayRecord>] = [],
        themePreferences: [RecordMigrator<ThemePreferencesRecord>] = []
    ) {
        self.settings = Dictionary(uniqueKeysWithValues: settings.map { ($0.sourceSchemaVersion, $0) })
        self.today = Dictionary(uniqueKeysWithValues: today.map { ($0.sourceSchemaVersion, $0) })
        self.themePreferences = Dictionary(
            uniqueKeysWithValues: themePreferences.map { ($0.sourceSchemaVersion, $0) }
        )
    }

    static let currentOnly = RecordMigrationRegistry()
}
