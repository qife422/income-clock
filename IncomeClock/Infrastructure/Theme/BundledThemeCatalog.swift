import Foundation

struct BundledThemeCatalog: ThemeCatalogProviding, @unchecked Sendable {
    private let bundle: Bundle
    private let decoder = JSONDecoder()

    init(bundle: Bundle = ThemeResourceBundle.bundle) {
        self.bundle = bundle
    }

    func loadBuiltInThemes() async -> ThemeCatalogSnapshot {
        var themes: [ValidatedTheme] = []
        var diagnostics: [String] = []
        for id in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            do {
                let manifest = try loadManifest(themeID: id)
                themes.append(try BuiltinThemeValidator.validate(manifest))
            } catch {
                diagnostics.append("\(id): \(error)")
            }
        }

        if !themes.contains(where: { $0.id == BuiltinThemeID.warmIsland }) {
            themes.append(.warmIslandFallback)
            diagnostics.append("默认内置皮肤资源无法读取，已使用应用安全 Token。")
        }
        themes.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return ThemeCatalogSnapshot(themes: themes, diagnostics: diagnostics)
    }

    private func loadManifest(themeID: String) throws -> ThemeManifest {
        let subdirectory = "BuiltinThemes/\(themeID)"
        guard let url = bundle.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decoder.decode(ThemeManifest.self, from: Data(contentsOf: url))
    }
}

actor EphemeralThemePreferencesRepository: ThemePreferencesRepository {
    private var record: ThemePreferencesRecord?

    init(record: ThemePreferencesRecord? = nil) {
        self.record = record
    }

    func loadThemePreferences() -> RecordLoadResult<ThemePreferencesRecord> {
        record.map { .loaded($0, migration: .current) } ?? .missing
    }

    func saveThemePreferences(
        _ proposed: ThemePreferencesRecord,
        expectedRevision: RecordRevision?
    ) throws -> ThemePreferencesRecord {
        guard record?.revision == expectedRevision else {
            throw PersistenceError.revisionConflict(
                expected: expectedRevision,
                actual: record?.revision
            )
        }
        let committed = proposed.replacingRevision(.init(rawValue: (record?.revision.rawValue ?? 0) + 1))
        try committed.validated()
        record = committed
        return committed
    }

    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) throws -> ThemePreferencesRecord {
        let committed = proposed.replacingRevision(.init(rawValue: 1))
        try committed.validated()
        record = committed
        return committed
    }
}
