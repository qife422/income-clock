import AppKit
import ApplicationServices
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    private var menuSummaryContrast: NativeMenuSummaryContrast?

    override init() {
        do {
            environment = try Self.makeEnvironment()
        } catch {
            preconditionFailure("Unable to construct the application environment: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contrast = NativeMenuSummaryContrast { [weak self] in
            guard let self else { return nil }
            return MenuBarContentView(environment: self.environment).nativeMenuFingerprint
        }
        menuSummaryContrast = contrast
        contrast.start()
        Task { @MainActor in
#if DEBUG
            if await SettingsRecoveryHarness.runIfRequested() { return }
#endif
            await environment.start()
#if DEBUG
            await PanelFocusHarness.runIfRequested(environment: environment)
#endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuSummaryContrast?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

#if DEBUG
    private static func isolatedDebugClock() -> any NowProvider {
        // Called only inside the explicit INCOMECLOCK_TEST_ROOT branch.
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let text = value(after: "--debug-now-ms"), let milliseconds = Int64(text) else {
            return SystemClock()
        }
        let rate = value(after: "--debug-time-rate").flatMap(Double.init) ?? 1
        guard rate.isFinite, rate >= 0, rate <= 86_400 else {
            return FixedClock(instant: .init(rawValue: milliseconds))
        }
        return AdvancingClock(origin: .init(rawValue: milliseconds), rate: rate)
    }
#endif

    private static func makeEnvironment() throws -> AppEnvironment {
#if DEBUG
        let launchEnvironment: [String: String]
        do { launchEnvironment = try Stage9RecoveryBootstrap.resolveEnvironment() }
        catch {
            FileHandle.standardError.write(Data("recovery bootstrap rejected: \(error)\n".utf8))
            Darwin.exit(92)
        }
        if let testRootPath = launchEnvironment["INCOMECLOCK_TEST_ROOT"] {
            let root: URL
            do { root = try Stage9RecoveryBootstrap.validatedExplicitRoot(testRootPath) }
            catch {
                FileHandle.standardError.write(Data("isolated test root rejected: \(error)\n".utf8))
                Darwin.exit(92)
            }
            let repository = RecordRepositoryActor(paths: .init(root: root))
            if let nonce = ProcessInfo.processInfo.environment["INCOMECLOCK_UI_ISOLATION_NONCE"] {
                // A sandboxed UI runner cannot spawn ps. Emit a launch receipt
                // from this exact isolated repository branch for PID/nonce checks.
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "nonce": nonce,
                    "root": root.resolvingSymlinksInPath().path,
                    "bundle": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                    "arguments": ProcessInfo.processInfo.arguments
                ]
                try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("ui-isolation-receipt.json"), options: .atomic)
            }
            return try AppEnvironment(
                repository: repository,
                nowProvider: isolatedDebugClock(),
                timeZoneIdentifier: TimeZone.current.identifier,
                notificationService: FakeNotificationService(),
                loginItemService: FakeLoginItemService(),
                themePreferencesRepository: repository,
                themeRepository: ThemeRepositoryActor(applicationSupportRoot: root)
            )
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("IncomeClockHostTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            return try AppEnvironment(
                repository: RecordRepositoryActor(paths: .init(root: root)),
                nowProvider: SystemClock(),
                timeZoneIdentifier: TimeZone.current.identifier
            )
        }
#if STAGE9_ISOLATED_TEST_BUILD
        // This dedicated local build must never reach production, even when
        // LaunchServices drops every launch argument and environment variable.
        FileHandle.standardError.write(Data("isolated test build requires a validated root or bootstrap\n".utf8))
        Darwin.exit(92)
#endif
#endif
        return try AppEnvironment.production()
    }
}

#if DEBUG
@MainActor
private enum PanelFocusHarness {
    private struct Result: Codable {
        let ordinaryShowVisible: Bool
        let ordinaryShowPreservedExternalFrontmost: Bool
        let ordinaryShowDidNotBecomeKey: Bool
        let shortcutWasResolvedByMainMenu: Bool
        let focusedShowBecameKey: Bool
        let focusedShowActivatedApplication: Bool
        let keyboardNavigationAdvancedFocus: Bool
        let initialSemanticFocusWasSettings: Bool
        let plainTabFocusedHide: Bool
        let spaceActivatedFocusedHide: Bool
        let returnActivatedFocusedPrimary: Bool
        let escapeCancelledConfirmation: Bool
        let immediateHideCancelledDelayedFocus: Bool
        let rapidTransitionsCancelledStaleFocus: Bool
        let finalExternalFrontmostPreserved: Bool
        let passed: Bool
        let observations: [String]
    }

    static func runIfRequested(environment: AppEnvironment) async {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard let resultPath = processEnvironment["INCOMECLOCK_FOCUS_HARNESS_RESULT"] else {
            return
        }

        log("start")
        let result = await run(environment: environment)
        log("completed passed=\(result.passed)")
        do {
            let data = try JSONEncoder.sortedAndPrettyPrinted.encode(result)
            try data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("focus harness result write failed: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }

    private static func run(environment: AppEnvironment) async -> Result {
        var observations: [String] = []
        log("waiting-for-panel")
        guard let panel = await waitForPanel() else {
            return Result(
                ordinaryShowVisible: false,
                ordinaryShowPreservedExternalFrontmost: false,
                ordinaryShowDidNotBecomeKey: false,
                shortcutWasResolvedByMainMenu: false,
                focusedShowBecameKey: false,
                focusedShowActivatedApplication: false,
                keyboardNavigationAdvancedFocus: false,
                initialSemanticFocusWasSettings: false,
                plainTabFocusedHide: false,
                spaceActivatedFocusedHide: false,
                returnActivatedFocusedPrimary: false,
                escapeCancelledConfirmation: false,
                immediateHideCancelledDelayedFocus: false,
                rapidTransitionsCancelledStaleFocus: false,
                finalExternalFrontmostPreserved: false,
                passed: false,
                observations: ["IncomePanel was not created after application restore"]
            )
        }

        log("ordinary-show")
        environment.hidePanel()
        await pause()
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        let finderActivated = finder?.activate(options: [.activateIgnoringOtherApps]) == true
        let finderWasFrontmost = await waitUntil {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        }
        observations.append("finderActivated=\(finderActivated), finderWasFrontmost=\(finderWasFrontmost)")

        environment.togglePanelFromMenuBar()
        let ordinaryShowVisible = await waitUntil { panel.isVisible }
        await pause(nanoseconds: 250_000_000)
        let ordinaryShowPreservedExternalFrontmost =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        let ordinaryShowDidNotBecomeKey = !panel.isKeyWindow
        observations.append(
            "ordinary visible=\(ordinaryShowVisible), key=\(panel.isKeyWindow), frontmost=" +
            "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
        )

        log("shortcut-focus")
        environment.hidePanel()
        await pause()
        let shortcutWasResolvedByMainMenu = performPanelShortcut()
        let focusedShowBecameKey = await waitUntil { panel.isVisible && panel.isKeyWindow }
        let focusedShowActivatedApplication = await waitUntil {
            NSApp.isActive && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        observations.append(
            "shortcutResolved=\(shortcutWasResolvedByMainMenu), visible=\(panel.isVisible), " +
            "key=\(panel.isKeyWindow), active=\(NSApp.isActive), frontmost=" +
            "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
        )

        log("keyboard-navigation")
        await pause()
        let accessibilityFocusBeforeTab = focusedAccessibilityElementDescription()
        let semanticBeforeInitialReturn = panel.semanticFocusForTesting?()
        postReturnKeyEvent(to: panel)
        let initialSemanticFocusWasSettings = await waitUntil {
            NSApp.windows.contains { !($0 is IncomePanel) && $0.isVisible }
        }
        NSApp.windows.filter { !($0 is IncomePanel) }.forEach { $0.close() }
        let saveOutcome = await environment.businessStore.send(
            .saveWorkRules(.init(
                dailyWageCents: 30_000,
                workStartMinuteOfDay: 0,
                workEndMinuteOfDay: 1_439
            )),
            source: .system
        )

        environment.hidePanel()
        _ = performPanelShortcut()
        _ = await waitUntil { panel.isVisible && panel.isKeyWindow }
        await pause()
        let semanticBeforeHideTab = panel.semanticFocusForTesting?()
        postTabKeyEvent(to: panel)
        await pause()
        let semanticAfterHideTab = panel.semanticFocusForTesting?()
        let accessibilityFocusAfterFirstTab = focusedAccessibilityElementDescription()
        postSpaceKeyEvent(to: panel)
        let spaceActivatedFocusedHide = await waitUntil { !panel.isVisible }
        let plainTabFocusedHide = spaceActivatedFocusedHide

        _ = performPanelShortcut()
        _ = await waitUntil { panel.isVisible && panel.isKeyWindow }
        await pause()
        let reopenedAtSettings = panel.isVisible && panel.isKeyWindow
        let semanticBeforePrimaryTabs = panel.semanticFocusForTesting?()
        postTabKeyEvent(to: panel)
        await pause()
        let semanticAfterFirstPrimaryTab = panel.semanticFocusForTesting?()
        postTabKeyEvent(to: panel)
        await pause()
        let semanticAfterSecondPrimaryTab = panel.semanticFocusForTesting?()
        let accessibilityFocusAtPrimary = focusedAccessibilityElementDescription()
        postReturnKeyEvent(to: panel)
        let returnActivatedFocusedPrimary = await waitUntil {
            guard let state = environment.businessStore.viewState?.state else { return false }
            return [.clockedInWaiting, .earning, .awaitingClockOut].contains(state)
        }
        let stateAfterPrimary = environment.businessStore.viewState?.state
        let confirmationOutcome = await environment.businessStore.send(
            .requestClockOut,
            source: .system
        )
        environment.hidePanel()
        _ = performPanelShortcut()
        _ = await waitUntil { panel.isVisible && panel.isKeyWindow }
        await pause()
        let accessibilityFocusAtCancel = focusedAccessibilityElementDescription()
        postEscapeKeyEvent(to: panel)
        let escapeCancelledConfirmation = await waitUntil {
            environment.businessStore.confirmation == nil
        }
        let keyboardNavigationAdvancedFocus =
            initialSemanticFocusWasSettings && plainTabFocusedHide &&
            spaceActivatedFocusedHide && reopenedAtSettings &&
            returnActivatedFocusedPrimary && escapeCancelledConfirmation
        observations.append(
            "accessibilityBefore=\(accessibilityFocusBeforeTab ?? "nil"), " +
            "accessibilityAfterFirst=\(accessibilityFocusAfterFirstTab ?? "nil"), " +
            "accessibilityAtPrimary=\(accessibilityFocusAtPrimary ?? "nil"), " +
            "accessibilityAtCancel=\(accessibilityFocusAtCancel ?? "nil"), " +
            "semanticInitial=\(String(describing: semanticBeforeInitialReturn)), " +
            "semanticHideBefore=\(String(describing: semanticBeforeHideTab)), " +
            "semanticHideAfter=\(String(describing: semanticAfterHideTab)), " +
            "semanticPrimary=\(String(describing: semanticBeforePrimaryTabs))/" +
            "\(String(describing: semanticAfterFirstPrimaryTab))/" +
            "\(String(describing: semanticAfterSecondPrimaryTab)), " +
            "spaceHid=\(spaceActivatedFocusedHide), returnActivatedPrimary=" +
            "\(returnActivatedFocusedPrimary), escapeCancelled=\(escapeCancelledConfirmation), " +
            "save=\(saveOutcome), stateAfterPrimary=\(String(describing: stateAfterPrimary)), " +
            "confirmation=\(confirmationOutcome), " +
            "advanced=\(keyboardNavigationAdvancedFocus)"
        )

        log("immediate-hide")
        environment.hidePanel()
        _ = performPanelShortcut()
        environment.hidePanel()
        await pause(nanoseconds: 250_000_000)
        let immediateHideCancelledDelayedFocus = !panel.isVisible && !panel.isKeyWindow
        observations.append(
            "immediateHide visible=\(panel.isVisible), key=\(panel.isKeyWindow)"
        )

        log("rapid-transitions")
        for _ in 0..<4 {
            _ = performPanelShortcut()
            environment.hidePanel()
        }
        _ = finder?.activate(options: [.activateIgnoringOtherApps])
        _ = await waitUntil {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        }
        await pause(nanoseconds: 350_000_000)
        let rapidTransitionsCancelledStaleFocus = !panel.isVisible && !panel.isKeyWindow
        let finalExternalFrontmostPreserved =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        observations.append(
            "rapidFinal visible=\(panel.isVisible), key=\(panel.isKeyWindow), frontmost=" +
            "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
        )

        let checks = [
            ordinaryShowVisible,
            ordinaryShowPreservedExternalFrontmost,
            ordinaryShowDidNotBecomeKey,
            shortcutWasResolvedByMainMenu,
            focusedShowBecameKey,
            focusedShowActivatedApplication,
            keyboardNavigationAdvancedFocus,
            initialSemanticFocusWasSettings,
            plainTabFocusedHide,
            spaceActivatedFocusedHide,
            returnActivatedFocusedPrimary,
            escapeCancelledConfirmation,
            immediateHideCancelledDelayedFocus,
            rapidTransitionsCancelledStaleFocus,
            finalExternalFrontmostPreserved
        ]
        return Result(
            ordinaryShowVisible: ordinaryShowVisible,
            ordinaryShowPreservedExternalFrontmost: ordinaryShowPreservedExternalFrontmost,
            ordinaryShowDidNotBecomeKey: ordinaryShowDidNotBecomeKey,
            shortcutWasResolvedByMainMenu: shortcutWasResolvedByMainMenu,
            focusedShowBecameKey: focusedShowBecameKey,
            focusedShowActivatedApplication: focusedShowActivatedApplication,
            keyboardNavigationAdvancedFocus: keyboardNavigationAdvancedFocus,
            initialSemanticFocusWasSettings: initialSemanticFocusWasSettings,
            plainTabFocusedHide: plainTabFocusedHide,
            spaceActivatedFocusedHide: spaceActivatedFocusedHide,
            returnActivatedFocusedPrimary: returnActivatedFocusedPrimary,
            escapeCancelledConfirmation: escapeCancelledConfirmation,
            immediateHideCancelledDelayedFocus: immediateHideCancelledDelayedFocus,
            rapidTransitionsCancelledStaleFocus: rapidTransitionsCancelledStaleFocus,
            finalExternalFrontmostPreserved: finalExternalFrontmostPreserved,
            passed: checks.allSatisfy { $0 },
            observations: observations
        )
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("focus-harness: \(message)\n".utf8))
    }

    private static func waitForPanel(timeout: TimeInterval = 5) async -> IncomePanel? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let panel = NSApp.windows.compactMap({ $0 as? IncomePanel }).first { return panel }
            await pause(nanoseconds: 50_000_000)
        } while Date() < deadline
        return NSApp.windows.compactMap { $0 as? IncomePanel }.first
    }

    private static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            await pause(nanoseconds: 50_000_000)
        } while Date() < deadline
        return condition()
    }

    private static func pause(nanoseconds: UInt64 = 100_000_000) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func performPanelShortcut() -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: 34
        ) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    private static func postTabKeyEvent(to panel: NSPanel) {
        postKeyEvent(
            to: panel,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            keyCode: 48
        )
    }

    private static func postSpaceKeyEvent(to panel: NSPanel) {
        postKeyEvent(
            to: panel,
            characters: " ",
            charactersIgnoringModifiers: " ",
            keyCode: 49
        )
    }

    private static func postReturnKeyEvent(to panel: NSPanel) {
        postKeyEvent(
            to: panel,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: 36
        )
    }

    private static func postEscapeKeyEvent(to panel: NSPanel) {
        postKeyEvent(
            to: panel,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            keyCode: 53
        )
    }

    private static func postKeyEvent(
        to panel: NSPanel,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        panel.sendEvent(event)
    }

    private static func focusedAccessibilityElementDescription() -> String? {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let element = value as! AXUIElement?
        else { return nil }

        func stringAttribute(_ attribute: String) -> String? {
            var attributeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &attributeValue
            ) == .success else { return nil }
            return attributeValue as? String
        }

        return [
            stringAttribute(kAXRoleAttribute),
            stringAttribute(kAXTitleAttribute),
            stringAttribute(kAXDescriptionAttribute),
            stringAttribute(kAXValueAttribute),
            stringAttribute(kAXHelpAttribute),
            stringAttribute(kAXIdentifierAttribute)
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }
}

private extension JSONEncoder {
    static var sortedAndPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
#endif

#if DEBUG
/// Sandboxed NSWorkspace callers cannot pass environment or arguments. A
/// short-lived, same-container request is the only additional DEBUG entrypoint.
/// A present but invalid request is an error, never a production fallback.
@MainActor
enum Stage9RecoveryBootstrap {
    struct Request: Codable, Equatable {
        let schema: Int
        let root: String
        let output: String
        let bundle: String
        let parentPID: Int32
        let nonce: String
        let mode: String
        let time: Int64
        let createdAt: Double
        let expiresAt: Double
    }
    static var activeEnvironment: [String: String]?
    static var markerURL: URL {
        FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("IncomeClockRecoveryBootstrap.request.json")
    }
    static func validatedExplicitRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = [FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !path.isEmpty, allowed.contains(where: { root.path.hasPrefix($0 + "/") }) else {
            throw PersistenceError.invalidProposedRecord
        }
        return root
    }
    static func validate(_ request: Request, now: Double, temporary: URL, bundle: URL) throws {
        let root = URL(fileURLWithPath: request.root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: request.output).standardizedFileURL.resolvingSymlinksInPath()
        guard request.schema == 1, UUID(uuidString: request.nonce) != nil,
              request.parentPID > 1, request.parentPID != ProcessInfo.processInfo.processIdentifier,
              request.createdAt.isFinite, request.expiresAt.isFinite,
              request.createdAt <= now, request.expiresAt > now,
              request.expiresAt - request.createdAt > 0, request.expiresAt - request.createdAt <= 60,
              request.bundle == bundle.standardizedFileURL.resolvingSymlinksInPath().path,
              request.root == root.path,
              root.deletingLastPathComponent().path == temporary.standardizedFileURL.resolvingSymlinksInPath().path,
              root.lastPathComponent.hasPrefix("IncomeClockRecovery-"),
              request.output == output.path, output.deletingLastPathComponent().path == root.path,
              ["commit", "restore", "earning-commit", "earning-restore", "prior-day-restore", "theme-restore"].contains(request.mode) else {
            throw PersistenceError.invalidProposedRecord
        }
    }
    static func readRequest(at url: URL) throws -> Request {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PersistenceError.invalidProposedRecord }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0, metadata.st_size > 0, metadata.st_size <= 65_536 else {
            throw PersistenceError.invalidProposedRecord
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        return try JSONDecoder().decode(Request.self, from: data)
    }
    static func environmentWhenMarkerMissing(_ original: [String: String], requireIsolation: Bool) throws -> [String: String] {
        guard requireIsolation else { return original }
        if let path = original["INCOMECLOCK_TEST_ROOT"] {
            _ = try validatedExplicitRoot(path)
            return original
        }
        // XCTest creates its existing independent ephemeral repository branch.
        if original["XCTestConfigurationFilePath"] != nil { return original }
        throw PersistenceError.invalidProposedRecord
    }
    static func resolveEnvironment() throws -> [String: String] {
        let original = ProcessInfo.processInfo.environment
#if !STAGE9_ISOLATED_TEST_BUILD
        // Ordinary Debug ignores even a leftover bootstrap marker entirely.
        return original
#else
        var metadata = stat()
        let exists = lstat(markerURL.path, &metadata)
        if exists != 0 {
            guard errno == ENOENT else { throw PersistenceError.invalidProposedRecord }
#if STAGE9_ISOLATED_TEST_BUILD
            return try environmentWhenMarkerMissing(original, requireIsolation: true)
#else
            return try environmentWhenMarkerMissing(original, requireIsolation: false)
#endif
        }
        let request = try readRequest(at: markerURL)
        try validate(request, now: Date().timeIntervalSince1970,
            temporary: FileManager.default.temporaryDirectory, bundle: Bundle.main.bundleURL)
        guard let parent = NSRunningApplication(processIdentifier: request.parentPID), !parent.isTerminated,
              parent.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == request.bundle else {
            throw PersistenceError.invalidProposedRecord
        }
        let root = URL(fileURLWithPath: request.root, isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw PersistenceError.invalidProposedRecord
        }
        // O_EXCL is the claim: a second app racing this request must fail closed.
        // The fixed request remains present until the parent verifies this receipt.
        let claim = root.appendingPathComponent("bootstrap-claim-\(request.nonce).json")
        let lock = claim.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PersistenceError.invalidProposedRecord }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "parentPID": request.parentPID, "nonce": request.nonce, "root": request.root,
            "bundle": request.bundle, "mode": request.mode]
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try handle.write(contentsOf: receiptData)
        try handle.synchronize()
        try handle.close()
        // The exclusive lock chooses one child; only this atomic ready file is
        // observed by the parent, so it cannot see the lock's empty/partial bytes.
        guard !FileManager.default.fileExists(atPath: claim.path) else {
            throw PersistenceError.invalidProposedRecord
        }
        try receiptData.write(to: claim, options: .atomic)
        var environment = original
        environment["INCOMECLOCK_TEST_ROOT"] = request.root
        environment["INCOMECLOCK_SETTINGS_RECOVERY_MODE"] = request.mode
        environment["INCOMECLOCK_SETTINGS_RECOVERY_RESULT"] = request.output
        environment["INCOMECLOCK_SETTINGS_RECOVERY_TIME"] = String(request.time)
        environment["INCOMECLOCK_RECOVERY_NONCE"] = request.nonce
        activeEnvironment = environment
        return environment
#endif
    }
}
#endif

#if DEBUG
// Lossless, JSON-safe observation of every BusinessViewState field for the
// isolated process fixture. No production execution path calls this serializer.
enum Stage9RecoverySnapshot {
    static func object(_ state: BusinessViewState?) -> [String: Any] {
        guard let state else { return ["missing": true] }
        func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        let amount: [String: Any]
        switch state.amount {
        case .hidden: amount = ["kind": "hidden"]
        case let .live(value): amount = ["kind": "live", "raw": value.rawValue]
        case let .rounded(value): amount = ["kind": "rounded", "raw": value.rawValue]
        }
        return [
            "state": state.state.rawValue,
            "recoveryReason": optional(state.recoveryReason.map { String(reflecting: $0) }),
            "amount": amount,
            "earnedDuration": optional(state.earnedDuration?.rawValue),
            "scheduledProgress": optional(state.scheduledProgress),
            "remainingToStart": optional(state.remainingToStart?.rawValue),
            "remainingToEnd": optional(state.remainingToEnd?.rawValue),
            "clockInAt": optional(state.clockInAt?.rawValue),
            "clockOutAt": optional(state.clockOutAt?.rawValue),
            "todayDateKey": optional(state.todayDateKey),
            "todayTimeZoneIdentifier": optional(state.todayTimeZoneIdentifier),
            "isPreviousWorkday": state.isPreviousWorkday,
            "clockOutDateKey": optional(state.clockOutDateKey),
            "canClockIn": state.canClockIn,
            "canRequestClockOut": state.canRequestClockOut,
            "canRequestTodayReset": state.canRequestTodayReset,
            "canRequestStartToday": state.canRequestStartToday,
            "canRequestSettingsReset": state.canRequestSettingsReset,
            "previousDayCleanupPending": state.previousDayCleanupPending
        ]
    }
}
#endif

#if DEBUG
// Explicitly opt-in, isolated process fixture; never used by the normal app lifecycle.
@MainActor
private enum SettingsRecoveryHarness {
    private final class HoldCommittedResult: SaveSettingsResultDeliveryControlling {
        var reachedCommit = false
        let shouldHold: Bool
        init(shouldHold: Bool) { self.shouldHold = shouldHold }
        func deliver(_ delivery: SaveSettingsResultDelivery) {
            if delivery.kind == .committed && shouldHold { reachedCommit = true }
            else { delivery.deliver() }
        }
    }

    private final class CountingFiles: RecordFileStore, SaveSettingsCommandContextObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var settingsCommands = 0
        private var repositoryAttempts = 0
        var saveCommandEntries: Int { lock.lock(); defer { lock.unlock() }; return settingsCommands }
        var repositoryWriteAttempts: Int { lock.lock(); defer { lock.unlock() }; return repositoryAttempts }
        func observe(_ context: BusinessCommandContext, consumer: SaveSettingsContextConsumer) {
            lock.lock(); defer { lock.unlock() }
            if consumer == .commandEntry { settingsCommands += 1 }
            if consumer == .repositoryWrite { repositoryAttempts += 1 }
        }
        private let base = AtomicRecordFileStore()
        var writeAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
        func readData(at url: URL) throws -> Data? { try base.readData(at: url) }
        func commitAtomically(_ data: Data, to url: URL) throws {
            lock.lock(); attempts += 1; lock.unlock()
            try base.commitAtomically(data, to: url)
        }
        func removeItem(at url: URL) throws {
            lock.lock(); attempts += 1; lock.unlock()
            try base.removeItem(at: url)
        }
        func copyItem(at source: URL, to target: URL) throws {
            lock.lock(); attempts += 1; lock.unlock()
            try base.copyItem(at: source, to: target)
        }
    }

    private static func honorSelfTerminationRequest(environment: [String: String], root: URL,
                                                     resultURL: URL, mode: String) throws {
#if STAGE9_ISOLATED_TEST_BUILD
        guard let nonce = environment["INCOMECLOCK_RECOVERY_NONCE"], UUID(uuidString: nonce) != nil else { return }
        let requestURL = resultURL.appendingPathExtension("signal.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any]
        guard object?["nonce"] as? String == nonce,
              object?["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier,
              object?["root"] as? String == root.path,
              object?["mode"] as? String == mode,
              object?["signal"] as? Int32 == SIGKILL else {
            throw PersistenceError.invalidProposedRecord
        }
        // This is an intention receipt immediately BEFORE the actual kernel
        // call; neither side claims a parent kill success or waitpid exit code.
        let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "nonce": nonce, "root": root.path, "mode": mode, "signal": SIGKILL,
            "sender": "self", "phase": "before-kill-syscall"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: resultURL.appendingPathExtension("signal-receipt.json"), options: .atomic)
        guard Darwin.kill(Darwin.getpid(), SIGKILL) == 0 else {
            throw PersistenceError.invalidProposedRecord
        }
#endif
    }

    static func runIfRequested() async -> Bool {
        let env = Stage9RecoveryBootstrap.activeEnvironment ?? ProcessInfo.processInfo.environment
        guard let mode = env["INCOMECLOCK_SETTINGS_RECOVERY_MODE"],
              let path = env["INCOMECLOCK_TEST_ROOT"],
              let output = env["INCOMECLOCK_SETTINGS_RECOVERY_RESULT"] else { return false }
        do {
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            // Refuse real Application Support and arbitrary filesystem destinations.
            let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let containerTemporaryRoot = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
            let resultURL = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            guard [temporaryRoot.path, containerTemporaryRoot.path].contains(root.deletingLastPathComponent().path),
                  root.lastPathComponent.hasPrefix("IncomeClockRecovery-"),
                  resultURL.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
                  ["commit", "restore", "earning-commit", "earning-restore", "prior-day-restore", "theme-restore"].contains(mode) else {
                FileHandle.standardError.write(Data("recovery fixture rejected path: \(root.path), temporary: \(temporaryRoot.path)\n".utf8))
                throw PersistenceError.invalidProposedRecord
            }
            let files = CountingFiles()
            let paths = RecordRepositoryPaths(root: root)
            let repository = RecordRepositoryActor(paths: paths, fileStore: files)
            let delivery = HoldCommittedResult(shouldHold: mode == "commit")
            // Fixed absolute time is supplied by the fixture, never by normal application startup.
            guard let rawTime = env["INCOMECLOCK_SETTINGS_RECOVERY_TIME"], let time = Int64(rawTime) else {
                throw PersistenceError.invalidProposedRecord
            }
            let clock = FixedClock(instant: .init(rawValue: time))
            let notificationService = FakeNotificationService(authorization: .authorized)
            if mode == "theme-restore",
               case let .loaded(today, _) = await repository.loadToday(),
               let identifier = today.notificationRequestIdentifier {
                await notificationService.setPendingIdentifiers([identifier])
            }
            let businessNotifications: any NotificationServicing
            if mode == "theme-restore" { businessNotifications = notificationService }
            else { businessNotifications = UnavailableNotificationService() }
            let store = try BusinessStore(repository: repository, nowProvider: clock,
                timeZoneIdentifierProvider: FixedTimeZoneIdentifierProvider(identifier: "Asia/Shanghai"),
                saveSettingsCommandContextObserver: files,
                saveSettingsResultDeliveryController: delivery,
                notificationService: businessNotifications)
            await store.restore()
            if mode == "commit" || mode == "earning-commit" {
                let outcome = await store.send(.saveWorkRules(.init(dailyWageCents: 88_000,
                    workStartMinuteOfDay: 540, workEndMinuteOfDay: 1080)), source: .settings)
                guard outcome == .committed else {
                    FileHandle.standardError.write(Data("recovery fixture save failed: \(outcome)\n".utf8))
                    throw PersistenceError.invalidProposedRecord
                }
            }
            if mode == "earning-commit" {
                let outcome = await store.send(.clockIn, source: .panel)
                guard outcome == .committed else {
                    FileHandle.standardError.write(Data("recovery fixture clock-in failed: \(outcome)\n".utf8))
                    throw PersistenceError.invalidProposedRecord
                }
            }
            var newClockInWasRejected = false
            if mode == "prior-day-restore" {
                let outcome = await store.send(.clockIn, source: .panel)
                newClockInWasRejected = outcome == .rejected(.invalidState)
            }
            guard case let .loaded(record, _) = await repository.loadSettingsForBusiness() else {
                throw PersistenceError.invalidProposedRecord
            }
            let amountRaw: Int64
            let amountKind: String
            switch store.viewState?.amount {
            case let .live(amount): amountRaw = amount.rawValue; amountKind = "live"
            case let .rounded(amount): amountRaw = amount.rawValue; amountKind = "rounded"
            default: amountRaw = -1; amountKind = "unavailable"
            }
            var object: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "mode": mode,
                "root": root.path,
                "bundle": Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path,
                "nonce": env["INCOMECLOCK_RECOVERY_NONCE"] ?? "",
                "harnessResultComplete": true,
                "revision": record.revision.rawValue,
                "wage": record.dailyWageCents,
                "writes": files.writeAttempts,
                "saveCommandEntries": files.saveCommandEntries,
                "repositoryWriteAttempts": files.repositoryWriteAttempts,
                "heldCommittedPublication": delivery.reachedCommit,
                "ready": store.viewState?.state == .ready,
                "state": store.viewState?.state.rawValue ?? "nil",
                "amountRaw": amountRaw,
                "amountKind": amountKind,
                "earnedDuration": store.viewState?.earnedDuration?.rawValue ?? -1,
                "clockInAt": store.viewState?.clockInAt?.rawValue ?? -1,
                "workDate": store.viewState?.todayDateKey ?? "nil",
                "isPreviousWorkday": store.viewState?.isPreviousWorkday ?? false,
                "canClockIn": store.viewState?.canClockIn ?? false,
                "newClockInWasRejected": newClockInWasRejected,
                "feedbackNil": store.feedback == nil,
                "readErrorNil": store.settingsReadErrorViewState == nil,
                "scheduleErrorNil": store.scheduleTimeErrorViewState == nil,
                "todayMissing": !FileManager.default.fileExists(atPath: paths.today.path)
            ]
            if mode == "theme-restore" {
                let before = Stage9RecoverySnapshot.object(store.viewState)
                let callsBefore = await notificationService.operationLog()
                let themes = ThemeStore(repository: repository,
                    themeRepository: ThemeRepositoryActor(applicationSupportRoot: root))
                await themes.restore()
                object["businessBeforeThemeRestore"] = before
                object["businessAfterThemeRestore"] = Stage9RecoverySnapshot.object(store.viewState)
                object["selectedThemeID"] = themes.selectedTheme.id
                object["selectedThemeVersion"] = themes.selectedTheme.manifest.themeVersion
                object["appearance"] = themes.preferredAppearance.rawValue
                object["soundsEnabled"] = themes.soundsEnabled
                object["fallbackNoticeNil"] = themes.viewState.fallbackNotice == nil
                object["themeErrorNil"] = themes.viewState.error == nil
                object["notificationCallsBefore"] = callsBefore.map { String(describing: $0) }
                object["notificationCallsAfter"] = await notificationService.operationLog().map { String(describing: $0) }
                object["writesAfterThemeRestore"] = files.writeAttempts
                object["root"] = root.path
            }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
            if mode == "commit" || mode == "earning-commit" {
                // The parent requests an authenticated self-SIGKILL while
                // publication is still held. No graceful shutdown or business command.
                while true {
                    try honorSelfTerminationRequest(environment: env, root: root, resultURL: resultURL, mode: mode)
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
            }
            if let nonce = env["INCOMECLOCK_RECOVERY_NONCE"] {
                guard UUID(uuidString: nonce) != nil else { throw PersistenceError.invalidProposedRecord }
                let acknowledgement = resultURL.appendingPathExtension("ack")
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: acknowledgement.path), Date() < deadline {
                    try honorSelfTerminationRequest(environment: env, root: root, resultURL: resultURL, mode: mode)
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                guard try Data(contentsOf: acknowledgement) == Data(nonce.utf8) else {
                    throw PersistenceError.invalidProposedRecord
                }
            }
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("settings recovery harness: \(error)\n".utf8))
            Darwin.exit(91)
        }
    }
}
#endif
