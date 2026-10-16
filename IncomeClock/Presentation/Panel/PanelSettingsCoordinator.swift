import Foundation

struct PendingPanelPreferences: Codable, Equatable, Sendable {
    var panelVisible: Bool?
    var panelPlacement: PanelPlacementRecord?
    var alwaysOnTop: Bool?
    var lockPanelPosition: Bool?
    var hideInFullScreen: Bool?

    var isEmpty: Bool {
        panelVisible == nil && panelPlacement == nil && alwaysOnTop == nil
            && lockPanelPosition == nil && hideInFullScreen == nil
    }
}

enum PanelSettingsMutation: Sendable {
    case visibility(Bool)
    case placement(PanelPlacementRecord)
    case alwaysOnTop(Bool)
    case lockPanelPosition(Bool)
    case hideInFullScreen(Bool)
}

enum PanelPersistenceLoadResult: Equatable, Sendable {
    case missing
    case pending(PendingPanelPreferences)
    case loaded(SettingsRecord)
    case damaged(DamagedRecordResult)
}

enum PanelPersistenceCommitResult: Equatable, Sendable {
    case pending(PendingPanelPreferences)
    case committed(SettingsRecord)
    case damaged(DamagedRecordResult)
}

protocol PanelPreferenceStoring: Sendable {
    func load() async -> PendingPanelPreferences?
    func save(_ preferences: PendingPanelPreferences) async
    func clear() async
}

protocol PanelSettingsPersisting: Sendable {
    func loadPanelPersistence() async -> PanelPersistenceLoadResult
    func persistPanelMutation(
        _ mutation: PanelSettingsMutation,
        updatedAtMs: Int64
    ) async throws -> PanelPersistenceCommitResult
}

actor EphemeralPanelPreferenceStore: PanelPreferenceStoring {
    private var preferences: PendingPanelPreferences?

    func load() -> PendingPanelPreferences? {
        preferences
    }

    func save(_ preferences: PendingPanelPreferences) {
        self.preferences = preferences.isEmpty ? nil : preferences
    }

    func clear() {
        preferences = nil
    }
}

actor UserDefaultsPanelPreferenceStore: PanelPreferenceStoring {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "pendingPanelPreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PendingPanelPreferences? {
        guard let data = defaults.data(forKey: key),
              let preferences = try? decoder.decode(PendingPanelPreferences.self, from: data),
              (try? preferences.panelPlacement?.validated()) != nil || preferences.panelPlacement == nil,
              !preferences.isEmpty else {
            return nil
        }
        return preferences
    }

    func save(_ preferences: PendingPanelPreferences) {
        guard !preferences.isEmpty,
              let data = try? encoder.encode(preferences) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

actor PanelSettingsCoordinator: BusinessRecordRepository, PanelSettingsPersisting {
    private let repository: any BusinessRecordRepository
    private let preferenceStore: any PanelPreferenceStoring
    private var settingsMutationIsActive = false
    private var settingsMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        repository: any BusinessRecordRepository,
        preferenceStore: any PanelPreferenceStoring
    ) {
        self.repository = repository
        self.preferenceStore = preferenceStore
    }

    func loadPanelPersistence() async -> PanelPersistenceLoadResult {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }

        switch await repository.loadSettings() {
        case .missing:
            if let pending = await preferenceStore.load() {
                return .pending(pending)
            }
            return .missing
        case let .loaded(settings, _):
            return .loaded(settings)
        case let .damaged(damage):
            return .damaged(damage)
        }
    }

    func persistPanelMutation(
        _ mutation: PanelSettingsMutation,
        updatedAtMs: Int64
    ) async throws -> PanelPersistenceCommitResult {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }

        for attempt in 0...1 {
            switch await repository.loadSettings() {
            case .missing:
                var pending = await preferenceStore.load() ?? PendingPanelPreferences()
                pending.apply(mutation)
                await preferenceStore.save(pending)
                return .pending(pending)
            case let .damaged(damage):
                return .damaged(damage)
            case let .loaded(current, _):
                let proposed = current.applyingPanelMutation(
                    mutation,
                    updatedAtMs: updatedAtMs
                )
                do {
                    let committed = try await repository.saveSettings(
                        proposed,
                        expectedRevision: current.revision
                    )
                    await preferenceStore.clear()
                    return .committed(committed)
                } catch let error as PersistenceError {
                    if case .revisionConflict = error, attempt == 0 {
                        continue
                    }
                    throw error
                }
            }
        }
        throw PersistenceError.atomicWriteFailed
    }

    func loadSettings() async -> RecordLoadResult<SettingsRecord> {
        await repository.loadSettings()
    }

    func loadSettingsForBusiness() async -> SettingsTypedLoadResult {
        await repository.loadSettingsForBusiness()
    }

    func loadToday() async -> RecordLoadResult<TodayRecord> {
        await repository.loadToday()
    }

    func loadTodayForBusiness() async -> TodayTypedLoadResult {
        await repository.loadTodayForBusiness()
    }

    func saveSettings(
        _ proposed: SettingsRecord,
        expectedRevision: RecordRevision?
    ) async throws -> SettingsRecord {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }

        let pending = expectedRevision == nil ? await preferenceStore.load() : nil
        let merged = proposed.merging(pending)
        let committed = try await repository.saveSettings(
            merged,
            expectedRevision: expectedRevision
        )
        if expectedRevision == nil {
            await preferenceStore.clear()
        }
        return committed
    }

    func saveToday(
        _ proposed: TodayRecord,
        expectedRevision: RecordRevision?
    ) async throws -> TodayRecord {
        try await repository.saveToday(proposed, expectedRevision: expectedRevision)
    }

    func recoverSettings(_ proposed: SettingsRecord) async throws -> SettingsRecord {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }

        return try await repository.recoverSettings(proposed)
    }

    func commitSaveSettings(_ intent: SettingsCommitIntent) async throws -> SettingsCommitResult {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }

        let result = try await repository.commitSaveSettings(intent)
        await preferenceStore.clear()
        return result
    }

    func commitStartToday(_ intent: StartTodayCommitIntent) async throws -> StartTodayCommitResult {
        try await repository.commitStartToday(intent)
    }

    func resetDamagedSettingsToMissing(expectedToken: SettingsRecordToken) async throws {
        await acquireSettingsMutationBoundary()
        defer { releaseSettingsMutationBoundary() }
        try await repository.resetDamagedSettingsToMissing(expectedToken: expectedToken)
    }

    func resetToday() async throws {
        try await repository.resetToday()
    }

    func resetToday(expectedToken: TodayRecordToken) async throws {
        try await repository.resetToday(expectedToken: expectedToken)
    }

    private func acquireSettingsMutationBoundary() async {
        guard settingsMutationIsActive else {
            settingsMutationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            settingsMutationWaiters.append(continuation)
        }
    }

    private func releaseSettingsMutationBoundary() {
        guard !settingsMutationWaiters.isEmpty else {
            settingsMutationIsActive = false
            return
        }
        settingsMutationWaiters.removeFirst().resume()
    }
}

private extension PendingPanelPreferences {
    mutating func apply(_ mutation: PanelSettingsMutation) {
        switch mutation {
        case let .visibility(visible):
            panelVisible = visible
        case let .placement(placement):
            panelPlacement = placement
        case let .alwaysOnTop(value):
            alwaysOnTop = value
        case let .lockPanelPosition(value):
            lockPanelPosition = value
        case let .hideInFullScreen(value):
            hideInFullScreen = value
        }
    }
}

private extension SettingsRecord {
    func merging(_ pending: PendingPanelPreferences?) -> SettingsRecord {
        guard let pending else { return self }
        return SettingsRecord(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            dailyWageCents: dailyWageCents,
            workStartMinuteOfDay: workStartMinuteOfDay,
            workEndMinuteOfDay: workEndMinuteOfDay,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: pending.alwaysOnTop ?? alwaysOnTop,
            lockPanelPosition: pending.lockPanelPosition ?? lockPanelPosition,
            hideInFullScreen: pending.hideInFullScreen ?? hideInFullScreen,
            launchAtLogin: launchAtLogin,
            panelVisible: pending.panelVisible ?? panelVisible,
            panelPlacement: pending.panelPlacement ?? panelPlacement,
            updatedAtMs: updatedAtMs
        )
    }

    func applyingPanelMutation(
        _ mutation: PanelSettingsMutation,
        updatedAtMs: Int64
    ) -> SettingsRecord {
        let visible: Bool
        let placement: PanelPlacementRecord?
        switch mutation {
        case let .visibility(newValue):
            visible = newValue
            placement = panelPlacement
        case let .placement(newValue):
            visible = panelVisible
            placement = newValue
        case .alwaysOnTop, .lockPanelPosition, .hideInFullScreen:
            visible = panelVisible
            placement = panelPlacement
        }
        let nextAlwaysOnTop: Bool
        let nextLockPanelPosition: Bool
        let nextHideInFullScreen: Bool
        if case let .alwaysOnTop(value) = mutation { nextAlwaysOnTop = value } else { nextAlwaysOnTop = alwaysOnTop }
        if case let .lockPanelPosition(value) = mutation { nextLockPanelPosition = value } else { nextLockPanelPosition = lockPanelPosition }
        if case let .hideInFullScreen(value) = mutation { nextHideInFullScreen = value } else { nextHideInFullScreen = hideInFullScreen }
        return SettingsRecord(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            dailyWageCents: dailyWageCents,
            workStartMinuteOfDay: workStartMinuteOfDay,
            workEndMinuteOfDay: workEndMinuteOfDay,
            notificationsEnabled: notificationsEnabled,
            alwaysOnTop: nextAlwaysOnTop,
            lockPanelPosition: nextLockPanelPosition,
            hideInFullScreen: nextHideInFullScreen,
            launchAtLogin: launchAtLogin,
            panelVisible: visible,
            panelPlacement: placement,
            updatedAtMs: updatedAtMs
        )
    }
}
