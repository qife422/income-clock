import AppKit
import Combine
import Darwin

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var isPanelVisible = false
    @Published private(set) var panelPreferences = PanelRuntimePreferences()
    @Published private(set) var panelPreferenceError: PanelRuntimeError?
    @Published private(set) var isResettingPanelPlacement = false

    let businessStore: BusinessStore
    let loginItemController: LoginItemController
    let themeStore: ThemeStore
    let themeSoundCoordinator: ThemeSoundCoordinator
    private var businessMaintenanceTask: Task<Void, Never>?
    private let panelController: any PanelControlling
    private var hasStarted = false
    private var lastExternalFrontmostBundleIdentifier: String?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?

    init(
        businessStore: BusinessStore,
        panelController: any PanelControlling,
        themeStore: ThemeStore? = nil,
        loginItemService: any LoginItemServicing = UnavailableLoginItemService(),
        themeSoundPlayer: (any ThemeSoundPlaying)? = nil
    ) {
        self.businessStore = businessStore
        self.themeStore = themeStore ?? ThemeStore()
        themeSoundCoordinator = ThemeSoundCoordinator(businessStore: businessStore,
            themeStore: self.themeStore, player: themeSoundPlayer ?? LocalThemeSoundPlayer())
        loginItemController = LoginItemController(
            service: loginItemService,
            businessStore: businessStore
        )
        self.panelController = panelController
        let applicationBundleIdentifier = Bundle.main.bundleIdentifier
        if let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontmostBundleIdentifier != applicationBundleIdentifier {
            lastExternalFrontmostBundleIdentifier = frontmostBundleIdentifier
        }
        panelController.setVisibilityChangeHandler { [weak self] visible in
            self?.isPanelVisible = visible
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleIdentifier = runningApplication.bundleIdentifier,
                  bundleIdentifier != applicationBundleIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.lastExternalFrontmostBundleIdentifier = bundleIdentifier
            }
        }
    }

    convenience init(businessStore: BusinessStore) {
        let themeStore = ThemeStore()
        self.init(
            businessStore: businessStore,
            panelController: PanelController(businessStore: businessStore, themeStore: themeStore),
            themeStore: themeStore,
            loginItemService: UnavailableLoginItemService()
        )
    }

    convenience init(
        repository: any BusinessRecordRepository,
        panelPreferenceStore: any PanelPreferenceStoring = EphemeralPanelPreferenceStore(),
        nowProvider: any NowProvider,
        timeZoneIdentifier: String,
        notificationService: any NotificationServicing = UnavailableNotificationService(),
        loginItemService: any LoginItemServicing = UnavailableLoginItemService(),
        themePreferencesRepository: any ThemePreferencesRepository = EphemeralThemePreferencesRepository(),
        themeCatalog: any ThemeCatalogProviding = BundledThemeCatalog(),
        themeRepository: any ThemeRepositoryProviding = UnavailableThemeRepository()
    ) throws {
        let coordinatedRepository = PanelSettingsCoordinator(
            repository: repository,
            preferenceStore: panelPreferenceStore
        )
        let businessStore = try BusinessStore(
            repository: coordinatedRepository,
            nowProvider: nowProvider,
            timeZoneIdentifier: timeZoneIdentifier,
            notificationService: notificationService
        )
        let themeStore = ThemeStore(
            repository: themePreferencesRepository,
            catalog: themeCatalog,
            themeRepository: themeRepository
        )
        self.init(
            businessStore: businessStore,
            panelController: PanelController(
                businessStore: businessStore,
                themeStore: themeStore,
                repository: coordinatedRepository
            ),
            themeStore: themeStore,
            loginItemService: loginItemService
        )
    }

    convenience init(
        repository: any BusinessRecordRepository,
        panelPreferenceStore: any PanelPreferenceStoring = EphemeralPanelPreferenceStore(),
        nowProvider: any NowProvider,
        timeZoneIdentifierProvider: any TimeZoneIdentifierProvider,
        notificationService: any NotificationServicing = UnavailableNotificationService(),
        loginItemService: any LoginItemServicing = UnavailableLoginItemService(),
        themePreferencesRepository: any ThemePreferencesRepository = EphemeralThemePreferencesRepository(),
        themeCatalog: any ThemeCatalogProviding = BundledThemeCatalog(),
        themeRepository: any ThemeRepositoryProviding = UnavailableThemeRepository()
    ) throws {
        let coordinatedRepository = PanelSettingsCoordinator(
            repository: repository,
            preferenceStore: panelPreferenceStore
        )
        let businessStore = try BusinessStore(
            repository: coordinatedRepository,
            nowProvider: nowProvider,
            timeZoneIdentifierProvider: timeZoneIdentifierProvider,
            notificationService: notificationService
        )
        let themeStore = ThemeStore(
            repository: themePreferencesRepository,
            catalog: themeCatalog,
            themeRepository: themeRepository
        )
        self.init(
            businessStore: businessStore,
            panelController: PanelController(
                businessStore: businessStore,
                themeStore: themeStore,
                repository: coordinatedRepository
            ),
            themeStore: themeStore,
            loginItemService: loginItemService
        )
    }

    static func production() throws -> AppEnvironment {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw PersistenceError.invalidProposedRecord
        }
        let paths = try RecordRepositoryPaths.applicationSupport(
            bundleIdentifier: bundleIdentifier
        )
        #if DEBUG
        let notificationService: any NotificationServicing = FakeNotificationService()
        let loginItemService: any LoginItemServicing = FakeLoginItemService()
        #else
        let notificationService: any NotificationServicing = UNUserNotificationCenterService()
        let loginItemService: any LoginItemServicing = SMAppServiceLoginItemService()
        #endif
        let repository = RecordRepositoryActor(paths: paths)
        return try AppEnvironment(
            repository: repository,
            panelPreferenceStore: UserDefaultsPanelPreferenceStore(),
            nowProvider: SystemClock(),
            timeZoneIdentifierProvider: SystemTimeZoneIdentifierProvider(),
            notificationService: notificationService,
            loginItemService: loginItemService,
            themePreferencesRepository: repository,
            themeRepository: ThemeRepositoryActor(applicationSupportRoot: paths.root)
        )
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await themeStore.restore()
        await themeStore.reconcileAppearance(systemIsDark:
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                await self?.themeStore.reconcileAppearance(systemIsDark:
                    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            }
        }
        await businessStore.restore()
        await loginItemController.refresh()
        themeSoundCoordinator.armAfterRestoration()
        // Business time still reaches its stop boundary while the panel is hidden.
        // This maintenance pulse is not a renderer and never accumulates earnings.
        businessMaintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let store = self?.businessStore else { return }
                await store.refresh()
            }
        }
        let shouldShow = await panelController.restore()
        panelPreferences = panelController.runtimePreferences()
        if shouldShow {
            panelController.show(persist: false, focus: false)
        } else {
            panelController.hide(persist: false)
        }
    }

    func restoreBusinessState() async {
        await businessStore.restore()
    }

    func togglePanel(focus: Bool = false) {
        isPanelVisible ? hidePanel() : showPanel(focus: focus)
    }

    func togglePanelFromMenuBar() {
        togglePanel(focus: false)
        let applicationToRestore = lastExternalFrontmostBundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        DispatchQueue.main.async {
            if applicationToRestore?.activate(options: [.activateIgnoringOtherApps]) != true {
                NSApp.deactivate()
            }
        }
    }

    func togglePanelFromShortcut() {
        togglePanel(focus: true)
    }

    func showPanel(focus: Bool = false) {
        panelController.show(persist: true, focus: focus)
    }

    func hidePanel() {
        panelController.hide(persist: true)
    }

    func setAlwaysOnTop(_ value: Bool) {
        updatePanelPreference(\.alwaysOnTop, value: value) { controller in
            await controller.setAlwaysOnTop(value)
        }
    }

    func setLockPanelPosition(_ value: Bool) {
        updatePanelPreference(\.lockPanelPosition, value: value) { controller in
            await controller.setLockPanelPosition(value)
        }
    }

    func setHideInFullScreen(_ value: Bool) {
        updatePanelPreference(\.hideInFullScreen, value: value) { controller in
            await controller.setHideInFullScreen(value)
        }
    }

    func resetPanelPlacement() {
        guard !isResettingPanelPlacement else { return }
        isResettingPanelPlacement = true
        Task { @MainActor in
            defer { isResettingPanelPlacement = false }
            panelPreferenceError = await panelController.resetToDefaultPlacement()
                ? nil : .persistence(.atomicWriteFailed)
        }
    }

    func terminateApplication() {
        NSApp.terminate(nil)
    }

    private func updatePanelPreference(
        _ keyPath: WritableKeyPath<PanelRuntimePreferences, Bool>,
        value: Bool,
        commit: @escaping @MainActor (any PanelControlling) async -> Bool
    ) {
        let previous = panelPreferences[keyPath: keyPath]
        panelPreferences[keyPath: keyPath] = value
        panelPreferenceError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await commit(self.panelController) {
                self.panelPreferences = self.panelController.runtimePreferences()
            } else {
                self.panelPreferences[keyPath: keyPath] = previous
                self.panelPreferenceError = .persistence(.atomicWriteFailed)
            }
        }
    }

    deinit {
        businessMaintenanceTask?.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }
}

/// Dispatch the system-provided Settings menu item, preserving SwiftUI's Settings scene.
/// The undocumented showSettingsWindow: responder action is not present on newer macOS.
@MainActor
enum NativeSettingsWindowRouter {
    @discardableResult
    static func open() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        func dispatch(in menu: NSMenu) -> Bool {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == ",",
                   item.keyEquivalentModifierMask.contains(.command),
                   item.action != nil {
                    NSApp.activate(ignoringOtherApps: true)
                    menu.performActionForItem(at: index)
                    return true
                }
                if let submenu = item.submenu, dispatch(in: submenu) { return true }
            }
            return false
        }
        return dispatch(in: mainMenu)
    }
}

enum ThemeSoundEvent: String, Equatable, Sendable {
    case clockInSuccess
    case autoStop
    case settlementComplete
}

enum ThemeSoundFailure: Error, Equatable, Sendable {
    case unavailableResource
    case unsafeResource
    case playbackFailed
}

struct ThemeSoundDiagnostic: Equatable, Sendable {
    let event: ThemeSoundEvent
    let failure: ThemeSoundFailure
}

@MainActor
protocol ThemeSoundPlaying: AnyObject {
    func play(_ data: Data, completion: @escaping @MainActor (Bool) -> Void) throws
}

/// Only receives bytes opened under a validated theme root; it never resolves URLs.
@MainActor
final class LocalThemeSoundPlayer: NSObject, ThemeSoundPlaying, NSSoundDelegate {
    private var activeSounds: [ObjectIdentifier: (NSSound, @MainActor (Bool) -> Void)] = [:]

    func play(_ data: Data, completion: @escaping @MainActor (Bool) -> Void) throws {
        guard let sound = NSSound(data: data) else { throw ThemeSoundFailure.playbackFailed }
        sound.delegate = self
        activeSounds[ObjectIdentifier(sound)] = (sound, completion)
        guard sound.play() else {
            activeSounds.removeValue(forKey: ObjectIdentifier(sound))
            throw ThemeSoundFailure.playbackFailed
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        activeSounds.removeValue(forKey: ObjectIdentifier(sound))?.1(finished)
    }
}

@MainActor
final class ThemeSoundCoordinator: ObservableObject {
    @Published private(set) var diagnostics: [ThemeSoundDiagnostic] = []
    private let businessStore: BusinessStore
    private let themeStore: ThemeStore
    private let player: any ThemeSoundPlaying
    private let systemIsDark: @MainActor () -> Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var previousState: BusinessViewState?
    private var seenEvents: [String] = []
    private var isArmed = false

    init(businessStore: BusinessStore, themeStore: ThemeStore, player: any ThemeSoundPlaying,
         systemIsDark: @escaping @MainActor () -> Bool = {
             NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
         }) {
        self.businessStore = businessStore
        self.themeStore = themeStore
        self.player = player
        self.systemIsDark = systemIsDark
        businessStore.$viewState.sink { [weak self] state in self?.observe(state) }.store(in: &subscriptions)
        businessStore.$feedback.sink { [weak self] feedback in self?.observe(feedback) }.store(in: &subscriptions)
    }

    /// Restoration establishes a baseline; launching never replays historical cues.
    func armAfterRestoration() {
        previousState = businessStore.viewState
        isArmed = true
    }

    private func observe(_ state: BusinessViewState?) {
        let previous = previousState
        previousState = state
        guard isArmed, !businessStore.isRestoring, let state, let previous,
              state.state == .awaitingClockOut,
              previous.state == .earning || previous.state == .clockedInWaiting,
              state.todayDateKey == previous.todayDateKey,
              state.clockInAt == previous.clockInAt else { return }
        emit(.autoStop, state: state)
    }

    private func observe(_ feedback: BusinessFeedback?) {
        guard isArmed, !businessStore.isRestoring, let state = previousState else { return }
        switch feedback {
        case .clockInSucceeded: emit(.clockInSuccess, state: state)
        case .clockOutSucceeded: emit(.settlementComplete, state: state)
        default: break
        }
    }

    private func emit(_ event: ThemeSoundEvent, state: BusinessViewState) {
        let key = "\(state.todayDateKey)|\(state.clockInAt?.rawValue ?? 0)|\(event.rawValue)"
        guard !seenEvents.contains(key) else { return }
        // Consume even while disabled, so enabling sounds cannot replay an old event.
        seenEvents.append(key)
        if seenEvents.count > 64 { seenEvents.removeFirst(seenEvents.count - 64) }
        let runtimeTheme = themeStore.effectiveTheme(systemIsDark: systemIsDark())
        guard themeStore.soundsEnabled,
              let relativePath = runtimeTheme.sounds[event.rawValue] else { return }
        do {
            let data = try Self.readVerifiedLocalSound(theme: runtimeTheme, relativePath: relativePath)
            try player.play(data) { [weak self] finished in
                if !finished { self?.record(event, failure: .playbackFailed) }
            }
        } catch let failure as ThemeSoundFailure {
            record(event, failure: failure)
        } catch {
            record(event, failure: .playbackFailed)
        }
    }

    private func record(_ event: ThemeSoundEvent, failure: ThemeSoundFailure) {
        diagnostics.append(.init(event: event, failure: failure))
        if diagnostics.count > 64 { diagnostics.removeFirst(diagnostics.count - 64) }
    }

    /// Descriptor-relative no-follow reads prevent a replaced file/link from opening
    /// arbitrary external paths. Installation has already fully decoded this media.
    static func readVerifiedLocalSound(theme: ValidatedTheme, relativePath: String) throws -> Data {
        guard case let .installed(root) = theme.source,
              theme.sounds.values.contains(relativePath),
              !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            throw ThemeSoundFailure.unsafeResource
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }),
              ["wav", "m4a", "aiff"].contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) else {
            throw ThemeSoundFailure.unsafeResource
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw ThemeSoundFailure.unavailableResource }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw ThemeSoundFailure.unsafeResource }
            close(directory)
            directory = next
        }
        // A replaced FIFO must not block before fstat can reject its file type.
        let descriptor = openat(directory, components.last!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ThemeSoundFailure.unavailableResource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let maximum = 10 * 1_024 * 1_024
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= maximum else {
            throw ThemeSoundFailure.unsafeResource
        }
        guard let data = try handle.read(upToCount: maximum + 1),
              data.count == metadata.st_size, data.count <= maximum else {
            throw ThemeSoundFailure.unavailableResource
        }
        return data
    }
}
