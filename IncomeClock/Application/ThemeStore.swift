import Combine
import Foundation

enum ThemeStoreError: Error, Equatable, Sendable {
    case preferencesDamaged
    case selectedThemeUnavailable(String)
    case builtInValidationFailed
    case persistenceFailed
}

struct ThemeViewState: Equatable, Sendable {
    let themes: [ValidatedTheme]
    let selectedTheme: ValidatedTheme
    let preferredAppearance: PreferredThemeAppearance
    let soundsEnabled: Bool
    let isProcessing: Bool
    let error: ThemeStoreError?
    let fallbackNotice: String?

    static let safeDefault = ThemeViewState(
        themes: [.warmIslandFallback],
        selectedTheme: .warmIslandFallback,
        preferredAppearance: .system,
        soundsEnabled: false,
        isProcessing: false,
        error: nil,
        fallbackNotice: nil
    )
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var viewState: ThemeViewState = .safeDefault
    @Published private(set) var importProgress: ThemeImportProgress?
    @Published private(set) var importCandidate: ThemeImportCandidate?
    @Published private(set) var importError: ThemeImportError?
    @Published private(set) var importMessage: String?
    @Published private(set) var lastInstalledThemeID: String?
    @Published private(set) var disabledInstalledThemes: [DisabledInstalledTheme] = []

    private let preferencesRepository: any ThemePreferencesRepository
    private let themeRepository: any ThemeRepositoryProviding
    private let catalog: any ThemeCatalogProviding
    private let nowMilliseconds: @Sendable () -> Int64
    private let validationTask = ThemeValidationTask()
    private var revision: RecordRevision?
    private var damagedPreferences = false
    private var operationGeneration: UInt64 = 0
    private var systemIsDark = false

    init(
        repository: any ThemePreferencesRepository,
        catalog: any ThemeCatalogProviding = BundledThemeCatalog(),
        themeRepository: any ThemeRepositoryProviding = UnavailableThemeRepository(),
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        preferencesRepository = repository
        self.themeRepository = themeRepository
        self.catalog = catalog
        self.nowMilliseconds = nowMilliseconds
    }

    convenience init() {
        self.init(repository: EphemeralThemePreferencesRepository())
    }

    var selectedTheme: ValidatedTheme { viewState.selectedTheme }
    var preferredAppearance: PreferredThemeAppearance { viewState.preferredAppearance }
    var soundsEnabled: Bool { viewState.soundsEnabled }

    func effectiveTheme(systemIsDark: Bool) -> ValidatedTheme {
        ThemeAppearanceResolver.effectiveTheme(theme: selectedTheme,
            preferred: preferredAppearance, systemIsDark: systemIsDark)
    }

    func appearanceFallbackNotice(systemIsDark: Bool) -> String? {
        guard effectiveTheme(systemIsDark: systemIsDark).id != selectedTheme.id else { return nil }
        return "当前皮肤不支持目标外观，已整体回退到 A「暖屿」。"
    }

    /// Call after restoration and whenever the system appearance changes. A
    /// healthy preference records the same A selection used by all renderers.
    func reconcileAppearance(systemIsDark: Bool) async {
        self.systemIsDark = systemIsDark
        guard !viewState.isProcessing,
              effectiveTheme(systemIsDark: systemIsDark).id != selectedTheme.id else { return }
        publish(themes: viewState.themes, selected: defaultTheme(in: viewState.themes),
            appearance: preferredAppearance, sounds: soundsEnabled, error: nil,
            notice: "当前皮肤不支持目标外观，已整体回退到 A「暖屿」。")
        // Damaged preferences are preserved until an explicit user save.
        guard !damagedPreferences else { return }
        await persistCurrentSelection(isAutomaticFallback: true)
    }

    func restore() async {
        let snapshot = await catalog.loadBuiltInThemes()
        let installed = await themeRepository.loadInstalledThemes()
        disabledInstalledThemes = installed.disabledThemes
        let themes = normalizedThemes(snapshot.themes + installed.themes)
        let catalogNotice = snapshot.diagnostics.isEmpty
            ? nil
            : "部分内置皮肤未通过验证，已使用安全默认外观。"

        switch await preferencesRepository.loadThemePreferences() {
        case .missing:
            revision = nil
            damagedPreferences = false
            publish(
                themes: themes,
                selected: defaultTheme(in: themes),
                appearance: .system,
                sounds: false,
                error: snapshot.diagnostics.isEmpty ? nil : .builtInValidationFailed,
                notice: catalogNotice
            )
        case let .loaded(record, _):
            revision = record.revision
            damagedPreferences = false
            guard let selected = themes.first(where: { $0.id == record.selectedThemeId }) else {
                let unavailable = record.selectedThemeId
                publish(
                    themes: themes,
                    selected: defaultTheme(in: themes),
                    appearance: .system,
                    sounds: false,
                    error: .selectedThemeUnavailable(unavailable),
                    notice: "之前选择的皮肤不可用，已回退到 A「暖屿」。"
                )
                await persistCurrentSelection(isAutomaticFallback: true)
                return
            }
            publish(
                themes: themes,
                selected: selected,
                appearance: record.preferredThemeAppearance,
                sounds: record.themeSoundsEnabled,
                error: snapshot.diagnostics.isEmpty ? nil : .builtInValidationFailed,
                notice: catalogNotice
            )
        case .damaged:
            revision = nil
            damagedPreferences = true
            publish(
                themes: themes,
                selected: defaultTheme(in: themes),
                appearance: .system,
                sounds: false,
                error: .preferencesDamaged,
                notice: "皮肤偏好无法读取，原文件已保留，当前使用 A「暖屿」安全默认值。"
            )
        }
    }

    func selectTheme(id: String) async {
        guard !viewState.isProcessing,
              let target = viewState.themes.first(where: { $0.id == id }) else {
            if viewState.themes.first(where: { $0.id == id }) == nil {
                setError(.selectedThemeUnavailable(id), notice: "所选皮肤未通过验证，当前皮肤未改变。")
            }
            return
        }
        guard target.id != viewState.selectedTheme.id else { return }
        await commit(
            selected: target,
            appearance: viewState.preferredAppearance,
            sounds: viewState.soundsEnabled
        )
    }

    func setAppearance(_ appearance: PreferredThemeAppearance) async {
        guard !viewState.isProcessing, appearance != viewState.preferredAppearance else { return }
        await commit(
            selected: viewState.selectedTheme,
            appearance: appearance,
            sounds: viewState.soundsEnabled
        )
    }

    func setSoundsEnabled(_ enabled: Bool) async {
        guard !viewState.isProcessing, enabled != viewState.soundsEnabled else { return }
        await commit(
            selected: viewState.selectedTheme,
            appearance: viewState.preferredAppearance,
            sounds: enabled
        )
    }

    func dismissImportError() { importError = nil }
    func dismissImportMessage() { importMessage = nil; lastInstalledThemeID = nil }

    func beginImport(from sourceURL: URL) async {
        guard !validationTask.isRunning, importProgress == nil else { return }
        if let previous = importCandidate { await themeRepository.discard(previous) }
        importCandidate = nil
        importError = nil
        importMessage = nil
        do {
            let candidate = try await validationTask.start(
                repository: themeRepository,
                sourceURL: sourceURL
            ) { [weak self] update in
                self?.importProgress = update
            }
            importProgress = nil
            importCandidate = candidate
        } catch let error as ThemeImportError {
            importProgress = nil
            importError = error == .cancelled ? nil : error
        } catch {
            importProgress = nil
            importError = .stagingFailed
        }
    }

    func cancelImport() {
        guard importProgress?.canCancel == true else { return }
        validationTask.cancel()
    }

    func dismissImportCandidate() async {
        guard importProgress?.stage != .committing else { return }
        guard let candidate = importCandidate else { return }
        importCandidate = nil
        await themeRepository.discard(candidate)
    }

    func installImportCandidate() async {
        guard let candidate = importCandidate, importProgress == nil else { return }
        importError = nil
        importProgress = .init(
            fileName: candidate.manifest.name,
            stage: .committing,
            fractionCompleted: 1,
            canCancel: false
        )
        do {
            let installed = try await themeRepository.install(candidate)
            let wasSelected = viewState.selectedTheme.id == installed.id
            let themes = normalizedThemes(viewState.themes.filter { $0.id != installed.id } + [installed])
            viewState = ThemeViewState(
                themes: themes,
                selectedTheme: wasSelected ? installed : viewState.selectedTheme,
                preferredAppearance: viewState.preferredAppearance,
                soundsEnabled: viewState.soundsEnabled,
                isProcessing: viewState.isProcessing,
                error: viewState.error,
                fallbackNotice: viewState.fallbackNotice
            )
            importCandidate = nil
            importProgress = nil
            lastInstalledThemeID = installed.id
            importMessage = "皮肤“\(installed.name)”已安全安装。"
            await reconcileAppearance(systemIsDark: systemIsDark)
        } catch let error as ThemeImportError {
            importProgress = nil
            importError = error
        } catch {
            importProgress = nil
            importError = .installFailed
        }
    }

    func useImportedTheme() async {
        guard let id = lastInstalledThemeID else { return }
        await selectTheme(id: id)
    }

    func restoreDefaultTheme() async {
        await selectTheme(id: BuiltinThemeID.warmIsland)
    }

    func deleteTheme(id: String) async {
        guard !viewState.isProcessing,
              let target = viewState.themes.first(where: { $0.id == id }),
              !target.isBuiltIn else {
            importError = .deleteFailed
            return
        }
        importError = nil
        let wasSelected = viewState.selectedTheme.id == id
        if wasSelected {
            let fallback = defaultTheme(in: viewState.themes)
            guard await commit(
                selected: fallback,
                appearance: viewState.preferredAppearance,
                sounds: viewState.soundsEnabled
            ) else {
                importError = .preferencesFailed
                return
            }
        }
        do {
            try await themeRepository.deleteTheme(id: id)
            let remaining = normalizedThemes(viewState.themes.filter { $0.id != id })
            publish(
                themes: remaining,
                selected: viewState.selectedTheme,
                appearance: viewState.preferredAppearance,
                sounds: viewState.soundsEnabled,
                error: nil,
                notice: nil
            )
            importMessage = "皮肤已删除。"
        } catch {
            // If this was the current theme, the already-committed default selection is
            // intentionally retained; leaving the undeleted files is consistent and safe.
            importError = .deleteFailed
        }
    }

    func deleteDisabledTheme(id: String) async {
        guard disabledInstalledThemes.contains(where: { $0.id == id }) else { return }
        do {
            try await themeRepository.deleteTheme(id: id)
            disabledInstalledThemes.removeAll { $0.id == id }
            importMessage = "已删除禁用皮肤。"
        } catch {
            importError = .deleteFailed
        }
    }

    private func commit(
        selected: ValidatedTheme,
        appearance: PreferredThemeAppearance,
        sounds: Bool
    ) async -> Bool {
        let effective = ThemeAppearanceResolver.effectiveTheme(theme: selected,
            preferred: appearance, systemIsDark: systemIsDark)
        let fallsBack = effective.id != selected.id
        operationGeneration &+= 1
        let generation = operationGeneration
        let previous = viewState
        viewState = ThemeViewState(
            themes: previous.themes,
            selectedTheme: previous.selectedTheme,
            preferredAppearance: previous.preferredAppearance,
            soundsEnabled: previous.soundsEnabled,
            isProcessing: true,
            error: nil,
            fallbackNotice: previous.fallbackNotice
        )
        let proposed = ThemePreferencesRecord(
            schemaVersion: ThemePreferencesRecord.currentSchemaVersion,
            revision: .proposed,
            selectedThemeId: effective.id,
            preferredThemeAppearance: appearance,
            themeSoundsEnabled: sounds,
            updatedAtMs: nowMilliseconds()
        )
        do {
            let committed: ThemePreferencesRecord
            if damagedPreferences {
                committed = try await preferencesRepository.recoverThemePreferences(proposed)
            } else {
                committed = try await preferencesRepository.saveThemePreferences(
                    proposed,
                    expectedRevision: revision
                )
            }
            guard generation == operationGeneration else { return false }
            revision = committed.revision
            damagedPreferences = false
            publish(
                themes: viewState.themes,
                selected: viewState.themes.first(where: { $0.id == effective.id }) ?? effective,
                appearance: appearance,
                sounds: sounds,
                error: nil,
                notice: fallsBack ? "当前皮肤不支持目标外观，已整体回退到 A「暖屿」。" : nil
            )
            await reconcileAppearance(systemIsDark: systemIsDark)
            return true
        } catch {
            guard generation == operationGeneration else { return false }
            viewState = ThemeViewState(
                themes: viewState.themes,
                selectedTheme: viewState.themes.first(where: { $0.id == previous.selectedTheme.id }) ?? previous.selectedTheme,
                preferredAppearance: previous.preferredAppearance,
                soundsEnabled: previous.soundsEnabled,
                isProcessing: false,
                error: .persistenceFailed,
                fallbackNotice: "皮肤偏好未保存，已保留原有外观和业务状态。"
            )
            await reconcileAppearance(systemIsDark: systemIsDark)
            return false
        }
    }

    private func persistCurrentSelection(isAutomaticFallback: Bool) async {
        let fallbackState = viewState
        viewState = ThemeViewState(themes: fallbackState.themes, selectedTheme: fallbackState.selectedTheme,
            preferredAppearance: fallbackState.preferredAppearance, soundsEnabled: fallbackState.soundsEnabled,
            isProcessing: true, error: fallbackState.error, fallbackNotice: fallbackState.fallbackNotice)
        let selected = viewState.selectedTheme
        let proposed = ThemePreferencesRecord(
            schemaVersion: ThemePreferencesRecord.currentSchemaVersion,
            revision: .proposed,
            selectedThemeId: selected.id,
            preferredThemeAppearance: viewState.preferredAppearance,
            themeSoundsEnabled: viewState.soundsEnabled,
            updatedAtMs: nowMilliseconds()
        )
        do {
            let committed = try await preferencesRepository.saveThemePreferences(
                proposed,
                expectedRevision: revision
            )
            revision = committed.revision
            publish(themes: viewState.themes, selected: fallbackState.selectedTheme,
                appearance: fallbackState.preferredAppearance, sounds: fallbackState.soundsEnabled,
                error: fallbackState.error, notice: fallbackState.fallbackNotice)
        } catch {
            if isAutomaticFallback {
                setError(
                    .persistenceFailed,
                    notice: "已在运行时回退到 A「暖屿」，但回退偏好未能保存。"
                )
            }
        }
    }

    private func normalizedThemes(_ themes: [ValidatedTheme]) -> [ValidatedTheme] {
        var unique = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0) })
        unique[BuiltinThemeID.warmIsland] = unique[BuiltinThemeID.warmIsland] ?? .warmIslandFallback
        return unique.values.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func defaultTheme(in themes: [ValidatedTheme]) -> ValidatedTheme {
        themes.first(where: { $0.id == BuiltinThemeID.warmIsland }) ?? .warmIslandFallback
    }

    private func publish(
        themes: [ValidatedTheme],
        selected: ValidatedTheme,
        appearance: PreferredThemeAppearance,
        sounds: Bool,
        error: ThemeStoreError?,
        notice: String?
    ) {
        viewState = ThemeViewState(
            themes: themes,
            selectedTheme: selected,
            preferredAppearance: appearance,
            soundsEnabled: sounds,
            isProcessing: false,
            error: error,
            fallbackNotice: notice
        )
    }

    private func setError(_ error: ThemeStoreError, notice: String) {
        viewState = ThemeViewState(
            themes: viewState.themes,
            selectedTheme: viewState.selectedTheme,
            preferredAppearance: viewState.preferredAppearance,
            soundsEnabled: viewState.soundsEnabled,
            isProcessing: false,
            error: error,
            fallbackNotice: notice
        )
    }
}
