import AppKit
import CoreText
import ApplicationServices
import CryptoKit
import ZIPFoundation
import SwiftUI
import XCTest
@testable import IncomeClock

/// These tests mount the production views and invoke their public accessibility
/// actions/native responder chain. Repository doubles only select success/failure
/// inputs; a Store/model assertion alone cannot satisfy any view expectation.
@MainActor
final class SettingsInteractionTests: XCTestCase {
    func testHostedThemeReinstallUpgradeRejectionAndNoncurrentDeletionPreserveBusinessRecords() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        let paths = RecordRepositoryPaths(root: root)
        let records = RecordRepositoryActor(paths: paths)
        _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(notificationsEnabled: true), expectedRevision: nil)
        let notifications = FakeNotificationService(authorization: .authorized)
        let business = try BusinessStore(repository: records,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        await business.restore()
        let clockIn = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(clockIn, .committed)
        let themes = ThemeStore(repository: records,
            themeRepository: ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0"))
        await themes.restore()
        let v1 = try managementThemePackage(in: root, version: "1.0.0")
        let v2 = try managementThemePackage(in: root, version: "1.1.0")
        // First installation is fixture setup; this method adds UI branch
        // evidence, not another atomic-install/validation corpus.
        await themes.beginImport(from: v1)
        await themes.installImportCandidate()
        XCTAssertNil(themes.importError)
        let id = "com.example.management-ui"
        XCTAssertTrue(themes.viewState.themes.contains { $0.id == id })
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes) })
        defer { host.close() }
        let settingsBytes = try Data(contentsOf: paths.settings)
        let todayBytes = try Data(contentsOf: paths.today)
        let preferenceBytes = try? Data(contentsOf: paths.themePreferences)
        let originalState = business.viewState
        let originalToday = business.todayRecordForValidation
        let originalCalls = await notifications.operationLog()
        let installedManifest = root.appendingPathComponent("Themes/\(id)/manifest.json")
        func unchanged(_ step: String) async throws {
            XCTAssertEqual(business.viewState, originalState, step)
            XCTAssertEqual(business.todayRecordForValidation, originalToday, step)
            XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes, step)
            XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes, step)
            XCTAssertEqual(try? Data(contentsOf: paths.themePreferences), preferenceBytes, step)
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland, step)
            let calls = await notifications.operationLog()
            XCTAssertEqual(calls, originalCalls, step)
        }
        for (package, title, version) in [(v1, "重新安装", "1.0.0"), (v2, "更新皮肤", "1.1.0")] {
            for accept in [false, true] {
                let before = try Data(contentsOf: installedManifest)
                await themes.beginImport(from: package)
                let candidate = try XCTUnwrap(themes.importCandidate)
                XCTAssertEqual(candidate.disposition, title == "重新安装" ? .reinstall : .upgrade(from: "1.0.0"))
                try await waitFor { host.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(host.window.attachedSheet)
                let install = try await host.element(identifier: "theme-import-confirm", root: sheet)
                XCTAssertTrue(host.text(install).contains(title))
                if title == "重新安装" {
                    XCTAssertTrue(host.containsText("此版本已安装", root: sheet))
                } else {
                    XCTAssertTrue(host.containsText("1.0.0 → 1.1.0", root: sheet),
                        "The actual sheet must disclose both installed and proposed versions")
                }
                try await unchanged("preview \(title)")
                if accept { try host.press(try await host.element(identifier: "theme-import-confirm", root: sheet)) }
                else { try host.press(try await host.element(identifier: "theme-import-cancel", root: sheet)) }
                try await waitFor { themes.importCandidate == nil && host.window.attachedSheet == nil }
                XCTAssertNil(themes.importError)
                if accept {
                    XCTAssertEqual(themes.viewState.themes.first(where: { $0.id == id })?.manifest.themeVersion, version)
                } else {
                    XCTAssertEqual(try Data(contentsOf: installedManifest), before)
                    XCTAssertEqual(themes.viewState.themes.first(where: { $0.id == id })?.manifest.themeVersion, "1.0.0")
                }
                try await unchanged("\(accept ? "accepted" : "cancelled") \(title)")
            }
        }
        // Existing repository tests establish the rejection policy; here the
        // actual production error sheet exposes its reason and no install action.
        let conflict = try managementThemePackage(in: root, version: "2.0.0", author: "Different Author")
        for (package, code) in [(v1, "identity.downgrade"), (conflict, "identity.author")] {
            let before = try Data(contentsOf: installedManifest)
            await themes.beginImport(from: package)
            let error = try XCTUnwrap(themes.importError)
            let diagnostic = try XCTUnwrap(error.diagnostics.first { $0.code == code })
            try await waitFor { host.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(host.window.attachedSheet)
            _ = try await host.element(identifier: "theme-import-error", root: sheet)
            XCTAssertTrue(host.containsText(diagnostic.reason, root: sheet))
            XCTAssertTrue(host.containsText(diagnostic.suggestion, root: sheet))
            XCTAssertNil(host.find(identifier: "theme-import-confirm", root: sheet))
            XCTAssertNil(themes.importCandidate)
            XCTAssertEqual(try Data(contentsOf: installedManifest), before)
            try await unchanged(code)
            try host.press(try await host.button(label: "关闭", scope: "theme-import-error", root: sheet))
            try await waitFor { themes.importError == nil && host.window.attachedSheet == nil }
        }
        try host.press(try await host.element(identifier: "theme-preview-" + id))
        _ = try await host.element(identifier: "theme-details-preview")
        for accept in [false, true] {
            try host.press(try await host.element(identifier: "theme-delete-request"))
            _ = try await host.control(role: "AXButton", label: "取消")
            let dialog: NSObject = host.window.attachedSheet ?? host.window
            let confirm = try await host.element(identifier: "theme-delete-confirm", root: dialog)
            XCTAssertTrue(host.containsText("删除后需要重新导入才能使用。", root: dialog))
            XCTAssertFalse(host.containsText("将先切换为默认皮肤", root: dialog))
            try await unchanged("noncurrent deletion confirmation")
            if accept { try host.press(try await host.element(identifier: "theme-delete-confirm", root: dialog)) }
            else { try host.press(try await host.control(role: "AXButton", label: "取消")) }
            try await waitFor { !host.containsControl(role: "AXButton", label: "取消") }
            if accept {
                try await waitFor { !themes.viewState.themes.contains(where: { $0.id == id }) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: installedManifest.path))
            } else {
                XCTAssertTrue(themes.viewState.themes.contains { $0.id == id })
                XCTAssertTrue(FileManager.default.fileExists(atPath: installedManifest.path))
            }
            try await unchanged("noncurrent deletion \(accept ? "accepted" : "cancelled")")
        }
        for id in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            try host.press(try await host.element(identifier: "theme-preview-" + id))
            try await waitFor { host.find(identifier: "theme-delete-request") == nil }
            XCTAssertNil(host.find(identifier: "theme-delete-request"), "Builtin details must not offer deletion")
        }
        try await unchanged("builtin deletion unavailable")
        // Retain tiny isolated fixtures. No screenshot, file chooser, clipboard,
        // system preference or real Application Support interaction is used.
    }

    // Bounded supplementary raster fixtures: seven Dark pages + two error/focus views.
    // Native compositor and all-control/three-focus contrast acceptance remain separate.
    func testMountedMinimumDarkSettingsSevenPagesOriginalPNGs() async throws {
        let (host, _) = try await contrastSettingsHost(.dark)
        defer { host.close() }
        for section in Stage5SettingsSection.allCases {
            // Navigation action selects the actual production page; this fixture does not
            // claim keyboard traversal (covered by the separate native keyboard runner).
            try host.press(try await host.element(identifier: "settings-nav-" + section.rawValue))
            _ = try await host.element(identifier: "settings-page-" + section.rawValue)
            try await attachContrastOriginal(host, name: "Settings-Dark-Minimum-" + section.rawValue)
        }
    }

    func testMountedSettingsNativeControlContrastLightDarkOriginalPNGs() async throws {
        for mode in [PreferredThemeAppearance.light, .dark] {
            let (host, _) = try await contrastSettingsHost(mode)
            defer { host.close() }
            for title in ["通用", "面板与启动", "外观与皮肤", "数据与隐私"] {
                try host.press(try await host.element(identifier: "settings-nav-" + title))
                _ = try await host.element(identifier: "settings-page-" + title)
                if title == "通用" {
                    let sounds = try await host.control(role: "AXCheckBox", label: "皮肤提示音", scope: "settings-page-通用")
                    try await host.reachByTab(sounds)
                    XCTAssertTrue(host.hasKeyboardFocus(sounds))
                }
                host.dumpAccessibility(reason: "Native control contrast \(mode) \(title)")
                try await attachContrastOriginal(host, name: "Settings-NativeControls-\(mode)-" + title)
            }
        }
    }

    func testMountedMinimumSettingsErrorStartFocusLightDarkOriginalPNGs() async throws {
        for mode in [PreferredThemeAppearance.light, .dark] {
            let (host, store) = try await contrastSettingsHost(mode)
            defer { host.close() }
            try host.press(try await host.element(identifier: "settings-nav-工作规则"))
            _ = try await host.element(identifier: "settings-page-工作规则")
            let before = store.settingsRecordForValidation
            for (identifier, value) in [("settings-wage", "425.50"),
                                        ("settings-start", "25:00"), ("settings-end", "18:00")] {
                let field = try await host.element(identifier: identifier)
                try await host.reachByTab(field)
                XCTAssertTrue(host.hasKeyboardFocus(field))
                try await host.sendKey(code: 0, characters: "a", modifiers: .command)
                for character in value { try await host.sendKey(code: 0, characters: String(character)) }
            }
            // Return invokes the real default action. Its parser assigns start focus.
            try await host.sendKey(code: 36, characters: "\r")
            try await waitFor { host.containsText("请使用 HH:mm 的 24 小时时间。") }
            let start = try await host.element(identifier: "settings-start")
            try await waitFor { host.hasKeyboardFocus(start) }
            let save = try await host.element(identifier: "settings-save")
            XCTAssertEqual(host.boolAttribute(save, "isAccessibilityEnabled"), true)
            XCTAssertEqual(store.settingsRecordForValidation, before)
            XCTAssertNil(store.todayRecordForValidation)
            host.dumpAccessibility(reason: "Contrast \(mode) actual start focus and enabled Save")
            try await attachContrastOriginal(host, name: "Settings-\(mode)-Minimum-Error-StartFocus")
        }
    }

    private func contrastSettingsHost(_ mode: PreferredThemeAppearance) async throws -> (HostedSettings, BusinessStore) {
        let repository = BusinessRecordRepositorySpy(settings:
            .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
            notificationService: FakeNotificationService(authorization: .authorized))
        let themes = ThemeStore(repository: EphemeralThemePreferencesRepository())
        let environment = AppEnvironment(businessStore: store, panelController: KeyboardPanelController(),
            themeStore: themes, loginItemService: FakeLoginItemService())
        await environment.start()
        await themes.setAppearance(mode)
        XCTAssertEqual(themes.preferredAppearance, mode)
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        host.window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        host.window.setContentSize(NSSize(width: 680, height: 500))
        host.window.contentView?.layoutSubtreeIfNeeded()
        host.window.recalculateKeyViewLoop()
        return (host, store)
    }

    private func attachContrastOriginal(_ host: HostedSettings, name: String) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        let view = try XCTUnwrap(host.window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        XCTAssertEqual(view.bounds.width, 680, accuracy: 1)
        XCTAssertEqual(view.bounds.height, 500, accuracy: 1)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let metadata: [String: Any] = [
            "name": name, "png_sha256": sha,
            "pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
            "logicalWidth": view.bounds.width, "logicalHeight": view.bounds.height,
            "windowAppearance": host.window.effectiveAppearance.name.rawValue,
            "backingScaleFactor": host.window.backingScaleFactor,
            "colorSpace": bitmap.colorSpace.localizedName ?? "unknown",
            "producer": "Mounted NSHostingView.cacheDisplay; original PNG, no image conversion or resizing",
            "pixel_review": "Load PNG embedded ICC via NSBitmapImageRep, then colorAt(x,y).usingColorSpace(.sRGB) before WCAG luminance; record solid foreground/background coordinates and PNG SHA",
            "limit": "Mounted raster only. Native compositor focus/default-action/translucency must be confirmed in UI runner if absent/different. No automatic contrast PASS.",
            "textScale": "production semantic fonts; no incomePanelTextScale injection",
            "requirements": "UI12.2 UI18-047.a; minimum geometry is hosted content only, not native resize acceptance"
        ]
        let record = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        record.name = name + "-metadata"
        record.lifetime = .keepAlways
        add(record)
    }

    func testHostedPendingSettingsControlsExposeSharedDisabledReasons() async throws {
        // Untouched missing Settings: inspect the real form before entering any text.
        do {
            let repository = BusinessRecordRepositorySpy()
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await store.restore()
            let host = HostedSettings(WorkRulesSettingsView(businessStore: store))
            defer { host.close() }
            let save = try await host.element(identifier: "settings-save")
            XCTAssertEqual(host.boolAttribute(save, "isAccessibilityEnabled"), false)
            XCTAssertTrue(host.help(save).contains("请先填写日工资"))
        }
        let repository = BusinessRecordRepositorySpy(settings:
            .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
            notificationService: FakeNotificationService(authorization: .authorized))
        let themes = ThemeStore()
        await themes.restore()
        await store.restore()
        let login = FakeLoginItemService()
        let coordinator = PanelSettingsCoordinator(repository: repository,
            preferenceStore: EphemeralPanelPreferenceStore())
        let screens = MutablePanelScreenProvider(screens: [.init(displayUUID: "held-settings",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 836), isMain: true)])
        let panel = PanelController(businessStore: store, themeStore: themes,
            repository: coordinator, screenProvider: screens,
            notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())
        let environment = AppEnvironment(businessStore: store, panelController: panel,
            themeStore: themes, loginItemService: login)
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        let menu = HostedSettings(VStack { MenuBarContentView(environment: environment) })
        defer { host.close(); menu.close() }
        // Each hold below has a separate causal gate; no business flag substitutes for another.
        func page(_ title: String) async throws {
            try host.press(try await host.element(identifier: "settings-nav-" + title))
            _ = try await host.element(identifier: "settings-page-" + title)
        }
        func disabled(_ element: NSObject, reason: String, on view: HostedSettings) async throws {
            try await waitFor { view.boolAttribute(element, "isAccessibilityEnabled") == false }
            XCTAssertTrue(view.help(element).contains(reason) || view.containsText(reason),
                "Actual disabled control must have its shared help or co-present explanation")
        }
        try await page("工作规则")
        await repository.holdNextSettingsSave()
        defer { Task { await repository.resumeHeldSettingsSave() } }
        let saving = Task { await store.send(.saveWorkRules(.init(dailyWageCents: 42550,
            workStartMinuteOfDay: 540, workEndMinuteOfDay: 1080)), source: .settings) }
        await repository.waitUntilSettingsSaveIsHeld()
        try await disabled(try await host.element(identifier: "settings-save"),
            reason: "正在检查或保存设置", on: host)
        await repository.resumeHeldSettingsSave()
        _ = await saving.value

        try await page("数据与隐私")
        await repository.holdNextTodaySave()
        defer { Task { await repository.releaseHeldTodaySave() } }
        let business = Task { await store.send(.clockIn, source: .menuBar) }
        await repository.waitUntilTodaySaveIsHeld()
        try await disabled(try await host.button(label: "重置今日记录…", scope: "settings-page-数据与隐私"),
            reason: "正在处理打卡记录", on: host)
        try await disabled(try await menu.control(role: "AXButton", label: "打卡上班"),
            reason: "正在处理，请稍候", on: menu)
        await repository.releaseHeldTodaySave()
        _ = await business.value

        try await page("面板与启动")
        await login.holdNextRegister()
        defer { Task { await login.releaseHeldRegister() } }
        let registration = Task { await environment.loginItemController.setEnabled(true) }
        await login.waitUntilRegisterIsHeld()
        try await disabled(try await host.control(role: "AXCheckBox", label: "登录时启动", scope: "settings-page-面板与启动"),
            reason: "正在与系统登录项同步", on: host)
        try await disabled(try await menu.control(role: "AXCheckBox", label: "登录时启动"),
            reason: "正在同步登录项", on: menu)
        await login.releaseHeldRegister()
        await registration.value

        try await page("通用")
        await repository.holdNextSettingsSave()
        let notification = Task { await store.setNotificationsEnabled(true) }
        await repository.waitUntilSettingsSaveIsHeld()
        try await disabled(try await host.control(role: "AXCheckBox", label: "下班通知", scope: "settings-page-通用"),
            reason: "正在同步通知偏好", on: host)
        await repository.resumeHeldSettingsSave()
        _ = await notification.value

        try await page("面板与启动")
        await repository.holdNextSettingsSave()
        environment.resetPanelPlacement()
        await repository.waitUntilSettingsSaveIsHeld()
        try await disabled(try await host.button(label: "恢复默认面板位置", scope: "settings-page-面板与启动"),
            reason: "正在保存默认位置", on: host)
        await repository.resumeHeldSettingsSave()
        try await waitFor { !environment.isResettingPanelPlacement }

        // Fresh restore lifecycle; only the remaining General control is observed.
        let restoringRepository = BusinessRecordRepositorySpy()
        await restoringRepository.holdNextBusinessSettingsLoad()
        defer { Task { await restoringRepository.resumeBusinessSettingsLoad() } }
        let restoringStore = try BusinessStore(repository: restoringRepository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let restoringEnvironment = AppEnvironment(businessStore: restoringStore,
            panelController: PanelControllerSpy(), loginItemService: FakeLoginItemService())
        let restore = Task { await restoringStore.restore() }
        await restoringRepository.waitUntilBusinessSettingsLoadHeld()
        let restoringHost = HostedSettings(IncomeSettingsView(environment: restoringEnvironment))
        defer { restoringHost.close() }
        try restoringHost.press(try await restoringHost.element(identifier: "settings-nav-通用"))
        _ = try await restoringHost.element(identifier: "settings-page-通用")
        try await disabled(try await restoringHost.control(role: "AXCheckBox", label: "下班通知", scope: "settings-page-通用"),
            reason: "正在恢复本地记录", on: restoringHost)
        await restoringRepository.resumeBusinessSettingsLoad()
        await restore.value
    }

    private func managementThemePackage(in root: URL, version: String,
                                        author: String = "Management Test") throws -> URL {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR42mP8z8AARAwMjIwgAQAQAgEAff9QNgAAAABJRU5ErkJggg=="))
        let fallback = ValidatedTheme.warmIslandFallback.manifest
        let manifest = ThemePackageManifest(schemaVersion: 1, themeId: "com.example.management-ui",
            name: "Management UI", author: author, themeVersion: version, minimumAppVersion: "0.1.0",
            description: "Mounted management control fixture", preview: "preview.png",
            appearance: .init(supportedModes: [.light, .dark]),
            tokens: .init(light: fallback.light, dark: fallback.dark), metrics: fallback.metrics,
            resources: [:], hashes: ["preview.png": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()],
            animationPresets: ["none", "softFade"], sounds: nil, licenseOrSource: "Original test fixture",
            requiredCapabilities: [.init(name: "standard-theme", version: 1)], optionalCapabilities: [],
            panelProfile: "standard-panel@1", layoutProfile: "standard-layout@1", visualMask: nil, extensions: [:])
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("incomeclocktheme")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in [("manifest.json", try JSONEncoder().encode(manifest)), ("preview.png", png)] {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    func testHostedGeneralWorkPanelAndReadOnlyPagesOperateThroughNativeKeyboard() async throws {
        let repository = BusinessRecordRepositorySpy(settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
            notificationService: FakeNotificationService(authorization: .authorized))
        let panel = KeyboardPanelController()
        let environment = AppEnvironment(businessStore: store, panelController: panel, loginItemService: FakeLoginItemService())
        await environment.start()
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        defer { host.close() }
        try await host.navigateByKeyboard(to: "通用")
        try await host.activateByKeyboard(try await host.control(role: "AXCheckBox", label: "下班通知", scope: "settings-page-通用"))
        try await waitFor { store.notificationsEnabled }
        try await host.activateByKeyboard(try await host.control(role: "AXCheckBox", label: "皮肤提示音", scope: "settings-page-通用"))
        try await waitFor { environment.themeStore.soundsEnabled }
        let appearance = try await host.control(role: "AXRadioGroup", scope: "settings-page-通用")
        try await host.reachByTab(appearance)
        try await host.sendKey(code: 124, characters: "\u{f703}")
        try await host.sendKey(code: 49, characters: " ")
        try await waitFor { environment.themeStore.preferredAppearance == .light }
        // Applying an appearance can replace the native segmented control.
        // Reach its current instance through Tab before choosing the next mode.
        host.window.contentView?.layoutSubtreeIfNeeded()
        host.window.recalculateKeyViewLoop()
        try await host.reachByTab(try await host.control(role: "AXRadioGroup", scope: "settings-page-通用"))
        try await host.sendKey(code: 124, characters: "\u{f703}")
        try await host.sendKey(code: 49, characters: " ")
        try await waitFor { environment.themeStore.preferredAppearance == .dark }

        try await host.navigateByKeyboard(to: "面板与启动")
        for title in ["始终置顶", "锁定面板位置", "全屏应用时隐藏", "登录时启动"] {
            try await host.activateByKeyboard(try await host.control(role: "AXCheckBox", label: title, scope: "settings-page-面板与启动"))
            try await waitFor { !environment.loginItemController.isProcessing }
        }
        try await waitFor {
            !environment.panelPreferences.alwaysOnTop && environment.panelPreferences.lockPanelPosition &&
            !environment.panelPreferences.hideInFullScreen && environment.loginItemController.isEnabled
        }
        try await host.activateByKeyboard(try await host.button(label: "恢复默认面板位置", scope: "settings-page-面板与启动"))
        try await waitFor { panel.resetCount == 1 && !environment.isResettingPanelPlacement }

        try await host.navigateByKeyboard(to: "工作规则")
        let unchangedSave = try await host.button(label: "保存", scope: "settings-page-工作规则", enabled: false)
        XCTAssertTrue(host.help(unchangedSave).contains("尚未修改"))
        for (identifier, value) in [("settings-wage", "425.50"), ("settings-start", "09:30"), ("settings-end", "18:30")] {
            let field = try await host.element(identifier: identifier)
            try await host.reachByTab(field)
            try await host.sendKey(code: 0, characters: "a", modifiers: .command)
            for character in value { try await host.sendKey(code: 0, characters: String(character)) }
        }
        // Return invokes the real form default action while the final field has focus.
        try await host.sendKey(code: 36, characters: "\r")
        try await waitFor { store.settingsRecordForValidation?.dailyWageCents == 42_550 }
        XCTAssertEqual(store.settingsRecordForValidation?.workStartMinuteOfDay, 570)
        XCTAssertEqual(store.settingsRecordForValidation?.workEndMinuteOfDay, 1110)
        XCTAssertNil(store.todayRecordForValidation)

        try await host.navigateByKeyboard(to: "数据与隐私")
        let reset = try await host.button(label: "重置今日记录…", scope: "settings-page-数据与隐私", enabled: false)
        XCTAssertTrue(host.help(reset).contains("仅在今日记录需要恢复时"))
        for title in ["快捷键", "关于"] {
            try await host.navigateByKeyboard(to: title)
            XCTAssertTrue(host.actionableControls(scope: "settings-page-" + title).isEmpty,
                "These informational pages have no hidden actionable controls to omit from the keyboard inventory")
        }
    }

    func testHostedInstalledThemeControlsAndRecoveryResetAreKeyboardOperable() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ValidatedTheme.warmIslandFallback.manifest)) as? [String: Any])
        object["themeId"] = "com.example.keyboard-theme"
        object["name"] = "Keyboard Theme"
        object["isDefault"] = false
        let userTheme = ValidatedTheme(manifest: try JSONDecoder().decode(ThemeManifest.self,
            from: JSONSerialization.data(withJSONObject: object)), source: .installed(root: FileManager.default.temporaryDirectory))
        let themeRepository = KeyboardThemeRepository(theme: userTheme)
        let themes = ThemeStore(repository: EphemeralThemePreferencesRepository(), themeRepository: themeRepository)
        let settings = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
            today: .damaged(.init(kind: .today, issue: .decodingFailed, disposition: .requireTodayReset)))
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(), themeStore: themes)
        await environment.start()
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        defer { host.close() }
        try await host.navigateByKeyboard(to: "外观与皮肤")
        for id in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion, userTheme.id] {
            try await host.activateByKeyboard(try await host.element(identifier: "theme-preview-" + id))
            _ = try await host.element(identifier: "theme-details-preview")
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
        }
        try await host.activateByKeyboard(try await host.button(label: "使用此皮肤", scope: "theme-details-preview"))
        try await waitFor { themes.selectedTheme.id == userTheme.id }
        let used = try await host.button(label: "使用此皮肤", scope: "theme-details-preview", enabled: false)
        XCTAssertTrue(host.help(used).contains("正在使用此皮肤"))
        try await host.activateByKeyboard(try await host.button(label: "恢复默认皮肤", scope: "settings-page-外观与皮肤"))
        try await waitFor { themes.selectedTheme.id == BuiltinThemeID.warmIsland }
        let defaultReset = try await host.button(label: "恢复默认皮肤", scope: "settings-page-外观与皮肤", enabled: false)
        XCTAssertTrue(host.help(defaultReset).contains("正在使用默认皮肤"))
        let picker = try await host.control(role: "AXPopUpButton", scope: "settings-page-外观与皮肤")
        try await host.reachByTab(picker)
        try await host.sendKey(code: 49, characters: " ")
        try await host.sendKey(code: 125, characters: "\u{f701}")
        try await host.sendKey(code: 36, characters: "\r")
        try await waitFor { themes.preferredAppearance == .light }
        let sound = try await host.control(role: "AXCheckBox", scope: "settings-page-外观与皮肤")
        try await host.activateByKeyboard(sound)
        try await waitFor { themes.soundsEnabled }
        XCTAssertEqual(store.viewState?.state, .recoveryRequired)
        XCTAssertEqual(store.settingsRecordForValidation, settings)

        try await host.navigateByKeyboard(to: "数据与隐私")
        try await host.activateByKeyboard(try await host.button(label: "重置今日记录…", scope: "settings-page-数据与隐私"))
        _ = try await host.control(role: "AXButton", label: "确认重置")
        try await host.sendKey(code: 53, characters: "\u{1b}")
        try await waitFor { !host.containsControl(role: "AXButton", label: "确认重置") }
        XCTAssertEqual(store.viewState?.state, .recoveryRequired)
        XCTAssertEqual(store.settingsRecordForValidation, settings)
        try await host.activateByKeyboard(try await host.button(label: "重置今日记录…", scope: "settings-page-数据与隐私"))
        try await host.activateByKeyboard(try await host.control(role: "AXButton", label: "确认重置"))
        try await waitFor { store.viewState?.state == .ready }
        XCTAssertEqual(store.settingsRecordForValidation, settings)
        XCTAssertNil(store.todayRecordForValidation)
    }

    func testHostedThemePreviewEscapeDismissesDetailsAndRestoresCardFocusWithoutApplying() async throws {
        let themes = ThemeStore()
        await themes.restore()
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes) })
        defer { host.close() }
        let b = "theme-preview-" + BuiltinThemeID.windowCompanion
        let card = try await host.element(identifier: b)
        try host.focus(card)
        try host.press(card)
        _ = try await host.element(identifier: "theme-details-preview")
        XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
        try await host.sendKey(code: 53, characters: "\u{1b}")
        try await waitFor(onTimeout: { host.dumpAccessibility(reason: "Escape did not dismiss Theme details") }) {
            host.find(identifier: "theme-details-preview") == nil
        }
        let restoredCard = try await host.element(identifier: b)
        XCTAssertEqual(host.boolAttribute(restoredCard, "isAccessibilityFocused"), true)
        XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertTrue(host.window.isVisible, "Escape cancels the preview, not the Settings window")
    }

    func testHostedThemeUsePublishesVisibleToastOnceAndFailedUsePreservesSelection() async throws {
        let repository = SettingsThemePreferencesFailureInput()
        let themes = ThemeStore(repository: repository)
        await themes.restore()
        var announcements: [String] = []
        let toast = SettingsSuccessToastController(announce: { announcements.append($0) })
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes, successToast: toast) })
        defer { host.close() }
        try host.press(try await host.element(identifier: "theme-preview-" + BuiltinThemeID.windowCompanion))
        try host.press(try await host.button(label: "使用此皮肤", scope: "theme-details-preview"))
        try await waitFor { themes.selectedTheme.id == BuiltinThemeID.windowCompanion }
        let visibleToast = try await host.element(identifier: "settings-success-toast")
        XCTAssertTrue(host.text(visibleToast).contains("窗边搭子"))
        XCTAssertEqual(announcements, ["已切换为“窗边搭子”"])
        let currentUse = try await host.button(label: "使用此皮肤", scope: "theme-details-preview", enabled: false)
        XCTAssertEqual(host.boolAttribute(currentUse, "isAccessibilityEnabled"), false)
        XCTAssertTrue(host.help(currentUse).contains("正在使用此皮肤"))
        // A new operation dismisses the prior success before the failed commit.
        await repository.failNextSave()
        try host.press(try await host.element(identifier: "theme-preview-" + BuiltinThemeID.warmIsland))
        try host.press(try await host.button(label: "使用此皮肤", scope: "theme-details-preview"))
        try await waitFor { themes.viewState.error == .persistenceFailed }
        _ = try await host.element(containing: "皮肤偏好未保存，已保留原有外观和业务状态。")
        XCTAssertNil(host.find(identifier: "settings-success-toast"))
        XCTAssertEqual(announcements, ["已切换为“窗边搭子”"])
        XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.windowCompanion)
        let persisted = await repository.loadThemePreferences()
        guard case let .loaded(record, _) = persisted else { return XCTFail("Missing committed Theme preference") }
        XCTAssertEqual(record.selectedThemeId, BuiltinThemeID.windowCompanion)
    }

    func testSidebarSpaceDoesNotInterceptTextEntryOrAnotherKeyWindow() async throws {
        let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)),
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy())
        await environment.start()
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        defer { host.close() }
        let general = try await host.element(identifier: "settings-nav-通用")
        try await host.reachByTab(general)
        let panel = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 240, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 12, y: 30, width: 210, height: 24))
        panel.contentView?.addSubview(field)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        defer { panel.close() }
        try await host.sendKey(code: 49, characters: " ", target: panel)
        XCTAssertEqual(field.stringValue, " ")
        XCTAssertNotNil(host.find(identifier: "settings-page-工作规则"), "Space in another key window must not activate the background sidebar")
        panel.close()
        let wage = try await host.element(identifier: "settings-wage")
        try await host.reachByTab(wage)
        try await host.sendKey(code: 0, characters: "a", modifiers: .command)
        try await host.sendKey(code: 49, characters: " ")
        try await waitFor { host.text(wage).contains(" ") }
        XCTAssertTrue(host.text(wage).contains(" "), "Focused text entry must receive Space")
        XCTAssertNotNil(host.find(identifier: "settings-page-工作规则"))
    }

    func testHostedSevenPageNavigationAcceptsTabShiftTabAndSpaceWithDisabledReasons() async throws {
        let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
            settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current)),
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                                         loginItemService: FakeLoginItemService())
        await environment.start()
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        defer { host.close() }
        let general = try await host.element(identifier: "settings-nav-通用")
        try await host.reachByTab(general)
        try await host.sendKey(code: 49, characters: " ")
        _ = try await host.element(identifier: "settings-page-通用")
        for title in ["工作规则", "面板与启动", "外观与皮肤", "数据与隐私", "快捷键", "关于"] {
            let nav = try await host.element(identifier: "settings-nav-" + title)
            // Page replacement may put focus into a native form field. Verify
            // actual Tab reachability without assuming one Tab per sidebar row.
            try await host.reachByTab(nav)
            try await host.sendKey(code: 49, characters: " ")
            _ = try await host.element(identifier: "settings-page-" + title)
            if title == "工作规则" {
                let save = try await host.button(label: "保存", scope: "settings-page-工作规则")
                XCTAssertEqual(host.boolAttribute(save, "isAccessibilityEnabled"), false)
                XCTAssertTrue(host.help(save).contains("尚未修改"))
            }
            if title == "数据与隐私" {
                let reset = try await host.button(label: "重置今日记录…", scope: "settings-page-数据与隐私")
                XCTAssertEqual(host.boolAttribute(reset, "isAccessibilityEnabled"), false)
                XCTAssertTrue(host.help(reset).contains("仅在今日记录需要恢复时"))
            }
        }
        let previous = try await host.element(identifier: "settings-nav-快捷键")
        try await host.reachByTab(previous, backwards: true)
        try await host.sendKey(code: 49, characters: " ")
        _ = try await host.element(identifier: "settings-page-快捷键")
        // This asserts the sidebar route, not every control on every page.
    }

    func testHostedThemeEmptyAndValidationErrorSheetExposeNativeDismissal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClock-HostedTheme-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("invalid.incomeclocktheme")
        try Data("invalid zip fixture".utf8).write(to: package)
        let themes = ThemeStore(repository: EphemeralThemePreferencesRepository(),
                                themeRepository: ThemeRepositoryActor(applicationSupportRoot: root))
        await themes.restore()
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes) })
        defer { host.close() }
        _ = try await host.element(identifier: "themes-installed-empty")
        _ = try await host.element(identifier: "theme-preview-" + BuiltinThemeID.warmIsland)
        _ = try await host.element(identifier: "theme-preview-" + BuiltinThemeID.windowCompanion)
        // The real validator supplies the error; only file-chooser gesture is excluded.
        await themes.beginImport(from: package)
        try await waitFor { themes.importError != nil && !host.window.sheets.isEmpty }
        let sheet = try XCTUnwrap(host.window.sheets.first)
        _ = try await host.element(identifier: "theme-import-error", root: sheet)
        _ = try await host.element(containing: "无法导入此皮肤", root: sheet)
        XCTAssertNil(host.find(identifier: "theme-import-confirm", root: sheet))
        try await host.sendKey(code: 53, characters: "\u{1b}", target: sheet)
        try await waitFor { themes.importError == nil && host.window.sheets.isEmpty }
        XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertTrue(host.window.isVisible)
        // Retain the tiny isolated invalid fixture for failure diagnostics.
    }

    func testNamedSettingsCoreLabelsRenderAt120PercentWithResolvedFontsAndVisibleGlyphs() async throws {
        // This bounded method is an observation fixture. Successful collection
        // is not UI17.3 acceptance: any font-unexposed button requires review of
        // its original 1.0/1.2 raster pair for actual glyph growth and clipping.
        var metrics: [[String: Any]] = []
        var headlineWidths: [String: CGFloat] = [:]
        var nativeBaselines: [String: NSFont] = [:]
        var buttonFrames: [String: CGRect] = [:]
        var unexposedFonts: [String] = []
        var pngCount = 0
        var pngBytes = 0
        var collectionCompleted = false
        defer {
            let document: [String: Any] = [
                "schema": "stage9.named-core-paired-text-observation.v1",
                "state": collectionCompleted ? "OBSERVATIONS_COLLECTED_REVIEW_PENDING" : "PARTIAL_OBSERVATIONS",
                "acceptance": "Not assigned by this fixture. Original raster glyph growth/full glyphs/no clipping require independent review where AX font is unavailable.",
                "unexposedFonts": unexposedFonts, "originalPngCount": pngCount,
                "originalPngBytes": pngBytes, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "date": ISO8601DateFormatter().string(from: Date()), "records": metrics
            ]
            if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), data.count <= 131_072 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Stage9-Named-Settings-Core-Text-Scale-Metrics"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Bounded paired text metrics could not be serialized within the declared 128KiB budget") }
        }
        func object(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func nodes(_ root: NSObject) -> [NSObject] {
            var pending = [root]
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            while let node = pending.popLast(), result.count < 1_024 {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                result.append(node)
                pending += object(node, "accessibilityChildren") as? [NSObject] ?? (node as? NSView)?.subviews ?? []
            }
            return result
        }
        func glyphBounds(_ text: String, _ font: NSFont) -> CGRect {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        }
        func observeHeadline(_ title: String, root: NSWindow, scale: CGFloat) async throws {
            var text: NSObject?
            try await self.waitFor {
                let matches = nodes(root).filter { node in
                    object(node, "accessibilityRole") as? String == "AXStaticText" &&
                    ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { object(node, $0) as? String == title }
                }
                guard matches.count == 1 else { return false }
                text = matches[0]
                return true
            }
            let node = try XCTUnwrap(text)
            let rect = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let font = SettingsCoreTextMetrics.font(.errorHeadline, scale: scale)
            let original = NSFont.preferredFont(forTextStyle: .headline, options: [:])
            XCTAssertEqual(font.fontDescriptor.symbolicTraits, original.fontDescriptor.symbolicTraits)
            XCTAssertEqual(font.pointSize, original.pointSize * scale, accuracy: 0.01)
            let ink = glyphBounds(title, font)
            XCTAssertGreaterThanOrEqual(rect.width + 1, ink.width)
            XCTAssertGreaterThanOrEqual(rect.height + 1, ink.height)
            let visibleView = try XCTUnwrap(root.contentView)
            let visibleAXFrame = NSAccessibility.screenRect(fromView: visibleView, rect: visibleView.bounds)
            XCTAssertTrue(visibleAXFrame.insetBy(dx: -1, dy: -1).contains(rect), "Actual title AX frame must be within the rendered content")
            if scale == 1 { headlineWidths[title] = rect.width }
            else {
                let baselineWidth = try XCTUnwrap(headlineWidths[title])
                XCTAssertEqual(rect.width / baselineWidth, 1.2, accuracy: 0.035,
                    "Actual mounted text geometry must grow; injected environment alone is not evidence")
            }
            metrics.append(["label": title, "scale": scale, "resolvedFont": font.fontName,
                "pointSize": font.pointSize, "traits": font.fontDescriptor.symbolicTraits.rawValue,
                "actualAXFrame": NSStringFromRect(rect), "glyphInk": NSStringFromRect(ink),
                "baseline": "NSFont.preferredFont(.headline), preserving descriptor traits"])
        }
        func attributedTitle(_ node: NSObject, label: String) -> NSAttributedString? {
            let selector = NSSelectorFromString("accessibilityAttributedStringForRange:")
            guard node.responds(to: selector) else { return nil }
            // Public NSAccessibility protocol method: the range is an NSRange
            // value, not an Objective-C boxed argument to NSObject.perform.
            typealias Getter = @convention(c) (AnyObject, Selector, NSRange) -> Unmanaged<AnyObject>?
            let getter = unsafeBitCast(node.method(for: selector), to: Getter.self)
            return getter(node, selector, NSRange(location: 0, length: (label as NSString).length))?.takeUnretainedValue() as? NSAttributedString
        }
        func fontInAXText(_ value: NSAttributedString) -> NSFont? {
            guard value.length > 0 else { return nil }
            // AX attributed text uses the documented AXFont dictionary, not
            // necessarily AppKit's NSAttributedString.Key.font.
            if let font = value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return font }
            let key = NSAttributedString.Key(rawValue: kAXFontTextAttribute.takeUnretainedValue() as String)
            guard let descriptor = value.attribute(key, at: 0, effectiveRange: nil) as? NSDictionary,
                  let name = descriptor[kAXFontNameKey.takeUnretainedValue() as String] as? String,
                  let size = descriptor[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber else { return nil }
            return NSFont(name: name, size: CGFloat(size.doubleValue))
        }
        func observeButton(_ label: String, id: String, root: NSWindow, scale: CGFloat, enabled: Bool) async throws {
            let content = try XCTUnwrap(root.contentView)
            let identifier = id.hasPrefix("save-") ? "settings-save" : "theme-import-confirm"
            var resolved: NSObject?
            try await self.waitFor {
                let matches = nodes(root).filter { node in
                    object(node, "accessibilityRole") as? String == "AXButton" &&
                    object(node, "accessibilityIdentifier") as? String == identifier &&
                    ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { object(node, $0) as? String == label }
                }
                guard matches.count == 1 else { return false }
                resolved = matches[0]
                return true
            }
            let button = try XCTUnwrap(resolved)
            guard button.responds(to: NSSelectorFromString("accessibilityFrame")) else {
                XCTFail("The actual named AXButton must expose its rendered frame")
                throw HostedSettingsFailure.observationTimedOut
            }
            let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let visible = NSAccessibility.screenRect(fromView: content, rect: content.bounds)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame), "The named rendered control must fit the original captured content")
            XCTAssertTrue(button.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
            guard button.responds(to: enabledSelector) else {
                XCTFail("Actual AXButton must expose its enabled state")
                throw HostedSettingsFailure.observationTimedOut
            }
            typealias EnabledGetter = @convention(c) (AnyObject, Selector) -> Bool
            let isEnabled = unsafeBitCast(button.method(for: enabledSelector), to: EnabledGetter.self)(button, enabledSelector)
            XCTAssertEqual(isEnabled, enabled)
            var record: [String: Any] = ["label": label, "id": id, "scale": scale,
                "actualAXClass": String(describing: type(of: button)), "actualAXFrame": NSStringFromRect(frame),
                "contentAXFrame": NSStringFromRect(visible), "enabled": isEnabled,
                "geometryScope": "Actual AXButton bounds, not an inferred glyph box. Paired original pixels carry glyph growth/clipping evidence.",
                "action": "Public AXPress remains exposed; Save is exercised below and import actions have separate accepted tests."]
            if scale == 1 { buttonFrames[id] = frame }
            else if let baseline = buttonFrames[id] {
                record["controlWidthRatio"] = frame.width / baseline.width
                record["controlHeightRatio"] = frame.height / baseline.height
                // Native padding need not scale. Do not label the whole control
                // ratio as the font or glyph-size ratio.
            }
            let attributedCandidates = nodes(button).compactMap { attributedTitle($0, label: label) }
                .filter { $0.string == label }
            let observed = attributedCandidates.compactMap(fontInAXText)
            if let font = observed.first {
                let predicted = SettingsCoreTextMetrics.font(.nativePrimary, scale: scale)
                XCTAssertEqual(font.pointSize, predicted.pointSize, accuracy: 0.01)
                let ink = glyphBounds(label, font)
                XCTAssertGreaterThanOrEqual(frame.width + 1, ink.width)
                XCTAssertGreaterThanOrEqual(frame.height + 1, ink.height)
                record["actualAXFirstRunFont"] = font.fontName
                record["actualAXPointSize"] = font.pointSize
                record["actualAXTraits"] = font.fontDescriptor.symbolicTraits.rawValue
                record["glyphInkFromObservedFont"] = NSStringFromRect(ink)
                record["fontEvidence"] = "Public AX attributed text; CoreText ink uses the observed font, not the requested font."
                if scale == 1 { nativeBaselines[id] = font }
                else if let baseline = nativeBaselines[id] {
                    XCTAssertEqual(font.pointSize / baseline.pointSize, 1.2, accuracy: 0.005)
                    XCTAssertEqual(font.fontDescriptor.symbolicTraits, baseline.fontDescriptor.symbolicTraits)
                    XCTAssertEqual(font.familyName, baseline.familyName)
                    record["actualAXFontRatio"] = font.pointSize / baseline.pointSize
                } else { record["fontRatio"] = "Baseline font was not exposed; use original raster pair." }
            } else {
                unexposedFonts.append("\(id)@\(scale)")
                record["fontEvidence"] = "PUBLIC_AX_FONT_UNAVAILABLE; no font/glyph ratio assertion is made from requested values. Continue collecting both original rasters for independent glyph measurement."
                record["attributedSelectors"] = nodes(button).map {
                    "\(type(of: $0)):\($0.responds(to: NSSelectorFromString("accessibilityAttributedStringForRange:")))"
                }
            }
            metrics.append(record)
        }
        func capture(_ window: NSWindow, name: String, pair: String, scale: CGFloat) throws {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            guard data.count <= 2 * 1_024 * 1_024, pngCount < 6, pngBytes + data.count <= 12 * 1_024 * 1_024 else {
                XCTFail("Bounded original screenshot budget exceeded; do not attach this raster")
                throw HostedSettingsFailure.observationTimedOut
            }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            pngCount += 1
            pngBytes += data.count
            metrics.append(["png": name, "pair": pair, "scale": scale, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "points": [view.bounds.width, view.bounds.height],
                "colorSpace": bitmap.colorSpace.localizedName ?? "unknown",
                "contentAXFrame": NSStringFromRect(NSAccessibility.screenRect(fromView: view, rect: view.bounds)),
                "contentIsFlipped": view.isFlipped, "backingScale": window.backingScaleFactor,
                "appearance": window.effectiveAppearance.name.rawValue,
                "review": "Compare this original image with the matching pair/other scale. Measure actual glyphs and inspect full labels/clipping; neither canvas nor button frame ratio is a glyph ratio.",
                "producer": "Original mounted NSHostingView cacheDisplay PNG; embedded ICC unchanged, no resize or compositor claim"])
        }

        for scale: CGFloat in [1, 1.2] {
            let repository = BusinessRecordRepositorySpy(settings: .damaged(.init(kind: .settings,
                issue: .decodingFailed, disposition: .requireSettingsRecovery)), today: .missing)
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await store.restore()
            let host = HostedSettings(ScrollView { WorkRulesSettingsView(businessStore: store).padding(20) }
                .environment(\.incomePanelTextScale, scale).preferredColorScheme(.light))
            host.window.appearance = NSAppearance(named: .aqua)
            host.window.setContentSize(NSSize(width: 680, height: 500))
            defer { host.close() }
            let wage = try await host.element(identifier: "settings-wage")
            try await host.reachByTab(wage)
            for character in "300" { try await host.sendKey(code: 0, characters: String(character)) }
            let save = try await host.element(identifier: "settings-save")
            try await waitFor { host.boolAttribute(save, "isAccessibilityEnabled") == true }
            try await observeHeadline("设置数据无法读取", root: host.window, scale: scale)
            try await observeButton("确认替换设置", id: "save-idle", root: host.window, scale: scale, enabled: true)
            try capture(host.window, name: "Named-Core-\(Int((scale * 100).rounded()))-WorkRules-Error-Save", pair: "WorkRules-Error-Save", scale: scale)
            await repository.holdNextSettingsSave()
            defer { Task { await repository.resumeHeldSettingsSave() } }
            try host.press(save)
            try await waitFor { if case .saving = store.commandPhase { return true }; return false }
            try await observeButton("正在保存…", id: "save-busy", root: host.window, scale: scale, enabled: false)
            await repository.resumeHeldSettingsSave()
            try await waitFor { !store.isCommandInFlight }
            let today = await repository.currentToday()
            XCTAssertNil(today)
            host.close()

            let root = try ApplicationTestSupport.makeTemporaryRoot()
            let themes = ThemeStore(repository: EphemeralThemePreferencesRepository(),
                themeRepository: ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0"))
            await themes.restore()
            let themeHost = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes) }
                .environment(\.incomePanelTextScale, scale).preferredColorScheme(.light))
            themeHost.window.appearance = NSAppearance(named: .aqua)
            themeHost.window.setContentSize(NSSize(width: 680, height: 500))
            defer { themeHost.close() }
            _ = try await themeHost.element(identifier: "themes-installed-empty")
            let invalid = root.appendingPathComponent("invalid.incomeclocktheme")
            try Data("invalid zip fixture".utf8).write(to: invalid, options: .withoutOverwriting)
            await themes.beginImport(from: invalid)
            try await waitFor { themes.importError != nil && themeHost.window.attachedSheet != nil }
            let errorSheet = try XCTUnwrap(themeHost.window.attachedSheet)
            try await observeHeadline("无法导入此皮肤", root: errorSheet, scale: scale)
            try capture(errorSheet, name: "Named-Core-\(Int((scale * 100).rounded()))-Theme-Import-Error", pair: "Theme-Import-Error", scale: scale)
            try themeHost.press(try await themeHost.button(label: "关闭", scope: "theme-import-error", root: errorSheet))
            try await waitFor { themes.importError == nil && themeHost.window.attachedSheet == nil }
            let package = try managementThemePackage(in: root, version: "1.0.0")
            await themes.beginImport(from: package)
            try await waitFor { themes.importCandidate != nil && themeHost.window.attachedSheet != nil }
            let previewSheet = try XCTUnwrap(themeHost.window.attachedSheet)
            _ = try await themeHost.element(identifier: "theme-import-confirm", root: previewSheet)
            try await observeButton("安装皮肤", id: "import-idle", root: previewSheet, scale: scale, enabled: true)
            try capture(previewSheet, name: "Named-Core-\(Int((scale * 100).rounded()))-Theme-Import-Primary", pair: "Theme-Import-Primary", scale: scale)
            try themeHost.press(try await themeHost.element(identifier: "theme-import-cancel", root: previewSheet))
            try await waitFor { themes.importCandidate == nil && themeHost.window.attachedSheet == nil }
            XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
            themeHost.close()
        }
        XCTAssertEqual(pngCount, 6, "Exactly three named 1.0/1.2 pairs; no all-page matrix")
        collectionCompleted = pngCount == 6
    }


    func testNamedSettingsPrimaryIdleBusyAndImportScalePairsPreserveNativeActions() async throws {
        // Collection is not acceptance: independent original-pixel review must
        // establish glyph growth/full labels/clipping and focused appearance.
        // A rendering transform leaves intrinsic AX font size unchanged.
        var records: [[String: Any]] = []
        var count = 0, bytes = 0
        var complete = false
        defer {
            let report: [String: Any] = [
                "schema": "stage9.native-primary-render-scale-pairs.v1",
                "state": complete ? "OBSERVATIONS_COLLECTED_REVIEW_PENDING" : "PARTIAL_OBSERVATIONS",
                "acceptance": "Independent raster glyph and clipping review pending; not asserted from scale/font requests.",
                "date": ISO8601DateFormatter().string(from: Date()),
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "pngCount": count, "pngBytes": bytes, "records": records
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), data.count <= 131_072 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Stage9-Native-Primary-Scale-Metrics"
                attachment.lifetime = .keepAlways; add(attachment)
            } else { XCTFail("Primary metrics exceeded 128KiB pre-attachment cap") }
        }
        func observe(_ host: HostedSettings, _ window: NSWindow, id: String, label: String,
                     scale: CGFloat, enabled: Bool) async throws -> CGRect {
            let button = try await host.element(identifier: id, root: window)
            XCTAssertEqual(button.perform(NSSelectorFromString("accessibilityRole"))?.takeUnretainedValue() as? String, "AXButton")
            XCTAssertEqual(host.text(button), label)
            XCTAssertEqual(host.boolAttribute(button, "isAccessibilityEnabled"), enabled)
            XCTAssertTrue(button.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let content = try XCTUnwrap(window.contentView)
            let visible = NSAccessibility.screenRect(fromView: content, rect: content.bounds)
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame))
            records.append(["id": id, "label": label, "scale": scale, "enabled": enabled,
                "actualAXClass": String(describing: type(of: button)), "actualAXFrame": NSStringFromRect(frame),
                "contentAXFrame": NSStringFromRect(visible),
                "focused": host.hasKeyboardFocus(button),
                "fontScope": "No intrinsic AX-font ratio assertion: native transform scales rendered pixels."])
            return frame
        }
        func capture(_ window: NSWindow, pair: String, scale: CGFloat) throws {
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            guard count < 6, png.count <= 2 * 1_024 * 1_024, bytes + png.count <= 12 * 1_024 * 1_024 else {
                XCTFail("Primary raster cap exceeded before attachment")
                throw HostedSettingsFailure.observationTimedOut
            }
            let name = "Native-Primary-\(Int((scale * 100).rounded()))-\(pair)"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            count += 1; bytes += png.count
            records.append(["png": name, "pair": pair, "scale": scale,
                "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
                "points": [content.bounds.width, content.bounds.height],
                "contentAXFrame": NSStringFromRect(NSAccessibility.screenRect(fromView: content, rect: content.bounds)),
                "contentIsFlipped": content.isFlipped, "backingScale": window.backingScaleFactor,
                "appearance": window.effectiveAppearance.name.rawValue,
                "colorSpace": bitmap.colorSpace.localizedName ?? "unknown",
                "producer": "Original NSHostingView cacheDisplay PNG; embedded ICC unchanged; no post-render scaling/compositor claim"])
        }
        func clickVisibleCenter(_ frame: CGRect, window: NSWindow) throws {
            // In-process NSAccessibility uses AppKit bottom-left screen
            // coordinates (NSAccessibility.h), unlike external AXUIElement APIs.
            let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.postEvent(event, atStart: false)
            }
        }
        for scale: CGFloat in [1, 1.2] {
            let repository = BusinessRecordRepositorySpy(settings: .damaged(.init(kind: .settings,
                issue: .decodingFailed, disposition: .requireSettingsRecovery)), today: .missing)
            let business = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await business.restore()
            let host = HostedSettings(ScrollView { WorkRulesSettingsView(businessStore: business).padding(20) }
                .environment(\.incomePanelTextScale, scale).preferredColorScheme(.light))
            host.window.appearance = NSAppearance(named: .aqua)
            host.window.setContentSize(NSSize(width: 680, height: 500))
            defer { host.close() }
            let wage = try await host.element(identifier: "settings-wage")
            try await host.reachByTab(wage)
            for character in "300" { try await host.sendKey(code: 0, characters: String(character)) }
            let save = try await host.element(identifier: "settings-save")
            try await waitFor { host.boolAttribute(save, "isAccessibilityEnabled") == true }
            try await host.reachByTab(save)
            XCTAssertTrue(host.hasKeyboardFocus(save))
            _ = try await observe(host, host.window, id: "settings-save", label: "确认替换设置", scale: scale, enabled: true)
            try capture(host.window, pair: "Save-idle-focused", scale: scale)
            await repository.holdNextSettingsSave()
            defer { Task { await repository.resumeHeldSettingsSave() } }
            // Native Return must still reach the original default action.
            try await host.sendKey(code: 36, characters: "\r")
            try await waitFor { if case .saving = business.commandPhase { return true }; return false }
            let busyFrame = try await observe(host, host.window, id: "settings-save", label: "正在保存…", scale: scale, enabled: false)
            try capture(host.window, pair: "Save-busy-disabled", scale: scale)
            let heldCount = await repository.settingsSaveCount
            try clickVisibleCenter(busyFrame, window: host.window)
            try await host.sendKey(code: 36, characters: "\r")
            try await Task.sleep(nanoseconds: 100_000_000)
            let stillHeldCount = await repository.settingsSaveCount
            XCTAssertEqual(stillHeldCount, heldCount, "Disabled transformed button cannot reenter Save")
            XCTAssertTrue(business.isCommandInFlight)
            await repository.resumeHeldSettingsSave()
            try await waitFor { !business.isCommandInFlight }
            XCTAssertEqual(business.currentWorkRules?.dailyWageCents, 30_000)
            let today = await repository.currentToday()
            XCTAssertNil(today)
            host.close()

            let root = try ApplicationTestSupport.makeResume008FixtureRoot(
                name: "primary-\(Int((scale * 100).rounded()))", reservedGrowthBytes: 1_024 * 1_024,
                familyName: "Resume009PrimaryFixtures")
            let themes = ThemeStore(repository: EphemeralThemePreferencesRepository(),
                themeRepository: ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0"))
            await themes.restore()
            let themeHost = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: themes) }
                .environment(\.incomePanelTextScale, scale).preferredColorScheme(.light))
            themeHost.window.appearance = NSAppearance(named: .aqua)
            themeHost.window.setContentSize(NSSize(width: 680, height: 500))
            defer { themeHost.close() }
            _ = try await themeHost.element(identifier: "themes-installed-empty")
            let package = try managementThemePackage(in: root, version: "1.0.0")
            let packageSize = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard packageSize <= 64 * 1_024 else { throw HostedSettingsFailure.observationTimedOut }
            await themes.beginImport(from: package)
            try await waitFor { themes.importCandidate != nil && themeHost.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(themeHost.window.attachedSheet)
            let expectedID = try XCTUnwrap(themes.importCandidate?.manifest.themeId)
            let frame = try await observe(themeHost, sheet, id: "theme-import-confirm", label: "安装皮肤", scale: scale, enabled: true)
            try capture(sheet, pair: "Import-idle", scale: scale)
            // Use the observed rendered button center, never a direct store call,
            // to verify the scaled visible target still performs its native action.
            sheet.makeKeyAndOrderFront(nil)
            try await waitFor { sheet.isKeyWindow }
            try clickVisibleCenter(frame, window: sheet)
            try await waitFor { themes.lastInstalledThemeID == expectedID && themes.importCandidate == nil }
            XCTAssertNil(themes.importError)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Themes/" + expectedID).path))
            let todayAfterImport = await repository.currentToday()
            XCTAssertNil(todayAfterImport)
            records.append(["scale": scale, "actions": "Native Tab focus and Return Save; held disabled click/Return no reentry; rendered-center native mouse import committed isolated theme."])
            themeHost.close()
        }
        XCTAssertEqual(count, 6)
        complete = count == 6
    }

    private func waitFor(onTimeout: (() -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        onTimeout?()
        XCTFail("Expected production view observation did not arrive", file: file, line: line)
        throw HostedSettingsFailure.observationTimedOut
    }
}

private enum HostedSettingsFailure: Error {
    case observationTimedOut
    case missingAccessibilityAction(String)
}

@MainActor
final class HostedSettings {
    let window: NSWindow

    init<Content: View>(_ content: Content) {
        window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 760, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stage9 isolated hosted Settings"
        let view = NSHostingView(rootView: content)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
    }

    func close() { window.close() }

    /// AppKit's public accessibility getters are queried in-process. Dynamic
    /// dispatch accommodates SwiftUI's private concrete AX element classes,
    /// without reading private fields or replacing production action handlers.
    private func object(_ element: NSObject, _ attribute: String) -> Any? {
        let selector = NSSelectorFromString(attribute)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func elements(root: NSObject? = nil) -> [NSObject] {
        var pending = [root ?? window]
        var visited = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        while let next = pending.popLast(), result.count < 1_024 {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            if let children = object(next, "accessibilityChildren") as? [NSObject] {
                pending.append(contentsOf: children.reversed())
            }
        }
        return result
    }

    func find(identifier: String, root: NSObject? = nil) -> NSObject? {
        elements(root: root).first { object($0, "accessibilityIdentifier") as? String == identifier }
    }

    func text(_ element: NSObject) -> String {
        ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap {
            object(element, $0) as? String
        }.joined(separator: " ")
    }

    func help(_ element: NSObject) -> String { object(element, "accessibilityHelp") as? String ?? "" }

    func boolAttribute(_ element: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let get = unsafeBitCast(element.method(for: selector), to: Getter.self)
        return get(element, selector)
    }

    func element(identifier: String, root: NSObject? = nil) async throws -> NSObject {
        try await waitElement("identifier=" + identifier, root: root) { self.find(identifier: identifier, root: root) }
    }

    func element(containing label: String, root: NSObject? = nil) async throws -> NSObject {
        try await waitElement("containing=" + label, root: root) { self.elements(root: root).first { self.text($0).contains(label) } }
    }

    func button(label: String, scope: String, root: NSObject? = nil, enabled: Bool? = nil) async throws -> NSObject {
        try await waitElement("AXButton label=" + label + " scope=" + scope, root: root) {
            // SwiftUI may expose the scope as a containing AXGroup or inherit
            // its identifier on leaf nodes. Search only those scoped roots and
            // their descendants; never resolve a same-label button elsewhere.
            let scopedRoots = self.elements(root: root).filter {
                self.object($0, "accessibilityIdentifier") as? String == scope
            }
            var seen = Set<ObjectIdentifier>()
            let scopedElements = scopedRoots.flatMap { self.elements(root: $0) }.filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }
            let matches = scopedElements.filter {
                self.object($0, "accessibilityRole") as? String == "AXButton" &&
                self.object($0, "accessibilityLabel") as? String == label &&
                (enabled == nil || self.boolAttribute($0, "isAccessibilityEnabled") == enabled)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func scopedElements(_ scope: String?) -> [NSObject] {
        guard let scope else {
            var seen = Set<ObjectIdentifier>()
            return ([window] + window.sheets).flatMap { elements(root: $0) }
                .filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        let roots = elements().filter { object($0, "accessibilityIdentifier") as? String == scope }
        var seen = Set<ObjectIdentifier>()
        return roots.flatMap { elements(root: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func control(role: String, label: String? = nil, scope: String? = nil) async throws -> NSObject {
        try await waitElement("role=\(role) label=\(label ?? "<unique>") scope=\(scope ?? "window")") {
            let matches = self.scopedElements(scope).filter {
                self.object($0, "accessibilityRole") as? String == role &&
                (label == nil || self.object($0, "accessibilityLabel") as? String == label)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    func actionableControls(scope: String) -> [NSObject] {
        let roles = Set(["AXButton", "AXCheckBox", "AXRadioGroup", "AXPopUpButton", "AXTextField"])
        return scopedElements(scope).filter { roles.contains(object($0, "accessibilityRole") as? String ?? "") }
    }

    func containsText(_ fragment: String, root: NSObject? = nil) -> Bool {
        elements(root: root).contains { text($0).contains(fragment) }
    }

    func containsControl(role: String, label: String) -> Bool {
        scopedElements(nil).contains {
            object($0, "accessibilityRole") as? String == role &&
            object($0, "accessibilityLabel") as? String == label
        }
    }

    func hasKeyboardFocus(_ target: NSObject) -> Bool {
        // FocusState updates can replace SwiftUI AX nodes. Resolve the same
        // uniquely identified control in the current tree before observing focus.
        let identifier = object(target, "accessibilityIdentifier") as? String ?? ""
        let role = object(target, "accessibilityRole") as? String
        let label = object(target, "accessibilityLabel") as? String
        let current = elements().filter {
            object($0, "accessibilityRole") as? String == role &&
            (identifier.isEmpty
                ? object($0, "accessibilityLabel") as? String == label
                : object($0, "accessibilityIdentifier") as? String == identifier)
        }
        guard current.count == 1, let control = current.first else { return false }
        return elements(root: control).contains { boolAttribute($0, "isAccessibilityFocused") == true }
    }

    /// No AX focus setter: every target must be reached by native Tab traversal.
    func reachByTab(_ target: NSObject, backwards: Bool = false) async throws {
        for _ in 0..<48 {
            if hasKeyboardFocus(target) { return }
            try await sendKey(code: 48, characters: "\t", modifiers: backwards ? .shift : [])
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        dumpAccessibility(reason: "Tab could not reach \(text(target))")
        XCTFail("Native Tab traversal did not reach the requested actionable control")
        throw HostedSettingsFailure.observationTimedOut
    }

    func activateByKeyboard(_ target: NSObject) async throws {
        try await reachByTab(target)
        XCTAssertEqual(boolAttribute(target, "isAccessibilityEnabled"), true)
        try await sendKey(code: 49, characters: " ")
    }

    func navigateByKeyboard(to title: String) async throws {
        try await activateByKeyboard(try await element(identifier: "settings-nav-" + title))
        _ = try await element(identifier: "settings-page-" + title)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func element(exactLabel label: String) async throws -> NSObject {
        try await waitElement("exactLabel=" + label) { self.elements().first { self.object($0, "accessibilityLabel") as? String == label } }
    }

    private func waitElement(_ description: String, root: NSObject? = nil, _ lookup: () -> NSObject?) async throws -> NSObject {
        try await Stage9EnableHostedAccessibility()
        for _ in 0..<100 {
            if let element = lookup() { return element }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        dumpAccessibility(reason: "Missing " + description, root: root)
        XCTFail("Expected native accessibility element is absent: " + description)
        throw HostedSettingsFailure.observationTimedOut
    }

    func dumpAccessibility(reason: String, root: NSObject? = nil) {
        let rows = elements(root: root).enumerated().map { index, element in
            let identifier = object(element, "accessibilityIdentifier") as? String ?? ""
            let role = object(element, "accessibilityRole") as? String ?? ""
            return "\(index) \(type(of: element)) role=\(role) id=\(identifier) text=\(text(element)) help=\(help(element)) enabled=\(String(describing: boolAttribute(element, "isAccessibilityEnabled"))) focused=\(String(describing: boolAttribute(element, "isAccessibilityFocused")))"
        }
        let dump = "\(reason)\nkey=\(window.isKeyWindow) main=\(window.isMainWindow) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) firstResponder=\(String(describing: window.firstResponder))\n" + rows.joined(separator: "\n")
        print("STAGE9_HOSTED_AX_DUMP\n" + dump)
        let attachment = XCTAttachment(string: dump)
        attachment.name = reason
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: reason) { $0.add(attachment) }
    }

    func press(_ element: NSObject, file: StaticString = #filePath, line: UInt = #line) throws {
        // AppKit confirmation dialogs expose their NSButtonCell in the AX tree.
        // The cell is not the action-owning control; invoking its AX selector can
        // dismiss the alert while returning false. Resolve its actual button
        // before dispatch, so this path executes exactly one native action.
        if let cell = element as? NSButtonCell {
            let button = try XCTUnwrap(cell.controlView as? NSButton,
                "Native alert cell must belong to an NSButton", file: file, line: line)
            XCTAssertTrue(button.cell === cell, "Resolved button must own the selected cell", file: file, line: line)
            guard button.cell === cell else { throw HostedSettingsFailure.missingAccessibilityAction("cell owner") }
            XCTAssertTrue(button.isEnabled, "Native alert button must be enabled", file: file, line: line)
            guard button.isEnabled else { throw HostedSettingsFailure.missingAccessibilityAction("disabled button") }
            let action = try XCTUnwrap(button.action,
                "Native alert button must have its production action", file: file, line: line)
            let accepted = button.sendAction(action, to: button.target)
            XCTAssertTrue(accepted, "Native NSButton must dispatch its production action", file: file, line: line)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { throw HostedSettingsFailure.missingAccessibilityAction("press") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let invoke = unsafeBitCast(element.method(for: selector), to: Action.self)
        let actionDescription = "\(type(of: element)) id=\(object(element, "accessibilityIdentifier") as? String ?? "") text=\(text(element))"
        let accepted = invoke(element, selector)
        if !accepted { dumpAccessibility(reason: "AX press returned false: " + actionDescription) }
        XCTAssertTrue(accepted, "Native AX press must invoke the actual production button: " + actionDescription, file: file, line: line)
    }

    func focus(_ element: NSObject) throws {
        let selector = NSSelectorFromString("setAccessibilityFocused:")
        guard element.responds(to: selector) else { throw HostedSettingsFailure.missingAccessibilityAction("focus") }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let set = unsafeBitCast(element.method(for: selector), to: Setter.self)
        set(element, selector, true)
    }

    func sendKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], target: NSWindow? = nil) async throws {
        let recipient = target ?? window.attachedSheet ?? window
        NSApp.activate(ignoringOtherApps: true)
        recipient.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if recipient.isKeyWindow { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard recipient.isKeyWindow else {
            dumpAccessibility(reason: "Native keyboard target did not become key", root: recipient)
            throw HostedSettingsFailure.observationTimedOut
        }
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: recipient.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return XCTFail("Cannot construct native key event") }
        // Queue the complete native down/up pair before the event loop handles
        // controls that may enter tracking (checkboxes and popup menus).
        NSApp.postEvent(event, atStart: false)
        }
    }
}

@MainActor
private final class KeyboardPanelController: PanelControlling {
    private let base = PanelControllerSpy()
    private(set) var resetCount = 0
    func restore() async -> Bool { await base.restore() }
    func show(persist: Bool, focus: Bool) { base.show(persist: persist, focus: focus) }
    func hide(persist: Bool) { base.hide(persist: persist) }
    func runtimePreferences() -> PanelRuntimePreferences { base.runtimePreferences() }
    func resetToDefaultPlacement() async -> Bool { resetCount += 1; return true }
    func setAlwaysOnTop(_ value: Bool) async -> Bool { await base.setAlwaysOnTop(value) }
    func setLockPanelPosition(_ value: Bool) async -> Bool { await base.setLockPanelPosition(value) }
    func setHideInFullScreen(_ value: Bool) async -> Bool { await base.setHideInFullScreen(value) }
    func setVisibilityChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void) { base.setVisibilityChangeHandler(handler) }
}

private actor KeyboardThemeRepository: ThemeRepositoryProviding {
    let theme: ValidatedTheme
    init(theme: ValidatedTheme) { self.theme = theme }
    func loadInstalledThemes() async -> ThemeRepositorySnapshot { .init(themes: [theme], disabledThemes: []) }
    func validatePackage(at sourceURL: URL, progress: @escaping @Sendable (ThemeImportProgress) -> Void) async throws -> ThemeImportCandidate {
        throw ThemeImportError.stagingFailed
    }
    func install(_ candidate: ThemeImportCandidate) async throws -> ValidatedTheme { throw ThemeImportError.installFailed }
    func discard(_ candidate: ThemeImportCandidate) async {}
    func deleteTheme(id: String) async throws { throw ThemeImportError.deleteFailed }
}

private actor SettingsThemePreferencesFailureInput: ThemePreferencesRepository {
    private let base = EphemeralThemePreferencesRepository()
    private var shouldFail = false
    func failNextSave() { shouldFail = true }
    func loadThemePreferences() async -> RecordLoadResult<ThemePreferencesRecord> { await base.loadThemePreferences() }
    func saveThemePreferences(_ proposed: ThemePreferencesRecord, expectedRevision: RecordRevision?) async throws -> ThemePreferencesRecord {
        if shouldFail { shouldFail = false; throw PersistenceError.atomicWriteFailed }
        return try await base.saveThemePreferences(proposed, expectedRevision: expectedRevision)
    }
    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) async throws -> ThemePreferencesRecord {
        try await base.recoverThemePreferences(proposed)
    }
}

/// Start a real accessibility client request to this test host only. SwiftUI
/// lazily creates AccessibilityNode children after a client reads the app.
/// This never prompts for permission or reads another application's UI.
@MainActor
func Stage9EnableHostedAccessibility() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global().async {
            let ownApplication = AXUIElementCreateApplication(getpid())
            var children: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(ownApplication, kAXChildrenAttribute as CFString, &children)
            if result == .success { continuation.resume() }
            else { continuation.resume(throwing: NSError(domain: "Stage9SelfAccessibility", code: Int(result.rawValue))) }
        }
    }
}
