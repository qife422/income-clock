import AppKit
import SwiftUI

extension Notification.Name {
    static let incomePanelInitialKeyboardFocus = Notification.Name(
        "IncomeClock.Panel.InitialKeyboardFocus"
    )
    static let incomePanelAdvanceKeyboardFocus = Notification.Name(
        "IncomeClock.Panel.AdvanceKeyboardFocus"
    )
    static let incomePanelActivateKeyboardFocus = Notification.Name(
        "IncomeClock.Panel.ActivateKeyboardFocus"
    )
    static let incomePanelCancelConfirmation = Notification.Name(
        "IncomeClock.Panel.CancelConfirmation"
    )
}

@MainActor
protocol PanelControlling: AnyObject {
    func restore() async -> Bool
    func show(persist: Bool, focus: Bool)
    func hide(persist: Bool)
    func runtimePreferences() -> PanelRuntimePreferences
    func resetToDefaultPlacement() async -> Bool
    func setAlwaysOnTop(_ value: Bool) async -> Bool
    func setLockPanelPosition(_ value: Bool) async -> Bool
    func setHideInFullScreen(_ value: Bool) async -> Bool
    func setVisibilityChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void)
}

struct PanelRuntimePreferences: Equatable, Sendable {
    var alwaysOnTop = true
    var lockPanelPosition = false
    var hideInFullScreen = true
}

enum PanelRuntimeError: Error, Equatable {
    case settingsDamaged(RecordDamageIssue)
    case persistence(PersistenceError)
}

final class IncomePanel: NSPanel {
    enum KeyboardCommand: Equatable {
        case advanceFocus(reverse: Bool)
        case activateFocus
        case cancelConfirmation
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var keyboardCommandHandler: ((KeyboardCommand) -> Void)?
#if DEBUG
    var semanticFocusForTesting: (() -> Stage5PanelKeyboardFocus?)?
#endif

    override func sendEvent(_ event: NSEvent) {
        guard let command = Self.keyboardCommand(for: event) else {
            super.sendEvent(event)
            return
        }
        switch command {
        case let .advanceFocus(reverse):
            NotificationCenter.default.post(
                name: .incomePanelAdvanceKeyboardFocus,
                object: self,
                userInfo: ["reverse": reverse]
            )
        case .activateFocus:
            NotificationCenter.default.post(
                name: .incomePanelActivateKeyboardFocus,
                object: self
            )
        case .cancelConfirmation:
            NotificationCenter.default.post(
                name: .incomePanelCancelConfirmation,
                object: self
            )
        }
        keyboardCommandHandler?(command)
    }

    static func keyboardCommand(for event: NSEvent) -> KeyboardCommand? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let standardHandlingModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .function]
        guard modifiers.intersection(standardHandlingModifiers).isEmpty else { return nil }

        switch event.keyCode {
        case 48: // Tab / Shift-Tab
            return .advanceFocus(reverse: modifiers.contains(.shift))
        case 36, 49, 76: // Return, Space, keypad Enter
            guard !modifiers.contains(.shift) else { return nil }
            return .activateFocus
        case 53: // Escape
            guard !modifiers.contains(.shift) else { return nil }
            return .cancelConfirmation
        default:
            return nil
        }
    }
}

@MainActor
final class PanelController: NSObject, PanelControlling, NSWindowDelegate {
    private let businessStore: BusinessStore
    private let themeStore: ThemeStore
    private let repository: (any PanelSettingsPersisting)?
    private let profile: PanelPresentationProfile
    private let screenProvider: any PanelScreenProviding
    private let placementController: PanelPlacementController
    private let nowMilliseconds: @MainActor () -> Int64
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let keyboardCoordinator = Stage5PanelKeyboardCoordinator()

    private let renderPulse = PanelRenderPulseCoordinator(isVisible: false)
    private var panel: IncomePanel?
    private var settingsRecord: SettingsRecord?
    private var behaviorPreferences = PanelRuntimePreferences()
    private var currentPlacement: PanelPlacementRecord?
    private var visibilityChangeHandler: (@MainActor (Bool) -> Void)?
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var movementGeneration = 0
    private var visibilityGeneration = 0
    private var pendingFocusGeneration: Int?
#if DEBUG
    // Test opt-in only; no output or retained trace in ordinary app execution.
    var focusDeliveryTrace: (@MainActor (String) -> Void)? {
        didSet { keyboardCoordinator.focusBindingTrace = focusDeliveryTrace }
    }
    private var focusDeliveryTraceCount = 0
#endif
    private var isApplyingFrame = false
    private var persistenceTail: Task<Void, Never>?

    private(set) var lastRuntimeError: PanelRuntimeError?
    var windowForTesting: IncomePanel? { panel }

    init(
        businessStore: BusinessStore,
        themeStore: ThemeStore? = nil,
        repository: (any PanelSettingsPersisting)? = nil,
        profileRegistry: PanelPresentationProfileRegistry = .init(),
        screenProvider: any PanelScreenProviding = SystemPanelScreenProvider(),
        placementController: PanelPlacementController = .init(),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        nowMilliseconds: @escaping @MainActor () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.businessStore = businessStore
        self.themeStore = themeStore ?? ThemeStore()
        self.repository = repository
        profile = profileRegistry.standard
        self.screenProvider = screenProvider
        self.placementController = placementController
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.nowMilliseconds = nowMilliseconds
        super.init()
        observeSystemChanges()
    }

    deinit {
        observerTokens.forEach { center, token in
            center.removeObserver(token)
        }
    }

    func restore() async -> Bool {
        let restoredSettings: SettingsRecord?
        let restoredPending: PendingPanelPreferences?
        if let repository {
            switch await repository.loadPanelPersistence() {
            case .missing:
                restoredSettings = nil
                restoredPending = nil
            case let .pending(pending):
                restoredSettings = nil
                restoredPending = pending
            case let .loaded(settings):
                restoredSettings = settings
                restoredPending = nil
            case let .damaged(damage):
                restoredSettings = nil
                restoredPending = nil
                lastRuntimeError = .settingsDamaged(damage.issue)
            }
        } else {
            restoredSettings = nil
            restoredPending = nil
        }

        settingsRecord = restoredSettings
        behaviorPreferences = PanelRuntimePreferences(
            alwaysOnTop: restoredSettings?.alwaysOnTop ?? restoredPending?.alwaysOnTop ?? true,
            lockPanelPosition: restoredSettings?.lockPanelPosition ?? restoredPending?.lockPanelPosition ?? false,
            hideInFullScreen: restoredSettings?.hideInFullScreen ?? restoredPending?.hideInFullScreen ?? true
        )
        let panel = panel ?? makePanel()
        applyWindowBehavior(to: panel)
        currentPlacement = placementController.restoredPlacement(
            restoredSettings?.panelPlacement ?? restoredPending?.panelPlacement,
            screens: screenProvider.screens,
            mainScreen: screenProvider.mainScreen,
            profile: profile
        )
        applyCurrentPlacement(to: panel)
        return restoredSettings?.panelVisible ?? restoredPending?.panelVisible ?? true
    }

    func show(persist: Bool = true, focus: Bool = false) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        pendingFocusGeneration = focus ? generation : nil
        let panel = panel ?? makePanel()
        if currentPlacement == nil {
            currentPlacement = placementController.restoredPlacement(
                nil,
                screens: screenProvider.screens,
                mainScreen: screenProvider.mainScreen,
                profile: profile
            )
            applyCurrentPlacement(to: panel)
        }
        if focus {
            traceFocusDelivery("armed", panel: panel)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // makeKey may complete synchronously or on a later activation turn.
            // The delegate consumes the pending generation in the latter case.
            deliverPendingFocus(to: panel, reason: "show-already-key")
        } else {
            traceFocusDelivery("cancel-ordinary-show", panel: panel)
            panel.orderFrontRegardless()
        }
        renderPulse.setVisible(true)
        Task { await renderPulse.pulse(businessStore) }
        visibilityChangeHandler?(true)
        if persist {
            enqueue(.visibility(true))
        }
    }

    func hide(persist: Bool = true) {
        visibilityGeneration += 1
        pendingFocusGeneration = nil
        if let panel { traceFocusDelivery("cancel-hide", panel: panel) }
        renderPulse.setVisible(false)
        panel?.orderOut(nil)
        visibilityChangeHandler?(false)
        if persist {
            enqueue(.visibility(false))
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let candidate = notification.object as? IncomePanel,
              candidate === panel else { return }
        traceFocusDelivery("did-become-key", panel: candidate)
        deliverPendingFocus(to: candidate, reason: "did-become-key")
    }

    private func deliverPendingFocus(to candidate: IncomePanel, reason: String) {
        guard candidate === panel, candidate.isVisible, candidate.isKeyWindow,
              let generation = pendingFocusGeneration,
              generation == visibilityGeneration else { return }
        // Clear before publishing, so a synchronous callback cannot redeliver.
        pendingFocusGeneration = nil
        traceFocusDelivery("deliver-" + reason, panel: candidate)
        keyboardCoordinator.requestInitialFocus()
    }

    private func traceFocusDelivery(_ event: String, panel: IncomePanel) {
#if DEBUG
        guard let trace = focusDeliveryTrace, focusDeliveryTraceCount < 64 else { return }
        focusDeliveryTraceCount += 1
        trace("event=\(event),uptime=\(ProcessInfo.processInfo.systemUptime),generation=\(visibilityGeneration),pending=\(String(describing: pendingFocusGeneration)),window=\(panel.windowNumber),visible=\(panel.isVisible),key=\(panel.isKeyWindow),appActive=\(NSApp.isActive),fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
#endif
    }

    func setVisibilityChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
        visibilityChangeHandler = handler
    }

    func runtimePreferences() -> PanelRuntimePreferences { behaviorPreferences }

    func setAlwaysOnTop(_ value: Bool) async -> Bool {
        await persistenceTail?.value
        return await commit(.alwaysOnTop(value))
    }

    func setLockPanelPosition(_ value: Bool) async -> Bool {
        await persistenceTail?.value
        return await commit(.lockPanelPosition(value))
    }

    func setHideInFullScreen(_ value: Bool) async -> Bool {
        await persistenceTail?.value
        return await commit(.hideInFullScreen(value))
    }

    func resetToDefaultPlacement() async -> Bool {
        await persistenceTail?.value
        guard let mainScreen = screenProvider.mainScreen else { return false }
        let placement = placementController.defaultPlacement(on: mainScreen, profile: profile)
        guard await commit(.placement(placement)) else { return false }
        currentPlacement = placement
        if let panel { applyCurrentPlacement(to: panel) }
        return true
    }

    func reapplyScreenConstraints() {
        guard let panel else { return }
        let previous = currentPlacement
        let constrained = placementController.restoredPlacement(
            currentPlacement ?? settingsRecord?.panelPlacement,
            screens: screenProvider.screens,
            mainScreen: screenProvider.mainScreen,
            profile: profile
        )
        currentPlacement = constrained
        applyCurrentPlacement(to: panel)
        if let constrained, constrained != previous {
            enqueue(.placement(constrained))
        }
    }

    func finishDragging() {
        guard !behaviorPreferences.lockPanelPosition,
              let panel,
              let placement = placementController.snappedPlacement(
                for: panel.frame,
                screens: screenProvider.screens,
                mainScreen: screenProvider.mainScreen,
                profile: profile
              ) else { return }
        currentPlacement = placement
        applyCurrentPlacement(to: panel)
        enqueue(.placement(placement))
    }

    func waitForPendingPersistence() async {
        await persistenceTail?.value
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(persist: true)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame,
              !behaviorPreferences.lockPanelPosition else { return }
        movementGeneration += 1
        let generation = movementGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.movementGeneration == generation else { return }
            self.finishDragging()
        }
    }

    private func makePanel() -> IncomePanel {
        let panel = IncomePanel(
            contentRect: CGRect(origin: .zero, size: profile.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "可视收入打卡机"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.contentMinSize = profile.contentSize
        panel.contentMaxSize = profile.contentSize
        let openSettings: () -> Void = {
            NativeSettingsWindowRouter.open()
            NSApp.activate(ignoringOtherApps: true)
        }
        let hidePanel: () -> Void = { [weak self] in
            self?.hide(persist: true)
        }
        keyboardCoordinator.configure(
            businessStore: businessStore,
            onOpenSettings: openSettings,
            onHide: hidePanel
        )
        panel.contentViewController = NSHostingController(
            rootView: IncomePanelView(
                businessStore: businessStore,
                themeStore: themeStore,
                profile: profile,
                onOpenSettings: openSettings,
                onHide: hidePanel,
                keyboardCoordinator: keyboardCoordinator,
                renderPulse: renderPulse
            )
        )
        panel.keyboardCommandHandler = { [weak keyboardCoordinator] command in
            keyboardCoordinator?.send(command)
        }
#if DEBUG
        panel.semanticFocusForTesting = { [weak keyboardCoordinator] in
            keyboardCoordinator?.semanticFocus
        }
#endif
        applyWindowBehavior(to: panel)
        self.panel = panel
        return panel
    }

    private func applyWindowBehavior(to panel: IncomePanel) {
        panel.level = behaviorPreferences.alwaysOnTop ? .floating : .normal
        panel.isMovableByWindowBackground = !behaviorPreferences.lockPanelPosition
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces]
        if !behaviorPreferences.hideInFullScreen {
            behavior.insert(.fullScreenAuxiliary)
        }
        panel.collectionBehavior = behavior
    }

    private func applyCurrentPlacement(to panel: IncomePanel) {
        guard let frame = currentPlacement?.constrainedFrame.cgRect else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: false)
        isApplyingFrame = false
    }

    private func observeSystemChanges() {
        let screenToken = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyScreenConstraints()
            }
        }
        observerTokens.append((notificationCenter, screenToken))

        let spaceToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.applyWindowBehavior(to: panel)
            }
        }
        observerTokens.append((workspaceNotificationCenter, spaceToken))

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyScreenConstraints()
            }
        }
        observerTokens.append((workspaceNotificationCenter, wakeToken))
    }

    private func enqueue(_ mutation: PanelSettingsMutation) {
        guard repository != nil else { return }
        let previous = persistenceTail
        persistenceTail = Task { @MainActor [weak self] in
            await previous?.value
            _ = await self?.commit(mutation)
        }
    }

    @discardableResult
    private func commit(_ mutation: PanelSettingsMutation) async -> Bool {
        guard let repository else { return false }
        do {
            switch try await repository.persistPanelMutation(
                mutation,
                updatedAtMs: nowMilliseconds()
            ) {
            case let .pending(pending):
                behaviorPreferences.apply(pending)
                if let panel { applyWindowBehavior(to: panel) }
                lastRuntimeError = nil
            case let .committed(committed):
                settingsRecord = committed
                behaviorPreferences = PanelRuntimePreferences(
                    alwaysOnTop: committed.alwaysOnTop,
                    lockPanelPosition: committed.lockPanelPosition,
                    hideInFullScreen: committed.hideInFullScreen
                )
                if let panel {
                    applyWindowBehavior(to: panel)
                }
                lastRuntimeError = nil
            case let .damaged(damage):
                lastRuntimeError = .settingsDamaged(damage.issue)
                return false
            }
            return true
        } catch let error as PersistenceError {
            lastRuntimeError = .persistence(error)
            return false
        } catch {
            lastRuntimeError = .persistence(.atomicWriteFailed)
            return false
        }
    }
}

private extension PanelRuntimePreferences {
    mutating func apply(_ pending: PendingPanelPreferences) {
        if let value = pending.alwaysOnTop { alwaysOnTop = value }
        if let value = pending.lockPanelPosition { lockPanelPosition = value }
        if let value = pending.hideInFullScreen { hideInFullScreen = value }
    }
}
