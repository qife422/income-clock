import AppKit
import CryptoKit
import Darwin
import XCTest

final class ShortcutUITests: XCTestCase {
    private var isRecordingFailureTree = false
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func record(_ issue: XCTIssue) {
        let app = XCUIApplication()
        if !isRecordingFailureTree && (app.state == .runningForeground || app.state == .runningBackground) {
            isRecordingFailureTree = true
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Stage9 failure accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            isRecordingFailureTree = false
        }
        super.record(issue)
    }

    func testNativeCorruptSelectedThemeAndMalformedTodayRecoveryRepresentatives() throws {
        for scenario in ["corrupt-theme", "malformed-today", "dual-damage"] {
            let root = try isolatedRoot("RecoveryRepresentative-" + scenario)
            var app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
            defer { app.terminate() }
            let settings = try openSettings(app)
            replace(settings.textFields["settings-wage"], with: "300.00")
            replace(settings.textFields["settings-start"], with: "09:00")
            replace(settings.textFields["settings-end"], with: "18:00")
            settings.buttons["settings-save"].click()
            XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
            settings.buttons["外观与皮肤"].click()
            settings.buttons["theme-preview-app.incomeclock.window-companion"].click()
            settings.buttons["theme-use"].click()
            XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "app.incomeclock.window-companion" })
            settings.buttons[XCUIIdentifierCloseWindow].click()
            var panel = app.dialogs["可视收入打卡机"]
            XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
            panel.buttons["打卡上班"].click()
            XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
            app.terminate()
            let settingsURL = root.appendingPathComponent("Records/settings.json")
            let todayURL = root.appendingPathComponent("Records/today.json")
            var malformedManifest: URL?
            let bad = Data("{invalid-record".utf8)
            if scenario == "corrupt-theme" {
                // A selected installed directory with an unreadable actual manifest
                // is the native startup input. Import validation has separate corpus.
                let theme = root.appendingPathComponent("Themes/com.example.startup-corrupt")
                try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
                let manifest = theme.appendingPathComponent("manifest.json")
                try bad.write(to: manifest)
                malformedManifest = manifest
                var preferences = try record(root, "theme-preferences.json")
                preferences["selectedThemeId"] = "com.example.startup-corrupt"
                try JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("Records/theme-preferences.json"))
            } else {
                try bad.write(to: todayURL)
                if scenario == "dual-damage" { try bad.write(to: settingsURL) }
            }
            let settingsBefore = try Data(contentsOf: settingsURL)
            let todayBefore = try Data(contentsOf: todayURL)
            app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
            panel = app.dialogs["可视收入打卡机"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            if let malformedManifest {
                XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
                XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "app.incomeclock.warm-island" })
                let page = try openSettings(app)
                page.buttons["外观与皮肤"].click()
                XCTAssertTrue(page.buttons["theme-preview-app.incomeclock.warm-island"].label.contains("正在使用"))
                XCTAssertEqual(try Data(contentsOf: malformedManifest), bad)
                XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBefore)
                XCTAssertEqual(try Data(contentsOf: todayURL), todayBefore)
            } else {
                XCTAssertTrue(panel.staticTexts["今日记录无法安全恢复"].waitForExistence(timeout: 5))
                XCTAssertFalse(panel.buttons["打卡上班"].exists)
                XCTAssertFalse(panel.buttons["打卡下班"].exists)
                XCTAssertFalse(panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch.exists)
                XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBefore)
                XCTAssertEqual(try Data(contentsOf: todayURL), todayBefore)
                panel.buttons["重置今日记录"].click()
                XCTAssertTrue(panel.buttons["确认重置"].waitForExistence(timeout: 5))
                panel.buttons["取消"].click()
                XCTAssertTrue(panel.buttons["重置今日记录"].waitForExistence(timeout: 5))
                XCTAssertEqual(try Data(contentsOf: todayURL), todayBefore)
                panel.buttons["重置今日记录"].click()
                XCTAssertTrue(panel.buttons["确认重置"].waitForExistence(timeout: 5))
                panel.buttons["确认重置"].click()
                XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: todayURL.path) })
                XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBefore)
                if scenario == "dual-damage" {
                    XCTAssertTrue(panel.staticTexts["设置数据无法读取"].waitForExistence(timeout: 5))
                    XCTAssertFalse(panel.buttons["打卡上班"].exists)
                } else {
                    XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
                    XCTAssertTrue(panel.buttons["打卡上班"].isEnabled)
                }
            }
            attach(app, "Native-recovery-" + scenario)
            app.terminate()
        }
    }

    func testRemainingMainDisplayCornersPersistAcrossRealRestart() throws {
        let root = try isolatedRoot("MainDisplayRemainingCorners")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "300.00")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let visible = try primaryVisibleFrameInAccessibilityCoordinates()
        let size = panel.frame.size
        // Existing gap/placement method already exercises top-left, reset and lock.
        // These are the remaining corners of this actual primary display only.
        let corners: [(String, CGPoint)] = [
            ("topRight", CGPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20)),
            ("bottomLeft", CGPoint(x: visible.minX + 20, y: visible.maxY - size.height - 20)),
            ("bottomRight", CGPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        ]
        var observations: [String] = []
        defer {
            let attachment = XCTAttachment(string: observations.joined(separator: "\n"))
            attachment.name = "Real main-display remaining corners and fresh-process restore"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for (corner, origin) in corners {
            // Complete activation before resolving drag coordinates. XCUITest
            // otherwise activates a freshly restarted process during synthesis.
            app.activate()
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            dragPanelBackground(panel, to: origin)
            XCTAssertTrue(eventually {
                abs(panel.frame.minX - origin.x) <= 1 && abs(panel.frame.minY - origin.y) <= 1
            }, corner)
            XCTAssertTrue(visible.contains(panel.frame), corner)
            XCTAssertEqual(panel.frame.size, size)
            XCTAssertTrue(eventually {
                ((try? self.record(root, "settings.json")["panelPlacement"]) as? [String: Any])?["snapCorner"] as? String == corner
            }, "Real drag must commit its actual snap corner")
            let placement = try XCTUnwrap(record(root, "settings.json")["panelPlacement"] as? [String: Any])
            let placementBytes = try JSONSerialization.data(withJSONObject: placement, options: [.sortedKeys])
            observations.append("\(corner) before restart frame=\(panel.frame), main visible=\(visible)")
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            app.launchEnvironment["INCOMECLOCK_UI_ISOLATION_NONCE"] = UUID().uuidString
            app.launch()
            try verifyIsolation(app, root: root)
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertEqual(try primaryVisibleFrameInAccessibilityCoordinates(), visible,
                "This case requires the same actual main-display usable frame across restart")
            XCTAssertTrue(eventually {
                abs(panel.frame.minX - origin.x) <= 1 && abs(panel.frame.minY - origin.y) <= 1
            }, "Fresh application must restore persisted \(corner)")
            XCTAssertEqual(panel.frame.size, size)
            let restored = try XCTUnwrap(record(root, "settings.json")["panelPlacement"] as? [String: Any])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: restored, options: [.sortedKeys]), placementBytes)
            XCTAssertEqual(try record(root, "settings.json")["dailyWageCents"] as? Int64, 30_000)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
            observations.append("\(corner) after restart frame=\(panel.frame), stored placement unchanged")
        }
        let screenshot = XCTAttachment(screenshot: panel.screenshot())
        screenshot.name = "Remaining-Corners-Final-Restored-Bottom-Right"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFinderInactiveReturnShowsTimestampCurrentAmountAndCountdown() throws {
        let root = try isolatedRoot("FinderInactiveReturn")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 1)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "999999.99")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        // Production DEBUG rate1 uses this same host monotonic clock. The real
        // persisted command timestamp is sampled inside the click interval.
        let commandBefore = ProcessInfo.processInfo.systemUptime
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let commandAfter = ProcessInfo.processInfo.systemUptime
        let today = try record(root, "today.json")
        let clockIn = try XCTUnwrap(today["clockInAtMs"] as? Int64)
        let scheduledEnd = try XCTUnwrap(today["scheduledEndAtMs"] as? Int64)
        let todayURL = root.appendingPathComponent("Records/today.json")
        let todayBytes = try Data(contentsOf: todayURL)
        let amount = panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        func liveMilliYuan() throws -> Int64 {
            let value = try XCTUnwrap(amount.value as? String)
            let fields = value.split(separator: " ")
            XCTAssertEqual(fields.count, 8, value)
            guard fields.count == 8, let yuan = Int64(fields[0]), let jiao = Int64(fields[2]),
                  let fen = Int64(fields[4]), let li = Int64(fields[6]) else {
                throw NSError(domain: "Stage9VisibleAmount", code: 1)
            }
            XCTAssertEqual(value, amountVoiceValue(yuan * 1000 + jiao * 100 + fen * 10 + li, live: true))
            return yuan * 1000 + jiao * 100 + fen * 10 + li
        }
        let beforeHide = try liveMilliYuan()
        app.activate()
        app.typeKey("i", modifierFlags: [.option, .command])
        XCTAssertTrue(waitUntil(panel, exists: false))
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        XCTAssertTrue(finder.activate(options: [.activateIgnoringOtherApps]))
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.apple.finder"))
        // Leave a gap longer than the measured command sampling uncertainty and
        // the one-second countdown cadence; no device/system preference changes.
        let hiddenFor = max(4, commandAfter - commandBefore + 3)
        XCTAssertLessThan(hiddenFor, 15, "Overlong UI input latency makes this bounded observation inconclusive")
        RunLoop.current.run(until: Date().addingTimeInterval(hiddenFor))
        XCTAssertFalse(panel.exists)
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.apple.finder"))
        let status = app.statusItems["income-clock-menu-bar-extra"]
        status.click()
        activateOpenPanelMenuItem(named: "显示收入面板", in: status)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.apple.finder"))
        let countdown = panel.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "距离下班 ", "距离下班 ")).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        var samples: [String] = []
        defer {
            let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
            attachment.name = "Inactive return timestamp brackets and observed amount-countdown samples"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for index in 0..<4 {
            let sampledBefore = ProcessInfo.processInfo.systemUptime
            let observed = try liveMilliYuan()
            let label = nativeStaticText(countdown)
            let sampledAfter = ProcessInfo.processInfo.systemUptime
            // Amount brackets include actual command and UI snapshot latency.
            // Only countdown receives its separate one-second cadence bound.
            let lowerTime = clockIn + Int64(((sampledBefore - commandAfter) * 1000).rounded(.down))
            let upperTime = clockIn + Int64(((sampledAfter - commandBefore) * 1000).rounded(.up)) + 1
            let lowerAmount = try expectedAmount(today, at: lowerTime, live: true)
            let upperAmount = try expectedAmount(today, at: upperTime, live: true)
            XCTAssertGreaterThanOrEqual(observed, lowerAmount, "Observed amount must lie within the measured current timestamp interval")
            XCTAssertLessThanOrEqual(observed, upperAmount)
            XCTAssertGreaterThan(observed, beforeHide)
            let parts = label.dropFirst("距离下班 ".count).split(separator: ":")
            XCTAssertEqual(parts.count, 3, label)
            let hours = try XCTUnwrap(parts.first.flatMap { Int64($0) })
            let minutes = try XCTUnwrap(parts.dropFirst().first.flatMap { Int64($0) })
            let seconds = try XCTUnwrap(parts.last.flatMap { Int64($0) })
            let remaining = hours * 3600 + minutes * 60 + seconds
            XCTAssertGreaterThanOrEqual(remaining, max(0, scheduledEnd - upperTime) / 1000)
            XCTAssertLessThanOrEqual(remaining, max(0, scheduledEnd - (lowerTime - 1000)) / 1000)
            XCTAssertEqual(try Data(contentsOf: todayURL), todayBytes)
            samples.append("sample=\(index), timestamp=[\(lowerTime),\(upperTime)], milliYuan=\(observed) expected=[\(lowerAmount),\(upperAmount)], countdown=\(label), hiddenSeconds=\(hiddenFor)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let screenshot = XCTAttachment(screenshot: panel.screenshot())
        screenshot.name = "Finder-Inactive-Return-Current-Amount-And-Countdown"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // AX target samples are not every animation frame or an OS announcement
        // listener. Combine with existing native pulse/current-target + actual
        // hidden-panel activeAnimationCount==0 evidence; do not claim video QA.
    }

    /// Supported app/menu shortcut context; no foreign-app global delivery claim.
    func testOptionCommandITogglesRealPanel() throws {
        let root = try isolatedRoot("AppShortcutNativeFocus")
        try prepareHiddenPanelState(at: root)
        let now = try localTimestamp(hour: 12)
        let app = try launchIsolated(root: root, now: now, rate: 0)
        defer { app.terminate() }
        let panel = app.dialogs["可视收入打卡机"]
        let todayURL = root.appendingPathComponent("Records/today.json")
        var trace: [[String: Any]] = []
        func sample(_ phase: String, _ element: XCUIElement? = nil) {
            trace.append([
                "phase": phase,
                "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil",
                "nativeFocus": element?.debugDescription.components(separatedBy: "\n").first ?? "none"
            ])
        }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]),
               data.count <= 24_576 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "AppShortcut-NativeFocus-Toggle-Trace"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        func isFocused(_ element: XCUIElement) -> Bool {
            element.exists && element.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true
        }
        func requireFocus(_ element: XCUIElement, phase: String) {
            XCTAssertTrue(eventually { isFocused(element) }, "Native Keyboard Focused required: \(phase)")
            XCTAssertGreaterThan(element.frame.width, 0)
            XCTAssertGreaterThan(element.frame.height, 0)
            XCTAssertTrue(panel.frame.insetBy(dx: -2, dy: -2).contains(element.frame))
            XCTAssertTrue(element.isHittable)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.ffq.incomeclock")
            sample(phase, element)
        }
        XCTAssertFalse(panel.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))
        sample("before-app-activation")
        app.activate()
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.ffq.incomeclock"))
        XCTAssertFalse(panel.exists, "Activation alone must not substitute for shortcut display")
        sample("before-app-local-chord")
        // Actual native keyboard event through the supported app/menu context.
        // No additional click, activation or recovery Tab follows before focus proof.
        app.typeKey("i", modifierFlags: [.option, .command])
        sample("immediately-after-app-local-chord")
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.ffq.incomeclock"))
        let settings = panel.buttons["打开设置"]
        // UI Contract 17.1 initial native focus is Settings. No extra click/activate,
        // extra keyboard event, semantic focus hint, or recovery navigation precedes it.
        requireFocus(settings, phase: "shortcut-open-settings-native-focus")
        let clockIn = panel.buttons["打卡上班"]
        app.typeKey(.tab, modifierFlags: .shift)
        requireFocus(clockIn, phase: "shift-tab-primary-native-focus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))
        app.typeKey(.return, modifierFlags: [])
        let clockOut = panel.buttons["打卡下班"]
        XCTAssertTrue(clockOut.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: todayURL.path) })
        let today = try record(root, "today.json")
        XCTAssertEqual(today["clockInAtMs"] as? Int64, now)
        XCTAssertTrue(today["clockOutAtMs"] == nil || today["clockOutAtMs"] is NSNull)
        let committed = try Data(contentsOf: todayURL)
        sample("one-return-one-ongoing-record", clockOut)
        // Post-transition native traversal is bounded and cannot hide a failed
        // initial focus assertion. Stop before Return unless actual focus is proven.
        for _ in 0..<3 {
            if isFocused(clockOut) { break }
            app.typeKey(.tab, modifierFlags: [])
        }
        requireFocus(clockOut, phase: "clock-out-native-focus")
        app.typeKey(.return, modifierFlags: [])
        let cancel = panel.buttons["取消"]
        let confirm = panel.buttons["确认下班"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.exists)
        if !isFocused(cancel) { app.typeKey(.tab, modifierFlags: []) }
        requireFocus(cancel, phase: "confirmation-cancel-native-focus")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(confirm, exists: false))
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(clockOut.exists)
        XCTAssertEqual(try Data(contentsOf: todayURL), committed)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.ffq.incomeclock")
        sample("escape-preserved-committed-record", clockOut)

        // Retain the original real-dialog show/hide coverage, now with a record
        // preservation oracle; each chord is one deliberate toggle, never a retry.
        app.typeKey("i", modifierFlags: [.option, .command])
        XCTAssertTrue(waitUntil(panel, exists: false))
        XCTAssertEqual(try Data(contentsOf: todayURL), committed)
        sample("shortcut-hidden")
        app.typeKey("i", modifierFlags: [.option, .command])
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        requireFocus(settings, phase: "shortcut-reshown-native-focus")
        XCTAssertEqual(try Data(contentsOf: todayURL), committed)
        app.typeKey("i", modifierFlags: [.option, .command])
        XCTAssertTrue(waitUntil(panel, exists: false))
        XCTAssertEqual(try Data(contentsOf: todayURL), committed)
        sample("shortcut-hidden-again")

    }

    func testMenuBarExtraTogglesRealPanel() throws {
        let root = URL(fileURLWithPath: "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true)
            .appendingPathComponent("IncomeClockMenuBarUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try prepareHiddenPanelState(at: root)
        let app = XCUIApplication()
        app.launchEnvironment["INCOMECLOCK_TEST_ROOT"] = root.path
        app.launchEnvironment["INCOMECLOCK_UI_ISOLATION_NONCE"] = UUID().uuidString
        app.launch()
        try verifyIsolation(app, root: root)
        defer {
            app.terminate()
        }

        let panel = app.dialogs["可视收入打卡机"]
        let finder = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder"
            ).first
        )
        XCTAssertTrue(finder.activate(options: [.activateIgnoringOtherApps]))
        XCTAssertTrue(waitUntilFrontmostApplication(hasBundleIdentifier: "com.apple.finder"))

        let statusItem = app.statusItems["income-clock-menu-bar-extra"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertFalse(panel.exists, "The isolated menu test must start with the panel hidden")
        statusItem.click()
        let showItem = statusItem.menuItems["显示收入面板"]
        XCTAssertTrue(showItem.waitForExistence(timeout: 5))
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.ffq.incomeclock").first)
        XCTAssertEqual(running.activationPolicy, .accessory, "Actual default application policy excludes a Dock application tile")
        // macOS exposes these native menu names as AXTitle, not AXLabel.
        // Exact title lookup plus actual row geometry observes the visible order.
        let expectedOrder = ["显示收入面板", "打开设置…", "始终置顶", "全屏应用时隐藏", "登录时启动", "退出可视收入打卡机"]
        var previousBottom = -CGFloat.infinity
        for title in expectedOrder {
            let item = statusItem.menuItems[title]
            XCTAssertTrue(item.exists, "Missing native menu title: \(title)")
            XCTAssertGreaterThan(item.frame.width, 0, title)
            XCTAssertGreaterThan(item.frame.height, 0, title)
            XCTAssertGreaterThanOrEqual(item.frame.minY, previousBottom, title)
            previousBottom = item.frame.maxY
        }
        let menuEvidence = XCTAttachment(string: statusItem.debugDescription)
        menuEvidence.name = "Actual MenuBarExtra native menu and checked state"
        menuEvidence.lifetime = .keepAlways
        add(menuEvidence)
        attach(app, "Native-MenuBarExtra-Structure")
        activateOpenPanelMenuItem(named: "显示收入面板", in: statusItem)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntilFrontmostApplication(hasBundleIdentifier: "com.apple.finder")
        )

        statusItem.click()
        let hideItem = statusItem.menuItems["隐藏收入面板"]
        XCTAssertTrue(hideItem.waitForExistence(timeout: 5))
        activateOpenPanelMenuItem(named: "隐藏收入面板", in: statusItem)
        XCTAssertTrue(waitUntil(panel, exists: false))
    }

    private func prepareHiddenPanelState(at root: URL) throws {
        let records = root.appendingPathComponent("Records", isDirectory: true)
        try FileManager.default.createDirectory(
            at: records,
            withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
            "schemaVersion": 1,
            "revision": "1",
            "dailyWageCents": 30_000,
            "workStartMinuteOfDay": 9 * 60,
            "workEndMinuteOfDay": 18 * 60,
            "notificationsEnabled": false,
            "alwaysOnTop": true,
            "lockPanelPosition": false,
            "hideInFullScreen": true,
            "launchAtLogin": false,
            "panelVisible": false,
            "updatedAtMs": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        try data.write(
            to: records.appendingPathComponent("settings.json", isDirectory: false),
            options: .atomic
        )
    }

    private func activateOpenPanelMenuItem(
        named title: String,
        in statusItem: XCUIElement
    ) {
        let item = statusItem.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    private func waitUntil(
        _ element: XCUIElement,
        exists: Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == %@", NSNumber(value: exists)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilFrontmostApplication(
        hasBundleIdentifier bundleIdentifier: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    /// Real Settings -> MenuBar -> Panel commands share one persisted Today.
    /// DEBUG clock changes only this isolated application instance.
    func testSettingsMenuPanelClockOutAndRestartUseOneCommittedRecord() throws {
        let root = try isolatedRoot("SharedState")
        let origin = try localTimestamp(hour: 12)
        let app = try launchIsolated(root: root, now: origin, rate: 1)
        defer { app.terminate() }
        let settings = try openSettingsFromMenu(app)
        settings.buttons["工作规则"].click()
        replace(settings.textFields["settings-wage"], with: "999999.99")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        XCTAssertEqual(try record(root, "settings.json")["dailyWageCents"] as? Int64, 99_999_999)
        XCTAssertFalse(settings.buttons["settings-save"].isEnabled)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        let status = app.statusItems["income-clock-menu-bar-extra"]
        status.click()
        activateOpenPanelMenuItem(named: "打卡上班", in: status)
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let amount = panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let first = amount.value as? String
        XCTAssertNotNil(first)
        XCTAssertTrue(eventually { (amount.value as? String) != first })
        let todayBeforeCancel = try Data(contentsOf: root.appendingPathComponent("Records/today.json"))
        status.click()
        activateOpenPanelMenuItem(named: "打卡下班", in: status)
        XCTAssertTrue(panel.buttons["确认下班"].waitForExistence(timeout: 5))
        let estimate = panel.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "预计结算", "预计结算")).firstMatch
        XCTAssertTrue(estimate.exists)
        let firstEstimate = nativeStaticText(estimate)
        XCTAssertTrue(eventually { self.nativeStaticText(estimate) != firstEstimate })
        panel.buttons["取消"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), todayBeforeCancel)
        panel.buttons["打卡下班"].click()
        panel.buttons["确认下班"].click()
        XCTAssertTrue(eventually { (try? self.record(root, "today.json")["clockOutAtMs"] as? Int64) != nil })
        let today = try record(root, "today.json")
        let finalCents = try expectedAmount(today, at: XCTUnwrap(today["clockOutAtMs"] as? Int64), live: false)
        XCTAssertTrue(eventually { (amount.value as? String) == self.amountVoiceValue(finalCents, live: false) })
        let completedBytes = try Data(contentsOf: root.appendingPathComponent("Records/today.json"))
        attach(app, "Shared-State-Completed")
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launchArguments = ["--debug-now-ms", String(try localTimestamp(hour: 20)), "--debug-time-rate", "0"]
        app.launch()
        try verifyIsolation(app, root: root)
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { (amount.value as? String) == self.amountVoiceValue(finalCents, live: false) })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), completedBytes)
        XCTAssertFalse(panel.buttons["打卡上班"].exists)
        attach(app, "Shared-State-Restored-Settlement")
        let settingsBeforeQuit = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        status.click()
        activateOpenPanelMenuItem(named: "退出可视收入打卡机", in: status)
        XCTAssertTrue(eventually { app.state == .notRunning })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), completedBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), settingsBeforeQuit)
    }

    func testEarningRestartsFromPersistedTimestampAndThemePreviewRequiresApply() throws {
        let root = try isolatedRoot("ThemeEarning")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "900.00")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let before = try Data(contentsOf: root.appendingPathComponent("Records/today.json"))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        let resumedAt = try localTimestamp(hour: 13)
        app.launchArguments = ["--debug-now-ms", String(resumedAt), "--debug-time-rate", "0"]
        app.launch()
        try verifyIsolation(app, root: root)
        let amount = panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let live = try expectedAmount(record(root, "today.json"), at: resumedAt, live: true)
        XCTAssertEqual(amount.value as? String, amountVoiceValue(live, live: true))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), before)
        _ = try openSettings(app)
        settings.buttons["外观与皮肤"].click()
        let cardA = revealSettingsButton("theme-preview-app.incomeclock.warm-island", in: settings, towardTop: true)
        XCTAssertTrue(cardA.waitForExistence(timeout: 5))
        XCTAssertTrue(cardA.label.contains("正在使用"))
        let restoreDefault = revealSettingsButton("恢复默认皮肤", in: settings, towardTop: false)
        XCTAssertTrue(restoreDefault.exists)
        XCTAssertFalse(restoreDefault.isEnabled)
        revealSettingsButton("theme-preview-app.incomeclock.warm-island", in: settings, towardTop: true).click()
        let defaultUse = revealSettingsButton("theme-use", in: settings, towardTop: false)
        XCTAssertFalse(defaultUse.isEnabled)
        XCTAssertFalse(settings.buttons["theme-delete-request"].exists, "Built-in A must not offer deletion")
        XCTAssertTrue(settings.staticTexts["默认 · 内置 · 不可删除"].exists)
        let prefsURL = root.appendingPathComponent("Records/theme-preferences.json")
        let beforePrefs = try? Data(contentsOf: prefsURL)
        revealSettingsButton("theme-preview-app.incomeclock.window-companion", in: settings, towardTop: true).click()
        let apply = revealSettingsButton("theme-use", in: settings, towardTop: false)
        XCTAssertTrue(apply.isEnabled)
        XCTAssertFalse(settings.buttons["theme-delete-request"].exists, "Built-in B must not offer deletion")
        XCTAssertTrue(settings.staticTexts["内置验证皮肤"].exists)
        let unchangedCardA = revealSettingsButton("theme-preview-app.incomeclock.warm-island", in: settings, towardTop: true)
        XCTAssertTrue(unchangedCardA.label.contains("正在使用"))
        XCTAssertFalse(settings.buttons["theme-preview-app.incomeclock.window-companion"].label.contains("正在使用"))
        XCTAssertEqual(try? Data(contentsOf: prefsURL), beforePrefs)
        XCTAssertEqual(amount.value as? String, amountVoiceValue(live, live: true))
        revealSettingsButton("theme-use", in: settings, towardTop: false).click()
        XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "app.incomeclock.window-companion" })
        let selectedCard = revealSettingsButton("theme-preview-app.incomeclock.window-companion", in: settings, towardTop: true)
        XCTAssertTrue(selectedCard.label.contains("正在使用"))
        let selectedUse = revealSettingsButton("theme-use", in: settings, towardTop: false)
        XCTAssertFalse(selectedUse.isEnabled)
        let currentRestoreDefault = revealSettingsButton("恢复默认皮肤", in: settings, towardTop: false)
        XCTAssertTrue(currentRestoreDefault.isEnabled)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), before)
        XCTAssertEqual(amount.value as? String, amountVoiceValue(live, live: true))
        attach(app, "Theme-Explicit-Apply-Preserves-Earning")
    }

    func testSettingsInlineValidationRetainsInputsAndSevenPagesAreReachable() throws {
        let root = try isolatedRoot("SettingsValidation")
        // Process-only TZ plus the existing isolated clock selects a real DST gap day.
        // No host timezone setting is changed; the later Today snapshot proves use.
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let dstDate = try XCTUnwrap(dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let dstNow = Int64(dstDate.timeIntervalSince1970 * 1_000)
        let app = try launchIsolated(root: root, now: dstNow, rate: 0, timeZoneIdentifier: "America/New_York")
        defer { app.terminate() }
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let visibleFrame = try primaryVisibleFrameInAccessibilityCoordinates()
        assertDefaultPanelFrame(panel.frame, visibleFrame: visibleFrame)
        let settings = try openSettings(app)
        let wage = settings.textFields["settings-wage"]
        replace(wage, with: "0")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["请输入范围内的日工资，最多两位小数。"].waitForExistence(timeout: 5))
        XCTAssertEqual(wage.value as? String, "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/settings.json").path))
        XCTAssertFalse(settings.staticTexts["设置已保存"].exists)
        XCTAssertTrue(wage.isEnabled)
        replace(wage, with: "300.00")
        replace(settings.textFields["settings-start"], with: "18:00")
        replace(settings.textFields["settings-end"], with: "09:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["固定下班时间必须晚于上班时间。"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.textFields["settings-start"].value as? String, "18:00")
        XCTAssertEqual(settings.textFields["settings-end"].value as? String, "09:00")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/settings.json").path))
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        // The focused text field's Return follows the production default save action.
        settings.textFields["settings-end"].typeKey(.return, modifierFlags: [])
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        XCTAssertEqual(try record(root, "settings.json")["dailyWageCents"] as? Int64, 30_000)
        let settingsURL = root.appendingPathComponent("Records/settings.json")
        let beforeDST = try Data(contentsOf: settingsURL)
        let revisionBeforeDST = try XCTUnwrap(record(root, "settings.json")["revision"] as? String)
        let startField = settings.textFields["settings-start"]
        let endField = settings.textFields["settings-end"]
        let gapError = settings.staticTexts["当前时区下，此时间不存在或无法唯一确定，请选择其他时间。"]
        // 02:30 does not exist in New York on 2026-03-08; test both boundaries.
        for boundary in ["start", "end"] {
            let draftStart = boundary == "start" ? "02:30" : "01:30"
            let draftEnd = boundary == "end" ? "02:30" : "18:00"
            replace(startField, with: draftStart)
            replace(endField, with: draftEnd)
            settings.buttons["settings-save"].click()
            XCTAssertTrue(gapError.waitForExistence(timeout: 5), "DST gap at \(boundary)")
            // The typed DST failure uses the Contract's inline copy; exact
            // unchanged persistence and absence of success are asserted below.
            XCTAssertEqual(wage.value as? String, "300.00")
            XCTAssertEqual(startField.value as? String, draftStart)
            XCTAssertEqual(endField.value as? String, draftEnd)
            XCTAssertGreaterThanOrEqual(gapError.frame.minY, max(startField.frame.maxY, endField.frame.maxY))
            XCTAssertFalse(settings.staticTexts["设置已保存"].exists)
            XCTAssertEqual(try Data(contentsOf: settingsURL), beforeDST)
            XCTAssertEqual(try record(root, "settings.json")["revision"] as? String, revisionBeforeDST)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
            // No click/refocus: the error must place native keyboard focus on its boundary.
            editTimeDigits(boundary == "start" ? "01:30" : "18:00", into: app)
            XCTAssertEqual(startField.value as? String, "01:30")
            XCTAssertEqual(endField.value as? String, "18:00")
            attach(app, "Settings-DST-" + boundary + "-Gap-Preserved")
        }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        XCTAssertFalse(gapError.exists)
        let repairedRules = try record(root, "settings.json")
        XCTAssertEqual(repairedRules["workStartMinuteOfDay"] as? Int, 90)
        XCTAssertEqual(repairedRules["workEndMinuteOfDay"] as? Int, 1_080)
        XCTAssertNotEqual(repairedRules["revision"] as? String, revisionBeforeDST)
        // Same process, real mouse drag: background -> nearest top-left corner.
        // Screen geometry comes from the current main display, never a fake screen.
        settings.buttons[XCUIIdentifierCloseWindow].click()
        dragPanelBackground(panel, to: CGPoint(x: visibleFrame.minX + 20, y: visibleFrame.minY + 20))
        XCTAssertTrue(eventually {
            abs(panel.frame.minX - visibleFrame.minX - 20) <= 1 &&
            abs(panel.frame.minY - visibleFrame.minY - 20) <= 1
        })
        XCTAssertTrue(eventually {
            ((try? self.record(root, "settings.json")["panelPlacement"]) as? [String: Any])?["snapCorner"] as? String == "topLeft"
        })
        _ = try openSettings(app)
        settings.buttons["面板与启动"].click()
        let reset = settings.buttons["恢复默认面板位置"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.click()
        XCTAssertTrue(eventually {
            abs(panel.frame.maxX - visibleFrame.maxX + 20) <= 1 &&
            abs(panel.frame.maxY - visibleFrame.maxY + 20) <= 1
        })
        assertDefaultPanelFrame(panel.frame, visibleFrame: visibleFrame)
        let lock = settings.checkBoxes["锁定面板位置"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertEqual(try record(root, "settings.json")["lockPanelPosition"] as? Bool, false)
        lock.click()
        XCTAssertTrue(eventually { (try? self.record(root, "settings.json")["lockPanelPosition"] as? Bool) == true })
        let lockedSettings = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let lockedFrame = panel.frame
        dragPanelBackground(panel, to: CGPoint(x: visibleFrame.minX + 20, y: visibleFrame.minY + 20))
        // Wait through the production drag debounce before comparing both frame and record.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(panel.frame, lockedFrame)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), lockedSettings)
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5), "Locked panel primary action must still receive real clicks")
        let dstToday = try record(root, "today.json")
        XCTAssertEqual(dstToday["clockInAtMs"] as? Int64, dstNow)
        XCTAssertEqual(dstToday["dateKey"] as? String, "2026-03-08")
        let dstSnapshot = try XCTUnwrap(dstToday["settingsSnapshot"] as? [String: Any])
        XCTAssertEqual(dstSnapshot["timeZoneIdentifier"] as? String, "America/New_York", "Process TZ must actually reach the production command context")
        _ = try openSettings(app)
        XCTAssertTrue(settings.exists, "Locked panel settings control must still receive real clicks")
        attach(app, "Single-Main-Display-Locked-Panel-Controls")
        let pages: [(String, String)] = [
            ("通用", "皮肤提示音"), ("工作规则", "日工资"),
            ("面板与启动", "恢复默认面板位置"), ("外观与皮肤", "导入皮肤…"),
            ("数据与隐私", "本地数据"), ("快捷键", "⌥⌘I"), ("关于", "macOS 13")
        ]
        for (page, content) in pages {
            settings.buttons[page].click()
            XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings-page-" + page).firstMatch.waitForExistence(timeout: 5), page)
            if page == "工作规则" {
                XCTAssertTrue(settings.textFields["settings-wage"].exists)
            } else {
                let labelled = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", content)).firstMatch
                let textValue = settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", content)).firstMatch
                XCTAssertTrue(eventually { labelled.exists || textValue.exists }, page)
            }
            attach(app, "Settings-Page-" + page)
        }
    }

    func testSettingsDSTFoldPreservesBothFieldDraftsAndCommitsOnlyUniqueTimes() throws {
        let root = try isolatedRoot("SettingsDSTFold")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let now = Int64(date.timeIntervalSince1970 * 1_000)
        let app = try launchIsolated(root: root, now: now, rate: 0, timeZoneIdentifier: "America/New_York")
        defer { app.terminate() }
        let settings = try openSettings(app)
        let wage = settings.textFields["settings-wage"]
        let start = settings.textFields["settings-start"]
        let end = settings.textFields["settings-end"]
        let save = settings.buttons["settings-save"]
        let success = settings.staticTexts["设置已保存"]
        let inline = settings.staticTexts["当前时区下，此时间不存在或无法唯一确定，请选择其他时间。"]
        replace(wage, with: "300.00")
        replace(start, with: "09:00")
        replace(end, with: "18:00")
        save.click()
        XCTAssertTrue(success.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(success, exists: false), "Prior successful toast must expire before a failed-save assertion")
        let settingsURL = root.appendingPathComponent("Records/settings.json")
        let todayURL = root.appendingPathComponent("Records/today.json")

        // 01:30 occurs twice on 2026-11-01 in New York. Each correction is
        // different from the committed rules, so Save remains a real action.
        for boundary in ["start", "end"] {
            let before = try Data(contentsOf: settingsURL)
            let revision = try XCTUnwrap(record(root, "settings.json")["revision"] as? String)
            let draftStart = boundary == "start" ? "01:30" : "00:30"
            let draftEnd = boundary == "end" ? "01:30" : "18:00"
            replace(start, with: draftStart)
            replace(end, with: draftEnd)
            XCTAssertFalse(inline.exists)
            XCTAssertTrue(save.isEnabled)
            save.click()
            XCTAssertTrue(inline.waitForExistence(timeout: 5), "DST fold at \(boundary)")
            XCTAssertTrue(eventually { save.isEnabled })
            XCTAssertEqual(start.value as? String, draftStart)
            XCTAssertEqual(end.value as? String, draftEnd)
            XCTAssertEqual(wage.value as? String, "300.00")
            XCTAssertGreaterThanOrEqual(inline.frame.minY, max(start.frame.maxY, end.frame.maxY))
            XCTAssertFalse(success.exists)
            XCTAssertEqual(try Data(contentsOf: settingsURL), before)
            XCTAssertEqual(try record(root, "settings.json")["revision"] as? String, revision)
            XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))

            // Do not click or refocus: only the invalid boundary may receive
            // these digit edits. The real separator is preserved by the helper.
            editTimeDigits(boundary == "start" ? "03:00" : "18:00", into: app)
            XCTAssertEqual(start.value as? String, boundary == "start" ? "03:00" : "00:30")
            XCTAssertEqual(end.value as? String, "18:00")
            XCTAssertEqual(try Data(contentsOf: settingsURL), before, "Editing the corrected draft is not a commit")
            XCTAssertTrue(save.isEnabled)
            save.click()
            XCTAssertTrue(success.waitForExistence(timeout: 5))
            XCTAssertFalse(inline.exists)
            let saved = try record(root, "settings.json")
            XCTAssertNotEqual(saved["revision"] as? String, revision)
            XCTAssertEqual(saved["workStartMinuteOfDay"] as? Int, boundary == "start" ? 180 : 30)
            XCTAssertEqual(saved["workEndMinuteOfDay"] as? Int, 1_080)
            XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))
            XCTAssertTrue(waitUntil(success, exists: false))
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let today = try record(root, "today.json")
        let snapshot = try XCTUnwrap(today["settingsSnapshot"] as? [String: Any])
        XCTAssertEqual(today["dateKey"] as? String, "2026-11-01")
        XCTAssertEqual(today["clockInAtMs"] as? Int64, now)
        XCTAssertEqual(snapshot["timeZoneIdentifier"] as? String, "America/New_York")
        XCTAssertEqual(snapshot["workStartMinuteOfDay"] as? Int, 30)
        XCTAssertEqual(snapshot["workEndMinuteOfDay"] as? Int, 1_080)
    }

    func testStartupDSTGapOpensSettingsAndFailedRetryPreservesRecordsUntilCorrection() throws {
        let root = try isolatedRoot("StartupDSTGap")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let priorDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
        let gapDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let gapNow = Int64(gapDate.timeIntervalSince1970 * 1_000)
        var app = try launchIsolated(root: root, now: Int64(priorDate.timeIntervalSince1970 * 1_000),
                                     rate: 0, timeZoneIdentifier: "America/New_York")
        defer { app.terminate() }
        var settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "300.00")
        replace(settings.textFields["settings-start"], with: "02:30")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        let settingsURL = root.appendingPathComponent("Records/settings.json")
        let todayURL = root.appendingPathComponent("Records/today.json")
        let priorRules = try record(root, "settings.json")
        let priorRevision = try XCTUnwrap(priorRules["revision"] as? String)
        let priorBytes = try Data(contentsOf: settingsURL)
        XCTAssertEqual(priorRules["workStartMinuteOfDay"] as? Int, 150)
        XCTAssertEqual(priorRules["workEndMinuteOfDay"] as? Int, 1_080)
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        // Relaunch the same UI-authored, valid record on the next date. No
        // hand-written schema, system timezone change or observation hook.
        app = try launchIsolated(root: root, now: gapNow, rate: 0, timeZoneIdentifier: "America/New_York")
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["今日工作时间无法确定"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.staticTexts["原设置和记录未修改，请调整时间后重试"].exists)
        let amount = panel.staticTexts.matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        func assertNoPublishedBusinessSurface(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertFalse(amount.exists, file: file, line: line)
            XCTAssertFalse(panel.staticTexts["计划工作进度"].exists, file: file, line: line)
            XCTAssertFalse(panel.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@", "距离开始", "距离开始", "距离下班", "距离下班")).firstMatch.exists,
                           file: file, line: line)
            for state in ["待完成设置", "今日未打卡", "已打卡 · 等待开工", "计薪中", "计薪已停止", "今日已完成", "记录需要恢复"] {
                XCTAssertFalse(panel.staticTexts[state].exists, state, file: file, line: line)
            }
            for action in ["打卡上班", "打卡下班", "重置今日记录", "开始今天"] {
                XCTAssertFalse(panel.buttons[action].exists, action, file: file, line: line)
            }
            XCTAssertEqual(try Data(contentsOf: settingsURL), priorBytes, file: file, line: line)
            XCTAssertEqual(try record(root, "settings.json")["revision"] as? String, priorRevision, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path), file: file, line: line)
        }
        try assertNoPublishedBusinessSurface()
        attach(app, "Startup-DST-Gap-No-Business-State")
        let repair = panel.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "打开设置", "gearshape")).firstMatch
        XCTAssertTrue(repair.exists)
        XCTAssertTrue(repair.isEnabled)
        repair.click()
        settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["今日工作时间无法确定"].exists)
        XCTAssertTrue(settings.staticTexts["原有设置和记录未被修改。请调整上下班时间后重试。"].exists)
        let start = settings.textFields["settings-start"]
        let end = settings.textFields["settings-end"]
        XCTAssertEqual(start.value as? String, "02:30")
        XCTAssertEqual(end.value as? String, "18:00")

        // Automatic startup error focus receives a different still-invalid
        // draft, enabling a genuine failed retry rather than a disabled Save.
        editTimeDigits("02:45", into: app)
        XCTAssertEqual(start.value as? String, "02:45")
        XCTAssertEqual(end.value as? String, "18:00")
        let save = settings.buttons["settings-save"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        let inline = settings.staticTexts["当前时区下，此时间不存在或无法唯一确定，请选择其他时间。"]
        XCTAssertTrue(inline.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { save.isEnabled })
        XCTAssertEqual(start.value as? String, "02:45")
        XCTAssertEqual(end.value as? String, "18:00")
        XCTAssertFalse(settings.staticTexts["设置已保存"].exists)
        try assertNoPublishedBusinessSurface()

        // Again no field click: failed retry must leave focus on its boundary.
        editTimeDigits("03:00", into: app)
        XCTAssertEqual(start.value as? String, "03:00")
        XCTAssertEqual(end.value as? String, "18:00")
        XCTAssertEqual(try Data(contentsOf: settingsURL), priorBytes)
        save.click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        XCTAssertFalse(inline.exists)
        XCTAssertFalse(settings.staticTexts["今日工作时间无法确定"].exists)
        let repaired = try record(root, "settings.json")
        XCTAssertNotEqual(repaired["revision"] as? String, priorRevision)
        XCTAssertEqual(repaired["workStartMinuteOfDay"] as? Int, 180)
        XCTAssertEqual(repaired["workEndMinuteOfDay"] as? Int, 1_080)
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayURL.path))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(panel.staticTexts["今日未打卡"].waitForExistence(timeout: 5))
        XCTAssertFalse(panel.staticTexts["今日工作时间无法确定"].exists)
        XCTAssertTrue(amount.exists)
        XCTAssertTrue(panel.buttons["打卡上班"].isEnabled)
        attach(app, "Startup-DST-Gap-Corrected-Ready")
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let today = try record(root, "today.json")
        let snapshot = try XCTUnwrap(today["settingsSnapshot"] as? [String: Any])
        XCTAssertEqual(today["dateKey"] as? String, "2026-03-08")
        XCTAssertEqual(today["clockInAtMs"] as? Int64, gapNow)
        XCTAssertEqual(snapshot["timeZoneIdentifier"] as? String, "America/New_York")
        XCTAssertEqual(snapshot["workStartMinuteOfDay"] as? Int, 180)
        XCTAssertEqual(snapshot["workEndMinuteOfDay"] as? Int, 1_080)
        XCTAssertTrue(eventually { (amount.value as? String) == self.amountVoiceValue(0, live: true) })
    }

    func testNativeMenuWaitingAwaitingAndCompletedUseOwnedStateAndCommands() throws {
        executionTimeAllowance = 480
        let deadline = Date().addingTimeInterval(480)
        func require(_ ok: Bool, _ message: String) throws { _ = try XCTUnwrap(ok ? true : nil, message) }
        for appearance in ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"] {
            for waiting in [true, false] {
                try require(Date() < deadline, "Batch timeout stops remaining cases")
                try require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.ffq.incomeclock").isEmpty,
                    "Never replace an existing app on launch")
                let caseName = (waiting ? "waiting-" : "awaiting-") + appearance
                let root = try isolatedRoot("MenuRemaining-" + caseName)
                let records = root.appendingPathComponent("Records", isDirectory: true)
                try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
                let start: Int64 = 1_788_883_200_000
                let end: Int64 = 1_788_915_600_000
                let now: Int64 = waiting ? 1_788_879_600_000 : end
                let clockIn = waiting ? now : start
                let settings: [String: Any] = ["schemaVersion": 1, "revision": "1", "dailyWageCents": 90000,
                    "workStartMinuteOfDay": 540, "workEndMinuteOfDay": 1080, "notificationsEnabled": false,
                    "alwaysOnTop": true, "lockPanelPosition": false, "hideInFullScreen": true,
                    "launchAtLogin": false, "panelVisible": true, "updatedAtMs": 0]
                let today: [String: Any] = ["schemaVersion": 1, "revision": "1", "dateKey": "2026-09-08",
                    "clockInAtMs": clockIn, "scheduledStartAtMs": start, "scheduledEndAtMs": end,
                    "updatedAtMs": clockIn, "settingsSnapshot": ["dailyWageCents": 90000,
                    "workStartMinuteOfDay": 540, "workEndMinuteOfDay": 1080, "currency": "CNY",
                    "timeZoneIdentifier": "America/Los_Angeles"]]
                let settingsURL = records.appendingPathComponent("settings.json")
                let todayURL = records.appendingPathComponent("today.json")
                let settingsBefore = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
                let todayBefore = try JSONSerialization.data(withJSONObject: today, options: [.sortedKeys])
                try settingsBefore.write(to: settingsURL, options: .atomic)
                try todayBefore.write(to: todayURL, options: .atomic)
                // Explicit app handle/nonce exists before launch. No production/helper change.
                let app = XCUIApplication()
                let nonce = UUID().uuidString
                app.launchEnvironment = ["TZ": "America/Los_Angeles", "INCOMECLOCK_TEST_ROOT": root.path,
                    "INCOMECLOCK_UI_ISOLATION_NONCE": nonce, "INCOMECLOCK_NATIVE_MENU_DIAGNOSTIC": "1",
                    "INCOMECLOCK_NATIVE_MENU_SUMMARY_ROWS": "1",
                    "INCOMECLOCK_NATIVE_MENU_SUMMARY_APPEARANCE": appearance]
                app.launchArguments = ["--debug-now-ms", String(now), "--debug-time-rate", "0"]
                let testBundle = Bundle(for: ShortcutUITests.self).bundleURL.resolvingSymlinksInPath()
                let runner = testBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let product = runner.deletingLastPathComponent()
                try require(testBundle.lastPathComponent == "IncomeClockUITests.xctest"
                    && testBundle.deletingLastPathComponent().lastPathComponent == "PlugIns"
                    && runner.lastPathComponent == "IncomeClockUITests-Runner.app"
                    && ["Debug", "Debug-UIRunner"].contains(product.lastPathComponent), "Pinned runner before launch")
                let allowedBundle = product.appendingPathComponent("IncomeClock.app").resolvingSymlinksInPath().path
                app.launch()
                let owned = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.ffq.incomeclock").first)
                let pid = owned.processIdentifier
                let launchDate = try XCTUnwrap(owned.launchDate)
                let bundle = try XCTUnwrap(owned.bundleURL).resolvingSymlinksInPath().path
                let executable = try XCTUnwrap(owned.executableURL).resolvingSymlinksInPath().path
                func sameOwned() -> Bool {
                    let live = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ffq.incomeclock")
                    return live.count == 1 && live.first?.processIdentifier == pid && live.first?.launchDate == launchDate
                        && live.first?.bundleURL?.resolvingSymlinksInPath().path == bundle && !owned.isTerminated
                }
                func guardAction() throws {
                    try require(Date() < deadline && sameOwned(), "PID/bundle/launchDate/deadline before each input or capture")
                    let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                        root.appendingPathComponent("ui-isolation-receipt.json"))) as? [String: Any])
                    let args = try XCTUnwrap(receipt["arguments"] as? [String])
                    try require(args.count == app.launchArguments.count + 1, "Exact argv length")
                    try require(URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().path == executable
                        && Array(args.dropFirst()) == app.launchArguments, "Canonical executable/exact argv tail")
                    try require((receipt["pid"] as? NSNumber)?.int32Value == pid
                        && receipt["nonce"] as? String == app.launchEnvironment["INCOMECLOCK_UI_ISOLATION_NONCE"]
                        && receipt["root"] as? String == root.resolvingSymlinksInPath().path
                        && receipt["bundle"] as? String == bundle, "Receipt identity")
                }
                // Minimal positive receipt establishes ownership before full argv verification.
                // An absent/mismatched receipt cannot authorize killing a process; throw, stop
                // the batch and retain diagnostics for operator attention, never terminate by name.
                try require(bundle == allowedBundle && sameOwned(), "Allowed sibling app")
                let ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                    root.appendingPathComponent("ui-isolation-receipt.json"))) as? [String: Any])
                try require((ownership["pid"] as? NSNumber)?.int32Value == pid
                    && ownership["nonce"] as? String == nonce
                    && ownership["root"] as? String == root.resolvingSymlinksInPath().path
                    && ownership["bundle"] as? String == bundle, "Positive ownership receipt; otherwise stop without termination")
                func stopOwned() {
                    guard sameOwned() else { return }
                    _ = owned.terminate()
                    let grace = Date().addingTimeInterval(2)
                    while !owned.isTerminated && Date() < grace {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    if !owned.isTerminated && sameOwned() {
                        _ = owned.forceTerminate()
                        let forced = Date().addingTimeInterval(1)
                        while !owned.isTerminated && Date() < forced {
                            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                        }
                    }
                    XCTAssertTrue(owned.isTerminated, "Positively owned PID must finish bounded teardown")
                }
                addTeardownBlock { stopOwned() }
                defer { stopOwned() }
                try guardAction()
                try verifyIsolation(app, root: root)
                let status = app.statusItems["income-clock-menu-bar-extra"]
                let menu = status.menus.firstMatch
                let panel = app.dialogs["可视收入打卡机"]
                func attach(_ element: XCUIElement, _ name: String) throws {
                    try guardAction()
                    let png = element.screenshot().pngRepresentation
                    try require(!png.isEmpty && png.count <= 5 * 1024 * 1024, "Original native PNG <=5MiB")
                    let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    image.name = caseName + "-" + name + ".png"; image.lifetime = .keepAlways; add(image)
                    try guardAction()
                    let text = element.debugDescription
                    try require(text.utf8.count <= 24_576, "Full AX must fit cap; truncation is not evidence")
                    let ax = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
                    ax.name = caseName + "-" + name + "-AX"; ax.lifetime = .keepAlways; add(ax)
                    let extent = XCTAttachment(string: "AX total bytes=\(text.utf8.count); retained=\(min(text.utf8.count, 24576))")
                    extent.name = caseName + "-" + name + "-AX-extent"; extent.lifetime = .keepAlways; add(extent)
                }
                func unchanged() throws {
                    try require(try Data(contentsOf: settingsURL) == settingsBefore, "Settings byte-identical")
                    try require(try Data(contentsOf: todayURL) == todayBefore, "Today byte-identical")
                }
                func inspectMenu(_ titles: [String], completed: Bool) throws {
                    try guardAction()
                    if completed {
                        if menu.exists {
                            try guardAction()
                            app.typeKey(.escape, modifierFlags: [])
                            let closeAllowance = min(5, deadline.timeIntervalSinceNow)
                            try require(closeAllowance > 0, "Deadline before closing previous native Menu")
                            try require(waitUntil(menu, exists: false, timeout: closeAllowance),
                                "Previous native Menu closes within owned bounded window")
                        }
                        try guardAction()
                        try require(!menu.exists, "Previous native Menu closed before fresh diagnostic window")
                        let diagnosticURL = root.appendingPathComponent("native-menu-contrast-diagnostic.json")
                        let previous = try Data(contentsOf: diagnosticURL)
                        try require(previous.count <= 65_536, "Bounded prior native diagnostic")
                        let preserved = XCTAttachment(data: previous, uniformTypeIdentifier: "public.json")
                        preserved.name = caseName + "-pre-completed-diagnostic"
                        preserved.lifetime = .keepAlways; add(preserved)
                        try guardAction()
                        try Data("[]".utf8).write(to: diagnosticURL, options: .atomic)
                    }
                    try guardAction(); app.activate()
                    try require(status.waitForExistence(timeout: 5), "Owned statusItem exists")
                    try guardAction(); status.click()
                    try require(menu.waitForExistence(timeout: 5), "Native Menu opened")
                    let frame = menu.frame
                    try require(frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite
                        && frame.height.isFinite && frame.width > 0 && frame.height > 0, "Finite native Menu frame")
                    let controls = ["隐藏收入面板"] + (completed ? [] : ["打卡下班"])
                        + ["打开设置…", "始终置顶", "全屏应用时隐藏", "登录时启动", "退出可视收入打卡机"]
                    var bottom = frame.minY
                    for title in titles {
                        let labels = status.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title))
                        try require(labels.count == 1, "Unique exact summary: " + title)
                        let label = labels.firstMatch
                        try require(frame.contains(label.frame) && label.frame.height > 0 && label.frame.minY >= bottom,
                            "Summary geometry/order: " + title)
                        bottom = label.frame.maxY
                    }
                    for title in controls {
                        // Existing native tests prove AXTitle lookup via this subscript.
                        let item = status.menuItems[title]
                        try require(item.exists, "Exact native command: " + title)
                        try require(item.isEnabled && frame.contains(item.frame) && item.frame.height > 0
                            && item.frame.minY >= bottom, "Command geometry/order: " + title)
                        bottom = item.frame.maxY
                    }
                    try require(!status.menuItems["打卡上班"].exists && status.textFields.count == 0, "No clockIn/editable summary")
                    if completed { try require(!status.menuItems["打卡下班"].exists, "Completed has no clockOut") }
                    let data = try Data(contentsOf: root.appendingPathComponent("native-menu-contrast-diagnostic.json"))
                    try require(data.count <= 65_536, "Bounded native diagnostic")
                    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    let entry = try XCTUnwrap(entries.last)
                    try require((entry["itemCount"] as? NSNumber)?.intValue == (completed ? 11 : 12)
                        && (entry["summaryCount"] as? NSNumber)?.intValue == 2, "Exact native item and summary count")
                    try require(entry["bestMatchingAppearance"] as? String == appearance, "Actual native Menu appearance")
                    try require(entry["summaryHasInformationRow"] as? [Bool] == [true, true]
                        && entry["summaryHasAction"] as? [Bool] == [false, false]
                        && entry["summaryEnabled"] as? [Bool] == [false, false], "Native summary semantics")
                    let diagnostic = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    diagnostic.name = caseName + (completed ? "-completed" : "-initial") + "-diagnostic"
                    diagnostic.lifetime = .keepAlways; add(diagnostic)
                    try attach(menu, completed ? "completed-menu" : "menu")
                }
                try inspectMenu(waiting ? ["已打卡 · 等待开工", "今日已获得 ¥0.000 · 距离开始 01:00:00"]
                    : ["计薪已停止", "今日已获得 ¥900.00 · 请打卡下班"], completed: false)
                try unchanged()
                try guardAction(); status.menuItems["打卡下班"].click()
                if waiting {
                    try require(panel.buttons["确认下班"].waitForExistence(timeout: 5) && panel.buttons["取消"].exists,
                        "Early clockOut opens confirmation")
                    try unchanged(); try attach(panel, "confirmation")
                    try guardAction(); panel.buttons["取消"].click()
                    try require(waitUntil(panel.buttons["确认下班"], exists: false) && panel.buttons["打卡下班"].exists,
                        "Cancel returns to waiting panel")
                    try unchanged()
                } else {
                    try require(eventually {
                        guard let actual = try? self.record(root, "today.json") else { return false }
                        return actual["revision"] as? String == "2" && (actual["clockOutAtMs"] as? NSNumber)?.int64Value == now
                    }, "Direct clockOut commits exact revision/time")
                    try require(!panel.buttons["确认下班"].exists, "Direct branch has no confirmation")
                    let actual = try record(root, "today.json")
                    var expected = today
                    expected["revision"] = "2"; expected["clockOutAtMs"] = now; expected["updatedAtMs"] = now
                    try require(NSDictionary(dictionary: actual).isEqual(to: expected), "All Today fields exact")
                    try require(try Data(contentsOf: settingsURL) == settingsBefore, "Direct branch preserves Settings")
                    let committed = try Data(contentsOf: todayURL)
                    try inspectMenu(["今日已完成", "最终收入 ¥900.00"], completed: true)
                    try require(try Data(contentsOf: todayURL) == committed, "Completed Menu preserves Today")
                    try require(try Data(contentsOf: settingsURL) == settingsBefore, "Completed Menu preserves Settings")
                }
                let recordEvidence = XCTAttachment(data: try Data(contentsOf: todayURL), uniformTypeIdentifier: "public.json")
                recordEvidence.name = caseName + "-final-today"; recordEvidence.lifetime = .keepAlways; add(recordEvidence)
                if menu.exists { try guardAction(); app.typeKey(.escape, modifierFlags: []) }
                try guardAction()
                stopOwned()
                try require(owned.isTerminated, "Owned app exited before next serial case")
            }
        }
    }

    func testNativeInformationalMenuRowsKeepTextAndSafeNavigation() throws {
        for appearance in ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"] {
            let root = try isolatedRoot("MenuInformationRows")
            try prepareHiddenPanelState(at: root)
            let settingsURL = root.appendingPathComponent("Records/settings.json")
            let before = try Data(contentsOf: settingsURL)
            let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0,
                nativeMenuDiagnostic: true, nativeMenuRowsAppearance: appearance)
            defer { app.terminate() }
            let status = app.statusItems["income-clock-menu-bar-extra"]
            let menu = status.menus.firstMatch
            let titles = ["今日未打卡", "今日已获得 ¥0.00"]
            func openMenu() {
                app.activate()
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                status.click()
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
            }
            func noBusinessChange() throws {
                XCTAssertEqual(try Data(contentsOf: settingsURL), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
            }
            openMenu()
            let entriesURL = root.appendingPathComponent("native-menu-contrast-diagnostic.json")
            let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entriesURL)) as? [[String: Any]])
            let entry = try XCTUnwrap(entries.last)
            XCTAssertEqual(entry["bestMatchingAppearance"] as? String, appearance,
                "Requested appearance is not evidence of the actual native menu appearance")
            XCTAssertEqual(entry["summaryHasInformationRow"] as? [Bool], [true, true])
            XCTAssertEqual(entry["summaryHasAction"] as? [Bool], [false, false])
            XCTAssertEqual(entry["summaryEnabled"] as? [Bool], [false, false])
            XCTAssertTrue(menu.frame.width.isFinite && menu.frame.height.isFinite)
            XCTAssertGreaterThan(menu.frame.width, 0)
            XCTAssertGreaterThan(menu.frame.height, 0)
            for title in titles {
                let labels = status.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title))
                XCTAssertEqual(labels.count, 1, "One accessibility static text per informational row")
                let label = labels.firstMatch
                XCTAssertTrue(label.exists, "Exact informational static text: \(title)")
                XCTAssertTrue(menu.frame.contains(label.frame))
                XCTAssertFalse(label.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true)
            }
            XCTAssertEqual(status.textFields.count, 0)
            let original = XCTAttachment(screenshot: menu.screenshot())
            original.name = "Native-Information-Rows-" + appearance
            original.lifetime = .keepAlways
            add(original)
            let ax = XCTAttachment(string: String(status.debugDescription.prefix(24_576)))
            ax.name = "Native-Information-Rows-AX-" + appearance
            ax.lifetime = .keepAlways
            add(ax)
            let diagnostic = XCTAttachment(data: try Data(contentsOf: entriesURL), uniformTypeIdentifier: "public.json")
            diagnostic.name = "Native-Information-Rows-Diagnostic-" + appearance
            diagnostic.lifetime = .keepAlways
            add(diagnostic)

            for title in titles {
                if !menu.exists { openMenu() }
                let label = status.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
                XCTAssertTrue(label.exists)
                label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                XCTAssertFalse(app.windows["com_apple_SwiftUI_Settings_window"].exists)
                XCTAssertEqual(status.textFields.count, 0)
                try noBusinessChange()
            }
            if menu.exists { app.typeKey(.escape, modifierFlags: []) }
            openMenu()
            // Native arrow selection must skip both informational rows. Return
            // is sent only after the safe Settings command is actually selected.
            for command in ["显示收入面板", "打卡上班", "打开设置…"] {
                app.typeKey(.downArrow, modifierFlags: [])
                XCTAssertTrue(status.menuItems[command].isSelected, "Native selected command: \(command)")
            }
            app.typeKey(.return, modifierFlags: [])
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            try noBusinessChange()
            settings.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(waitUntil(settings, exists: false))
            openMenu()
            let openSettings = status.menuItems["打开设置…"]
            XCTAssertTrue(openSettings.isEnabled)
            XCTAssertTrue(menu.frame.contains(openSettings.frame))
            openSettings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            try noBusinessChange()
        }
    }

    func testNativeMenuLongEarningsSummaryUsesNormalRouteAndFits() throws {
        let root = try isolatedRoot("MenuLongSummary")
        try prepareHiddenPanelState(at: root)
        let settingsURL = root.appendingPathComponent("Records/settings.json")
        var settingsRecord = try record(root, "settings.json")
        settingsRecord["dailyWageCents"] = 99_999_999
        try JSONSerialization.data(withJSONObject: settingsRecord, options: [.sortedKeys])
            .write(to: settingsURL, options: .atomic)
        var app = try launchIsolated(root: root, now: try localTimestamp(hour: 9), rate: 0)
        defer { app.terminate() }
        app.activate()
        var status = app.statusItems["income-clock-menu-bar-extra"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let initialMenu = status.menus.firstMatch
        let clockIn = status.menuItems["打卡上班"]
        XCTAssertTrue(clockIn.waitForExistence(timeout: 5))
        XCTAssertTrue(clockIn.isEnabled)
        XCTAssertTrue(clockIn.frame.width.isFinite && clockIn.frame.height.isFinite)
        XCTAssertTrue(clockIn.frame.width > 0 && clockIn.frame.height > 0)
        XCTAssertTrue(initialMenu.frame.contains(clockIn.frame))
        clockIn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let todayURL = root.appendingPathComponent("Records/today.json")
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: todayURL.path) })
        app.terminate()
        let todayBefore = try Data(contentsOf: todayURL)
        let settingsBefore = try Data(contentsOf: settingsURL)
        // Same committed Today, later isolated clock; no post-hoc record edits.
        app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 1,
                                 nativeMenuDiagnostic: true)
        XCTAssertNil(app.launchEnvironment["INCOMECLOCK_NATIVE_MENU_SUMMARY_ROWS"])
        XCTAssertNil(app.launchEnvironment["INCOMECLOCK_NATIVE_MENU_SUMMARY_APPEARANCE"])
        app.activate()
        status = app.statusItems["income-clock-menu-bar-extra"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let menu = status.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(status.staticTexts.matching(NSPredicate(format: "value == %@", "计薪中")).count, 1)
        let summaries = status.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "今日已获得 ¥"))
        XCTAssertEqual(summaries.count, 1)
        let summary = summaries.firstMatch
        let first = nativeStaticText(summary)
        // Capture actual AX property values, not debugDescription's abbreviated display.
        let actualValue = summary.value as? String
        let actualLabel = summary.label
        let actual = XCTAttachment(string: "AXValue=\(actualValue ?? "<nil>")\nAXLabel=\(actualLabel)\nChild=\(first)")
        actual.name = "Native long summary actual AX values before format assertion"
        actual.lifetime = .keepAlways
        add(actual)
        let firstImage = XCTAttachment(screenshot: menu.screenshot())
        firstImage.name = "Native long summary before format assertion"
        firstImage.lifetime = .keepAlways
        add(firstImage)
        XCTAssertFalse(first.contains("...") || first.contains("…"))
        XCTAssertNotNil(first.range(of: #"^今日已获得 ¥[0-9]{3},[0-9]{3}\.[0-9]{3} · 距离下班 [0-9]{2}:[0-9]{2}:[0-9]{2}$"#,
                                    options: .regularExpression))
        XCTAssertTrue(menu.frame.contains(summary.frame))
        XCTAssertEqual(status.textFields.count, 0)
        let entriesURL = root.appendingPathComponent("native-menu-contrast-diagnostic.json")
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entriesURL)) as? [[String: Any]])
        let entry = try XCTUnwrap(entries.last)
        XCTAssertEqual(entry["summaryHasInformationRow"] as? [Bool], [true, true])
        XCTAssertEqual(entry["summaryHasAction"] as? [Bool], [false, false])
        XCTAssertEqual(entry["summaryEnabled"] as? [Bool], [false, false])
        // Record open-menu update behavior without inventing a Contract refresh cadence.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(menu.exists)
        let later = nativeStaticText(summary)
        XCTAssertFalse(later.contains("...") || later.contains("…"))
        XCTAssertTrue(menu.frame.contains(summary.frame))
        let screenshot = XCTAttachment(screenshot: menu.screenshot())
        screenshot.name = "Native-Long-Menu-Summary-Normal-Route"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let observation = XCTAttachment(string: "First=\(first)\nLater=\(later)\nChangedWhileOpen=\(first != later)\n" +
                                        String(status.debugDescription.prefix(24_576)))
        observation.name = "Native long summary geometry and update observation"
        observation.lifetime = .keepAlways
        add(observation)
        let diagnostic = XCTAttachment(data: try Data(contentsOf: entriesURL), uniformTypeIdentifier: "public.json")
        diagnostic.name = "Native long summary normal-route diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try Data(contentsOf: todayURL), todayBefore)
        XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBefore)
        app.terminate()
        // Damage only this stopped application's isolated Settings fixture;
        // retain its valid committed Today while checking the conditional row.
        let damagedSettings = Data("{broken-settings".utf8)
        try damagedSettings.write(to: settingsURL, options: .atomic)
        for appearance in ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"] {
            var appearanceRoot = root
            var appearanceSettingsURL = settingsURL
            var appearanceTodayURL = todayURL
            var appearanceTodayBefore = todayBefore
            if appearance == "NSAppearanceNameDarkAqua" {
                // A fresh isolated root keeps this launch's bounded diagnostic
                // independent of the normal-route and Aqua menu updates.
                appearanceRoot = try isolatedRoot("MenuLongSummaryDark")
                try prepareHiddenPanelState(at: appearanceRoot)
                appearanceSettingsURL = appearanceRoot.appendingPathComponent("Records/settings.json")
                var darkSettings = try record(appearanceRoot, "settings.json")
                darkSettings["dailyWageCents"] = 99_999_999
                try JSONSerialization.data(withJSONObject: darkSettings, options: [.sortedKeys])
                    .write(to: appearanceSettingsURL, options: .atomic)
                let fixtureApp = try launchIsolated(root: appearanceRoot,
                                                    now: try localTimestamp(hour: 9), rate: 0)
                defer { fixtureApp.terminate() }
                fixtureApp.activate()
                let fixtureStatus = fixtureApp.statusItems["income-clock-menu-bar-extra"]
                XCTAssertTrue(fixtureStatus.waitForExistence(timeout: 5))
                fixtureStatus.click()
                let fixtureMenu = fixtureStatus.menus.firstMatch
                let fixtureClockIn = fixtureStatus.menuItems["打卡上班"]
                XCTAssertTrue(fixtureClockIn.waitForExistence(timeout: 5))
                XCTAssertTrue(fixtureClockIn.isEnabled)
                XCTAssertTrue(fixtureMenu.frame.contains(fixtureClockIn.frame))
                fixtureClockIn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                appearanceTodayURL = appearanceRoot.appendingPathComponent("Records/today.json")
                XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: appearanceTodayURL.path) })
                fixtureApp.terminate()
                appearanceTodayBefore = try Data(contentsOf: appearanceTodayURL)
                try damagedSettings.write(to: appearanceSettingsURL, options: .atomic)
            }
            let appearanceEntriesURL = appearanceRoot.appendingPathComponent("native-menu-contrast-diagnostic.json")
            app = try launchIsolated(root: appearanceRoot, now: try localTimestamp(hour: 12), rate: 0,
                                     nativeMenuDiagnostic: true, nativeMenuRowsAppearance: appearance)
            app.activate()
            status = app.statusItems["income-clock-menu-bar-extra"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            status.click()
            let warningMenu = status.menus.firstMatch
            let warning = status.menuItems["设置需要修复"]
            XCTAssertTrue(warning.waitForExistence(timeout: 5))
            XCTAssertTrue(warningMenu.frame.contains(warning.frame))
            let warningEntries = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: appearanceEntriesURL)) as? [[String: Any]])
            let warningEntry = try XCTUnwrap(warningEntries.last)
            XCTAssertEqual(warningEntry["bestMatchingAppearance"] as? String, appearance)
            XCTAssertEqual(warningEntry["summaryCount"] as? Int, 3)
            XCTAssertEqual(warningEntry["summaryHasInformationRow"] as? [Bool], [true, true, true])
            XCTAssertEqual(warningEntry["summaryHasAction"] as? [Bool], [false, false, false])
            XCTAssertEqual(warningEntry["summaryEnabled"] as? [Bool], [false, false, false])
            let labels = status.staticTexts.matching(NSPredicate(format:
                "value == %@ OR label == %@", "设置需要修复", "设置需要修复"))
            XCTAssertEqual(labels.count, 1)
            let warningLabel = labels.firstMatch
            XCTAssertTrue(warningMenu.frame.contains(warningLabel.frame))
            XCTAssertFalse(warningLabel.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true)
            let warningScreenshot = XCTAttachment(screenshot: warningMenu.screenshot())
            warningScreenshot.name = "Native-Third-Warning-Contrast-" + appearance
            warningScreenshot.lifetime = .keepAlways
            add(warningScreenshot)
            let warningAX = XCTAttachment(string: String(status.debugDescription.prefix(24_576)))
            warningAX.name = "Native third warning accessibility - " + appearance
            warningAX.lifetime = .keepAlways
            add(warningAX)
            let warningDiagnostic = XCTAttachment(data: try Data(contentsOf: appearanceEntriesURL), uniformTypeIdentifier: "public.json")
            warningDiagnostic.name = "Native third warning diagnostic - " + appearance
            warningDiagnostic.lifetime = .keepAlways
            add(warningDiagnostic)
            warningLabel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertFalse(app.windows["com_apple_SwiftUI_Settings_window"].exists)
            XCTAssertEqual(try Data(contentsOf: appearanceTodayURL), appearanceTodayBefore)
            XCTAssertEqual(try Data(contentsOf: appearanceSettingsURL), damagedSettings)
            if warningMenu.exists { app.typeKey(.escape, modifierFlags: []) }
            status.click()
            let openSettings = status.menuItems["打开设置…"]
            XCTAssertTrue(openSettings.isEnabled)
            openSettings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertEqual(try Data(contentsOf: appearanceTodayURL), appearanceTodayBefore)
            XCTAssertEqual(try Data(contentsOf: appearanceSettingsURL), damagedSettings)
            app.terminate()
        }
    }

    func testNativeMinimumSettingsSevenPagesKeyboardAndCommittedPreferences() throws {
        let root = try isolatedRoot("MinimumSettingsKeyboard")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0, nativeMenuDiagnostic: true)
        defer { app.terminate() }
        let status = app.statusItems["income-clock-menu-bar-extra"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let nativeSummary = status.menuItems["请先设置工资与工作时间"]
        XCTAssertTrue(nativeSummary.waitForExistence(timeout: 5))
        // AppKit exposes a custom-view MenuItem ancestor as enabled even when
        // its underlying NSMenuItem is disabled. Verify the actual informational
        // role and underlying semantics instead of that ancestor projection.
        let summaryLabel = status.staticTexts.matching(NSPredicate(format:
            "value == %@ OR label == %@", "请先设置工资与工作时间", "请先设置工资与工作时间"))
        XCTAssertEqual(summaryLabel.count, 1)
        XCTAssertFalse(summaryLabel.firstMatch.debugDescription.components(separatedBy: "\n")
            .first?.contains("Keyboard Focused") == true)
        XCTAssertEqual(status.textFields.count, 0)
        let summaryEntries = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("native-menu-contrast-diagnostic.json"))) as? [[String: Any]])
        let summaryEntry = try XCTUnwrap(summaryEntries.last)
        XCTAssertEqual(summaryEntry["summaryHasInformationRow"] as? [Bool], [true, true])
        XCTAssertEqual(summaryEntry["summaryHasAction"] as? [Bool], [false, false])
        XCTAssertEqual(summaryEntry["summaryEnabled"] as? [Bool], [false, false])
        let menuTree = XCTAttachment(string: status.debugDescription)
        menuTree.name = "Current native attributed summary accessibility"
        menuTree.lifetime = .keepAlways
        add(menuTree)
        attach(app, "Current-Native-Menu-Summary-Contrast")
        let diagnosticURL = root.appendingPathComponent("native-menu-contrast-diagnostic.json")
        let diagnosticText = (try? String(contentsOf: diagnosticURL, encoding: .utf8)) ?? "No opt-in native menu diagnostic file"
        let diagnosticAttachment = XCTAttachment(string: String(diagnosticText.prefix(16_384)))
        diagnosticAttachment.name = "Native menu observer and matching diagnostic"
        diagnosticAttachment.lifetime = .keepAlways
        add(diagnosticAttachment)
        app.typeKey(.escape, modifierFlags: [])
        let settings = try openSettings(app)
        // The external authorized wrapper enables/restores Keyboard Navigation.
        // Do not change any system preference or use AXPress / private focus APIs here.
        let viewport = settings.scrollViews.firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        var trace: [String] = []
        addTeardownBlock {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "Minimum Settings geometry and native keyboard trace"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        func resizeWidthBy(_ delta: CGFloat) {
            let edge = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.click(forDuration: 0.15, thenDragTo: edge.withOffset(CGVector(dx: delta, dy: 0)))
        }
        func resizeHeightBy(_ delta: CGFloat) {
            let edge = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: -1))
            edge.click(forDuration: 0.15, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: delta)))
        }
        let display = try primaryVisibleFrameInAccessibilityCoordinates()
        let beforePlacement = settings.frame
        let expandedHere = CGRect(origin: beforePlacement.origin,
            size: CGSize(width: beforePlacement.width + 100, height: beforePlacement.height + 100))
        if !display.contains(expandedHere) {
            // The previous original ended at display.maxX; its +100 drag was
            // outside the physical display. Move only our Settings title strip.
            let origin = CGPoint(x: display.minX + 100, y: display.minY + 80)
            let expansion = CGRect(origin: origin,
                size: CGSize(width: beforePlacement.width + 100, height: beforePlacement.height + 100))
            guard display.contains(expansion) else {
                XCTFail("Current display cannot contain both independently enlarged Settings dimensions")
                return
            }
            let title = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 12))
            title.click(forDuration: 0.15, thenDragTo: title.withOffset(
                CGVector(dx: origin.x - beforePlacement.minX, dy: origin.y - beforePlacement.minY)))
            // Placement is test setup: the native drag can consume a small
            // threshold before moving. Require real on-screen resize headroom,
            // rather than an exact arbitrary setup origin.
            XCTAssertTrue(eventually {
                let frame = settings.frame
                return display.contains(CGRect(origin: frame.origin,
                    size: CGSize(width: frame.width + 100, height: frame.height + 100)))
            }, "Own Settings title drag must leave both resize endpoints on-screen")
            trace.append("Placement requested=\(origin), actual=\(settings.frame)")
            XCTAssertEqual(settings.frame.width, beforePlacement.width, accuracy: 2)
            XCTAssertEqual(settings.frame.height, beforePlacement.height, accuracy: 2)
        }
        let original = settings.frame
        let verifiedExpansion = CGRect(origin: original.origin,
            size: CGSize(width: original.width + 100, height: original.height + 100))
        guard display.contains(verifiedExpansion) else {
            XCTFail("Both resize endpoints require actual display headroom")
            return
        }
        trace.append("Resize placement before=\(beforePlacement), display=\(display), verifiedExpansion=\(verifiedExpansion)")
        trace.append("Before resize outer=\(original), viewport=\(viewport.frame)")
        resizeWidthBy(100)
        XCTAssertTrue(eventually { settings.frame.width > original.width + 40 },
            "Native middle-right edge must actually enlarge Settings width")
        XCTAssertEqual(settings.frame.height, original.height, accuracy: 2)
        let wider = settings.frame
        let heightExpansion = CGRect(origin: wider.origin,
            size: CGSize(width: wider.width, height: wider.height + 100))
        guard display.contains(heightExpansion) else {
            XCTFail("Actual window after width resize must retain height-growth headroom")
            return
        }
        resizeHeightBy(100)
        XCTAssertTrue(eventually { settings.frame.height > wider.height + 40 },
            "Native middle-bottom edge must actually enlarge Settings height")
        XCTAssertEqual(settings.frame.width, wider.width, accuracy: 2)
        trace.append("Enlarged by separate edges outer=\(settings.frame), viewport=\(viewport.frame)")
        resizeWidthBy(-700)
        resizeHeightBy(-700)
        XCTAssertTrue(eventually { abs(settings.frame.width - 680) <= 2 && abs(viewport.frame.height - 500) <= 2 },
            "Native shrink must clamp at 680-wide window / 500-high content, not a fabricated 500-high outer frame")
        let minimum = settings.frame
        let chromeHeight = minimum.height - viewport.frame.height
        trace.append("Minimum outer=\(minimum), viewport=\(viewport.frame), actual chrome height=\(chromeHeight)")
        XCTAssertGreaterThan(chromeHeight, 0)
        XCTAssertEqual(viewport.frame.maxY, minimum.maxY, accuracy: 2)
        XCTAssertEqual(viewport.frame.minY - minimum.minY, chromeHeight, accuracy: 2)
        resizeWidthBy(-60)
        resizeHeightBy(-60)
        XCTAssertEqual(settings.frame.width, minimum.width, accuracy: 2)
        XCTAssertEqual(settings.frame.height, minimum.height, accuracy: 2)

        func isFocused(_ element: XCUIElement) -> Bool {
            guard element.exists else { return false }
            return element.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true
        }
        func visible(_ element: XCUIElement, inContent: Bool = true) {
            XCTAssertTrue(element.exists)
            let bounds = inContent ? viewport.frame : settings.frame
            XCTAssertGreaterThan(element.frame.width, 0)
            XCTAssertGreaterThan(element.frame.height, 0)
            XCTAssertTrue(bounds.insetBy(dx: -2, dy: -2).contains(element.frame),
                "Control must be fully visible after native focus / automatic scroll: \(element.debugDescription)")
            XCTAssertTrue(element.isHittable)
        }
        func focus(_ element: XCUIElement, reverse: Bool = false) {
            // Offscreen SwiftUI controls can be zero-frame Other placeholders.
            // Native Tab must materialize/focus/scroll the exact target within
            // the same bound; do not require a button snapshot before traversal.
            for step in 0...24 {
                if isFocused(element) {
                    let inContent = !element.identifier.hasPrefix("settings-nav-")
                    XCTAssertTrue(eventually {
                        let bounds = inContent ? viewport.frame : settings.frame
                        return element.frame.width > 0 && element.frame.height > 0 &&
                            bounds.insetBy(dx: -2, dy: -2).contains(element.frame) && element.isHittable
                    }, "Actual focused control must become fully visible after its layout transaction: " +
                        "target=\(element.identifier), frame=\(element.frame), viewport=\(viewport.frame), " +
                        "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
                    trace.append("\(reverse ? "Shift-Tab" : "Tab") steps=\(step): \(element.debugDescription.components(separatedBy: "\n").first ?? "")")
                    visible(element, inContent: inContent)
                    return
                }
                if step < 24 {
                    app.typeKey(.tab, modifierFlags: reverse ? .shift : [])
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            XCTFail("Native bounded Tab traversal did not reach the required target within 24 steps")
        }
        func page(_ title: String, reverse: Bool = false) {
            let navigation = settings.buttons["settings-nav-" + title]
            focus(navigation, reverse: reverse)
            app.typeKey(.space, modifierFlags: [])
            let content = settings.descendants(matching: .any).matching(identifier: "settings-page-" + title).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5), "Native Space must select \(title)")
            XCTAssertEqual(settings.frame.width, minimum.width, accuracy: 2)
            XCTAssertEqual(settings.frame.height, minimum.height, accuracy: 2)
        }
        func screenshot(_ title: String) {
            let attachment = XCTAttachment(screenshot: settings.screenshot())
            attachment.name = "Minimum-Settings-" + title
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        page("工作规则")
        let wage = settings.textFields["settings-wage"]
        focus(wage)
        app.typeKey("a", modifierFlags: .command)
        // Native synthesized single-key events avoid the observed trailing
        // character loss in one batched typeText event; keep exact value proof.
        for character in "321.09" {
            app.typeKey(String(character), modifierFlags: [])
        }
        XCTAssertEqual(wage.value as? String, "321.09")
        let start = settings.textFields["settings-start"]
        focus(start)
        editTimeDigits("09:00", into: start)
        let end = settings.textFields["settings-end"]
        focus(end)
        editTimeDigits("18:00", into: end)
        focus(start, reverse: true)
        XCTAssertEqual(start.value as? String, "09:00")
        let save = settings.buttons["settings-save"]
        focus(save)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(isFocused(save), "Pre-save screenshot must show actual enabled Save keyboard focus")
        let focusedSaveTree = XCTAttachment(string: save.debugDescription)
        focusedSaveTree.name = "Enabled Save keyboard focus before commit"
        focusedSaveTree.lifetime = .keepAlways
        add(focusedSaveTree)
        screenshot("工作规则-保存前焦点")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        XCTAssertEqual(try record(root, "settings.json")["dailyWageCents"] as? Int64, 32_109)
        XCTAssertEqual(try record(root, "settings.json")["workStartMinuteOfDay"] as? Int, 540)
        XCTAssertEqual(try record(root, "settings.json")["workEndMinuteOfDay"] as? Int, 1080)
        XCTAssertFalse(save.isEnabled, "Committed unchanged work rules must disable Save")
        let savedSettingsTree = XCTAttachment(string: settings.debugDescription)
        savedSettingsTree.name = "Committed Settings Save state and geometry"
        savedSettingsTree.lifetime = .keepAlways
        add(savedSettingsTree)
        screenshot("工作规则")

        page("通用", reverse: true)
        let sounds = settings.checkBoxes["皮肤提示音"]
        focus(sounds)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["themeSoundsEnabled"] as? Bool) == true })
        focus(sounds)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["themeSoundsEnabled"] as? Bool) == false })
        screenshot("通用")

        page("面板与启动")
        let lock = settings.checkBoxes["锁定面板位置"]
        focus(lock)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "settings.json")["lockPanelPosition"] as? Bool) == true })
        focus(lock)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "settings.json")["lockPanelPosition"] as? Bool) == false })
        focus(settings.buttons["恢复默认面板位置"])
        screenshot("面板与启动")

        let businessBeforeTheme = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        page("外观与皮肤")
        let companion = settings.buttons["theme-preview-app.incomeclock.window-companion"]
        focus(companion)
        app.typeKey(.space, modifierFlags: [])
        let use = settings.buttons["theme-use"]
        focus(use)
        XCTAssertTrue(use.isEnabled)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "app.incomeclock.window-companion" })
        // Current-card label is an observation, not another required focus sequence.
        // Materialize it by native scroll only; retain first preview/Use keyboard actions
        // and the following native Tab-to-reset/Space action.
        let selectedCompanion = revealSettingsButton(
            "theme-preview-app.incomeclock.window-companion", in: settings, towardTop: true)
        XCTAssertTrue(selectedCompanion.label.contains("正在使用"))
        app.activate()
        XCTAssertTrue(eventually { app.state == .runningForeground },
            "Own app must regain foreground before the next native keyboard traversal")
        focus(settings.buttons["恢复默认皮肤"])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(eventually { (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "app.incomeclock.warm-island" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), businessBeforeTheme)
        screenshot("外观与皮肤")

        page("数据与隐私")
        let reset = settings.buttons["重置今日记录…"]
        visible(reset)
        XCTAssertFalse(reset.isEnabled, "Valid/no Today data must not enable destructive recovery")
        screenshot("数据与隐私")
        page("快捷键")
        visible(settings.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "⌥⌘I", "⌥⌘I")).firstMatch)
        screenshot("快捷键")
        page("关于")
        visible(settings.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "macOS 13", "macOS 13")).firstMatch)
        screenshot("关于")
        page("工作规则", reverse: true)
        focus(settings.textFields["settings-wage"])
        XCTAssertEqual(settings.textFields["settings-wage"].value as? String, "321.09")
        XCTAssertFalse(settings.buttons["settings-save"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
        let beforeError = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        focus(start)
        editTimeDigits("25:00", into: start)
        focus(save)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(settings.staticTexts["请使用 HH:mm 的 24 小时时间。"].waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { isFocused(start) })
        XCTAssertTrue(save.isEnabled)
        trace.append("Native invalid start focused=\(isFocused(start)); Save enabled=\(save.isEnabled)")
        attach(app, "Current-Native-Settings-Error-Save-StartFocus-Contrast")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), beforeError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
    }

    func testDamagedSettingsResetCancellationAndExplicitReplacementKeepCorrectSurfaces() throws {
        let root = try isolatedRoot("DamagedSettings")
        let records = root.appendingPathComponent("Records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let settingsURL = records.appendingPathComponent("settings.json")
        let damaged = Data("{invalid-settings".utf8)
        try damaged.write(to: settingsURL)
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
        defer { app.terminate() }
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.staticTexts["设置数据无法读取"].waitForExistence(timeout: 5))
        XCTAssertFalse(panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch.exists)
        XCTAssertFalse(panel.buttons["打卡上班"].exists)
        panel.buttons["重置设置…"].click()
        XCTAssertTrue(panel.buttons["确认重置"].waitForExistence(timeout: 5))
        panel.buttons["取消"].click()
        XCTAssertTrue(panel.staticTexts["设置数据无法读取"].waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: settingsURL), damaged)
        panel.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "打开设置", "gearshape")).firstMatch.click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["设置数据无法读取"].exists)
        replace(settings.textFields["settings-wage"], with: "300.00")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        XCTAssertEqual(settings.buttons["settings-save"].label, "确认替换设置")
        XCTAssertTrue(settings.buttons["settings-save"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: settingsURL), damaged, "Opening and editing recovery UI must preserve the damaged record until confirmation")
        XCTAssertFalse(settings.staticTexts["设置已保存"].exists)
        XCTAssertFalse(panel.buttons["打卡上班"].exists)
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        let repairedSettings = try record(root, "settings.json")
        XCTAssertEqual(repairedSettings["dailyWageCents"] as? Int64, 30_000)
        XCTAssertEqual(repairedSettings["workStartMinuteOfDay"] as? Int, 540)
        XCTAssertEqual(repairedSettings["workEndMinuteOfDay"] as? Int, 1_080)
        XCTAssertFalse(try XCTUnwrap(repairedSettings["revision"] as? String).isEmpty)
        XCTAssertNotEqual(try Data(contentsOf: settingsURL), damaged)
        XCTAssertFalse(settings.staticTexts["设置数据无法读取"].exists)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.buttons["打卡上班"].isEnabled)
        XCTAssertFalse(panel.staticTexts["设置数据无法读取"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: records.appendingPathComponent("today.json").path))
        attach(app, "Damaged-Settings-Explicit-Replacement")
    }

    func testWaitingClockOutCancelPreservesRecordAndConfirmSettlesZero() throws {
        let root = try isolatedRoot("WaitingClockOut")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 8), rate: 0)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "300.00")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let amount = panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        XCTAssertEqual(amount.value as? String, amountVoiceValue(0, live: true))
        let bytes = try Data(contentsOf: root.appendingPathComponent("Records/today.json"))
        panel.buttons["打卡下班"].click()
        XCTAssertTrue(panel.buttons["确认下班"].waitForExistence(timeout: 5))
        let estimate = panel.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "预计结算", "预计结算")).firstMatch
        XCTAssertTrue(nativeStaticText(estimate).contains("¥0.00"))
        let duration = panel.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "预计计薪", "预计计薪")).firstMatch
        XCTAssertTrue(nativeStaticText(duration).contains("00:00:00"))
        panel.buttons["取消"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), bytes)
        panel.buttons["打卡下班"].click()
        XCTAssertTrue(panel.buttons["确认下班"].waitForExistence(timeout: 5))
        panel.buttons["确认下班"].click()
        XCTAssertTrue(eventually { (amount.value as? String) == self.amountVoiceValue(0, live: false) })
        let today = try record(root, "today.json")
        let clockOut = try XCTUnwrap(today["clockOutAtMs"] as? Int64)
        XCTAssertLessThan(clockOut, try XCTUnwrap(today["scheduledStartAtMs"] as? Int64))
        XCTAssertEqual(try expectedAmount(today, at: clockOut, live: false), 0)
        XCTAssertFalse(panel.buttons["打卡下班"].exists)
        attach(app, "Waiting-Explicit-Zero-Settlement")
    }

    func testClosingSettingsDuringEarningKeepsSameTodayAndContinuesLiveAmount() throws {
        let root = try isolatedRoot("CloseSettingsEarning")
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 1)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "999999.99")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let panel = app.dialogs["可视收入打卡机"]
        XCTAssertTrue(panel.buttons["打卡上班"].waitForExistence(timeout: 5))
        panel.buttons["打卡上班"].click()
        XCTAssertTrue(panel.buttons["打卡下班"].waitForExistence(timeout: 5))
        let amount = panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "今日已获得")).firstMatch
        let todayBytes = try Data(contentsOf: root.appendingPathComponent("Records/today.json"))
        _ = try openSettings(app)
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(settings.staticTexts["修改将于明日生效"].exists)
        let whileOpen = amount.value as? String
        print("Stage9 native amount AX value: " + String(describing: amount.value))
        XCTAssertFalse(whileOpen?.isEmpty ?? true, "Amount must expose its concrete accessible value")
        XCTAssertTrue(eventually { (amount.value as? String) != whileOpen })
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitUntil(settings, exists: false))
        XCTAssertTrue(panel.buttons["打卡下班"].exists)
        let afterClose = amount.value as? String
        XCTAssertNotNil(afterClose)
        XCTAssertTrue(eventually { (amount.value as? String) != afterClose })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/today.json")), todayBytes)
        XCTAssertNil(try record(root, "today.json")["clockOutAtMs"] as? Int64)
        attach(app, "Settings-Closed-Earning-Continues")
    }

    func testSystemFileChooserPreviewInstallExplicitUseAndDeleteFallback() throws {
        let root = try isolatedRoot("ThemeFileChooser")
        let originalPackage = try writeMinimalUIThemePackage(in: root)
        let (_, package) = try shortNativeInputFixture(originalPackage: originalPackage, isolatedRoot: root)
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
        defer { app.terminate() }
        let settings = try openSettings(app)
        replace(settings.textFields["settings-wage"], with: "300.00")
        replace(settings.textFields["settings-start"], with: "09:00")
        replace(settings.textFields["settings-end"], with: "18:00")
        settings.buttons["settings-save"].click()
        XCTAssertTrue(settings.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        let businessBefore = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        settings.buttons["外观与皮肤"].click()
        let restoreDefault = settings.buttons["恢复默认皮肤"]
        XCTAssertTrue(restoreDefault.exists)
        XCTAssertFalse(restoreDefault.isEnabled)
        let installedDirectory = root.appendingPathComponent("Themes/com.example.ui-closeout")
        let preview = app.descendants(matching: .any).matching(identifier: "theme-import-preview").firstMatch
        chooseThemePackage(package, app: app, settings: settings)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["theme-import-confirm"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedDirectory.path))
        app.buttons["theme-import-cancel"].click()
        XCTAssertTrue(waitUntil(preview, exists: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), businessBefore)
        chooseThemePackage(package, app: app, settings: settings)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.buttons["theme-import-confirm"].click()
        XCTAssertTrue(waitUntil(preview, exists: false))
        let card = settings.buttons["theme-preview-com.example.ui-closeout"]
        let defaultCard = settings.buttons["theme-preview-app.incomeclock.warm-island"]
        func revealThemeCards() {
            // The lower install action scrolls both LazyVGrid rows out of view.
            // One native scroll returns to the page top before reading card labels.
            let viewport = settings.scrollViews.firstMatch
            let page = settings.descendants(matching: .any)
                .matching(identifier: "settings-page-外观与皮肤").firstMatch
            XCTAssertTrue(viewport.exists && page.exists)
            let pageHeight = page.frame.height
            XCTAssertGreaterThan(pageHeight, 0)
            XCTAssertLessThanOrEqual(pageHeight, 4096)
            viewport.scroll(byDeltaX: 0, deltaY: max(pageHeight, viewport.frame.height))
            XCTAssertTrue(eventually {
                defaultCard.exists && defaultCard.isHittable &&
                    defaultCard.frame.width > 0 && defaultCard.frame.height > 0
            }, "Native scroll must materialize the actual built-in card")
            if FileManager.default.fileExists(atPath: installedDirectory.path) {
                XCTAssertTrue(eventually {
                    card.exists && card.isHittable && card.frame.width > 0 && card.frame.height > 0
                }, "Native scroll must materialize the actual installed card")
            }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(defaultCard.label.contains("正在使用"))
        XCTAssertFalse(card.label.contains("正在使用"), "Installation must not silently select the new theme")
        let use = settings.buttons["theme-use-imported"]
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        XCTAssertTrue(use.isEnabled)
        // Installed package offers details/use/delete even before becoming current.
        card.click()
        let detailsUse = settings.buttons["theme-use"]
        let delete = settings.buttons["theme-delete-request"]
        XCTAssertTrue(detailsUse.waitForExistence(timeout: 5))
        XCTAssertTrue(detailsUse.isEnabled)
        XCTAssertTrue(delete.exists)
        XCTAssertTrue(delete.isEnabled)
        XCTAssertTrue(settings.staticTexts["已安装"].exists)
        XCTAssertTrue(defaultCard.label.contains("正在使用"))
        XCTAssertFalse(card.label.contains("正在使用"))
        use.click()
        XCTAssertTrue(eventually {
            (try? self.record(root, "theme-preferences.json")["selectedThemeId"] as? String) == "com.example.ui-closeout"
        })
        revealThemeCards()
        XCTAssertTrue(eventually { card.label.contains("正在使用") })
        XCTAssertEqual(try record(root, "theme-preferences.json")["selectedThemeId"] as? String, "com.example.ui-closeout")
        XCTAssertFalse(detailsUse.isEnabled)
        XCTAssertTrue(restoreDefault.exists)
        XCTAssertTrue(restoreDefault.isEnabled)
        card.click()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        let confirm = app.buttons["theme-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: installedDirectory.path) })
        revealThemeCards()
        XCTAssertTrue(eventually { !card.exists && defaultCard.label.contains("正在使用") })
        XCTAssertEqual(try record(root, "theme-preferences.json")["selectedThemeId"] as? String, "app.incomeclock.warm-island")
        XCTAssertTrue(restoreDefault.exists)
        XCTAssertFalse(restoreDefault.isEnabled)
        defaultCard.click()
        XCTAssertTrue(settings.buttons["theme-use"].waitForExistence(timeout: 5))
        XCTAssertFalse(settings.buttons["theme-use"].isEnabled)
        XCTAssertFalse(delete.exists)
        let builtinB = settings.buttons["theme-preview-app.incomeclock.window-companion"]
        XCTAssertTrue(builtinB.exists, "Deleting an installed skin retains both built-ins")
        builtinB.click()
        XCTAssertTrue(settings.buttons["theme-use"].isEnabled)
        XCTAssertFalse(delete.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), businessBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
        attach(app, "File-Chooser-Install-Use-Delete-Default")
    }

    private func chooseThemePackage(_ package: URL, app: XCUIApplication, settings: XCUIElement) {
        let open = settings.buttons["theme-import-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        // Wait for each native panel transition before sending the next event.
        // These IDs were observed in the exact isolated app's NSOpenPanel flow.
        let chooser = app.sheets["open-panel"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        chooser.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: [.command])
        // Allow native completion to settle between bounded input chunks.
        // The exact full path is still required before committing the selection.
        let characters = Array(package.path)
        for offset in stride(from: 0, to: characters.count, by: 16) {
            pathField.typeText(String(characters[offset..<min(offset + 16, characters.count)]))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(pathField.value as? String, package.path)
        // The retained failure raster shows the chooser inactive after full
        // path entry. Restore its real field focus before native Return.
        pathField.click()
        XCTAssertEqual(app.state, .runningForeground)
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(pathField, exists: false))
        guard chooser.exists, app.state == .runningForeground else {
            attach(app, "Chooser-Service-Disappeared-After-Path-Return")
            XCTFail("Path field disappearance alone is not selection: native open panel must survive Return")
            return
        }
        let accept = chooser.buttons["OKButton"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        XCTAssertTrue(eventually { accept.isEnabled })
        accept.click()
        XCTAssertTrue(waitUntil(chooser, exists: false))
    }

    func testNativeFinderFileDragValidPreviewAndUnsupportedRejection() throws {
        let root = try isolatedRoot("NativeThemeDrag")
        // This existing isolated fixture hides the unrelated floating panel,
        // so Finder interaction cannot treat it as an interrupting dialog.
        try prepareHiddenPanelState(at: root)
        let originalPackage = try writeMinimalUIThemePackage(in: root)
        let (fixtureFolder, package) = try shortNativeInputFixture(originalPackage: originalPackage, isolatedRoot: root)
        let unsupported = fixtureFolder.appendingPathComponent("unsupported-theme.txt")
        try Data("Not an incomeclocktheme package".utf8).write(to: unsupported, options: .withoutOverwriting)
        let app = try launchIsolated(root: root, now: try localTimestamp(hour: 12), rate: 0)
        defer { app.terminate() }
        let settings = try openSettingsFromMenu(app)
        // prepareHiddenPanelState already committed these exact work rules.
        // Saving the identical amount is disabled and is not part of file-drop acceptance.
        let before = try Data(contentsOf: root.appendingPathComponent("Records/settings.json"))
        let committed = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertEqual(committed["dailyWageCents"] as? Int, 30_000)
        XCTAssertEqual(committed["panelVisible"] as? Bool, false)
        XCTAssertEqual(settings.textFields["settings-wage"].value as? String, "300.00")
        XCTAssertFalse(settings.buttons["settings-save"].isEnabled)
        settings.buttons["外观与皮肤"].click()
        let visible = try primaryVisibleFrameInAccessibilityCoordinates()
        guard visible.width >= settings.frame.width + 548 else {
            throw XCTSkip("Two nonoverlapping native windows do not fit; no cropped-image coordinate guess")
        }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let count = finder.windows.count
        finder.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(eventually { finder.windows.count == count + 1 }, "Only one newly owned Finder window")
        finder.typeKey("g", modifierFlags: [.command, .shift])
        // Exact Sheet type and IDs from this test's Finder PID 635 failure hierarchy.
        let goTo = finder.sheets["GoToWindow"]
        XCTAssertTrue(goTo.waitForExistence(timeout: 5))
        XCTAssertEqual(finder.sheets.matching(identifier: "GoToWindow").count, 1)
        let pathField = goTo.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        let characters = Array(fixtureFolder.path)
        for offset in stride(from: 0, to: characters.count, by: 16) {
            pathField.typeText(String(characters[offset..<min(offset + 16, characters.count)]))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(pathField.value as? String, fixtureFolder.path)
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(goTo, exists: false))
        let owned = finder.windows.matching(NSPredicate(format: "title == %@", fixtureFolder.lastPathComponent)).firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: 5))
        XCTAssertEqual(finder.windows.matching(NSPredicate(format: "title == %@", fixtureFolder.lastPathComponent)).count, 1)
        // Install teardown only after exact full-path entry and a unique owned title.
        // An earlier GoTo failure cannot authorize closing an unidentified Finder window.
        addTeardownBlock {
            let exact = finder.windows.matching(NSPredicate(format: "title == %@", fixtureFolder.lastPathComponent))
            if exact.count == 1 { exact.element.buttons[XCUIIdentifierCloseWindow].click() }
        }
        finder.typeKey("1", modifierFlags: .command) // Icon view for this isolated fixture folder only.
        let right = owned.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        right.click(forDuration: 0.15, thenDragTo: right.withOffset(CGVector(dx: 500 - owned.frame.width, dy: 0)))
        // Keep Finder in place: dragging its title can drag a folder proxy.
        // Resize and position only this app's non-document Settings window.
        app.activate()
        let settingsEdge = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        settingsEdge.click(forDuration: 0.15,
            thenDragTo: settingsEdge.withOffset(CGVector(dx: 680 - settings.frame.width, dy: 0)))
        XCTAssertTrue(eventually { abs(settings.frame.width - 680) <= 2 })
        let finderFrame = owned.frame
        let gap: CGFloat = 24
        let settingsX: CGFloat
        if visible.maxX - finderFrame.maxX >= settings.frame.width + gap {
            settingsX = (finderFrame.maxX + gap + visible.maxX - settings.frame.width) / 2
        } else if finderFrame.minX - visible.minX >= settings.frame.width + gap {
            settingsX = (visible.minX + finderFrame.minX - gap - settings.frame.width) / 2
        } else {
            throw XCTSkip("Existing Finder position leaves no verified Settings slot; do not drag its folder proxy")
        }
        let origin = CGPoint(x: settingsX, y: visible.minY + 40)
        let beforeFrame = settings.frame
        let from = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        let target = from.withOffset(CGVector(dx: origin.x - beforeFrame.minX, dy: origin.y - beforeFrame.minY))
        from.click(forDuration: 0.15, thenDragTo: target)
        // This is placement setup, not an exact product-position requirement.
        // Validate measured usable geometry after the single native title drag.
        let reached = eventually {
            let actual = settings.frame
            return visible.contains(actual) && !finderFrame.intersects(actual)
        }
        let geometry = XCTAttachment(string: "Finder retained=\(finderFrame); Settings before=\(beforeFrame); requested=\(origin); actual=\(settings.frame); reached=\(reached)")
        geometry.name = "Owned native window placement geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertTrue(reached)
        XCTAssertEqual(owned.frame, finderFrame, "Finder window must remain at its original location")
        XCTAssertTrue(visible.insetBy(dx: -2, dy: -2).contains(settings.frame))
        XCTAssertFalse(owned.frame.intersects(settings.frame))
        let preview = app.descendants(matching: .any).matching(identifier: "theme-import-preview").firstMatch
        let error = app.descendants(matching: .any).matching(identifier: "theme-import-error").firstMatch
        let installed = root.appendingPathComponent("Themes/com.example.ui-closeout")
        let installedManifest = installed.appendingPathComponent("manifest.json")
        var confirmedManifest: Data?
        for file in [package, unsupported] {
            app.activate()
            // Production exposes the container's accessibility label on this
            // StaticText. Its painted text is not its native AX value.
            let dropTexts = settings.staticTexts.matching(NSPredicate(
                format: "label == %@ OR value == %@", "导入皮肤文件区域", "导入皮肤文件区域"))
            let zone = dropTexts.firstMatch
            let viewport = settings.scrollViews.firstMatch
            for step in 0...10 {
                if zone.exists, zone.isHittable, viewport.frame.contains(zone.frame) { break }
                if step < 10 { viewport.scroll(byDeltaX: 0, deltaY: -250) }
            }
            XCTAssertEqual(dropTexts.count, 1, "Exactly one native drop-area StaticText must identify the target")
            XCTAssertTrue(zone.exists && zone.isHittable && viewport.frame.contains(zone.frame))
            XCTAssertFalse(owned.frame.intersects(zone.frame))
            finder.activate()
            let finderTree = XCTAttachment(string: String(decoding: owned.debugDescription.utf8.prefix(24_570), as: UTF8.self))
            finderTree.name = "Owned Finder source tree " + file.lastPathComponent
            finderTree.lifetime = .keepAlways
            add(finderTree)
            let finderImage = XCTAttachment(screenshot: owned.screenshot())
            finderImage.name = "Owned Finder source window " + file.lastPathComponent
            finderImage.lifetime = .keepAlways
            add(finderImage)
            let sources = owned.images.matching(NSPredicate(format: "label == %@ OR label == %@",
                file.lastPathComponent, file.deletingPathExtension().lastPathComponent))
            XCTAssertEqual(sources.count, 1, "Exactly one visible Finder source image must match the owned fixture")
            let source = sources.firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable)
            XCTAssertTrue(owned.frame.contains(source.frame))
            let geometry = XCTAttachment(string: "file=\(file.path) source=\(source.frame) dropText=\(zone.frame) finder=\(owned.frame) settings=\(settings.frame)")
            geometry.name = "Native drag observed geometry " + file.lastPathComponent
            geometry.lifetime = .keepAlways
            add(geometry)
            // Real Finder mouse-down/hold/drag/up to the observed production drop-area text.
            // No chooser, clipboard, drop-handler invocation or invented desktop coordinates.
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.35, thenDragTo: zone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            if file == package {
                XCTAssertTrue(preview.waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["theme-import-confirm"].isEnabled)
                XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
                attach(app, "Native-File-Drag-Valid-Preview-No-Install")
                app.buttons["theme-import-confirm"].click()
                XCTAssertTrue(waitUntil(preview, exists: false))
                XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: installedManifest.path) })
                let manifest = try Data(contentsOf: installedManifest)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
                XCTAssertEqual(object["themeId"] as? String, "com.example.ui-closeout")
                confirmedManifest = manifest
                attach(app, "Native-File-Drag-Valid-Confirmed-Install")
            } else {
                XCTAssertTrue(error.waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                    "文件扩展名不受支持", "文件扩展名不受支持")).firstMatch.exists)
                XCTAssertFalse(preview.exists)
                XCTAssertFalse(app.buttons["theme-import-confirm"].exists)
                attach(app, "Native-File-Drag-Unsupported-Rejected")
                app.buttons["关闭"].click()
                XCTAssertTrue(waitUntil(error, exists: false))
            }
            XCTAssertEqual(try Data(contentsOf: installedManifest), try XCTUnwrap(confirmedManifest),
                "Unsupported drag must leave the confirmed valid installation unchanged")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Records/settings.json")), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Records/today.json").path))
        }
    }

    private func shortNativeInputFixture(originalPackage: URL, isolatedRoot: URL) throws -> (URL, URL) {
        // /tmp is only the existing OS alias; no new link or alternate app data root.
        let aliasParent = URL(fileURLWithPath:
            "/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true)
        let canonicalParent = isolatedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
        guard aliasParent.resolvingSymlinksInPath() == canonicalParent else {
            throw NSError(domain: "Stage9InputFixtureParent", code: 1)
        }
        let component = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let folder = aliasParent.appendingPathComponent(component, isDirectory: true)
        // POSIX mkdir is exclusive: collision or other failure stops without reusing a directory.
        guard Darwin.mkdir(folder.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertEqual(folderValues.isDirectory, true)
        XCTAssertEqual(folderValues.isSymbolicLink, false)
        XCTAssertEqual(folder.resolvingSymlinksInPath().deletingLastPathComponent(), canonicalParent)
        XCTAssertLessThan(folder.path.count, 102)
        let package = folder.appendingPathComponent("p.incomeclocktheme")
        XCTAssertLessThan(package.path.count, 102)
        let original = try Data(contentsOf: originalPackage)
        XCTAssertLessThan(original.count, 64 * 1024)
        try original.write(to: package, options: .withoutOverwriting)
        let copied = try Data(contentsOf: package)
        let values = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(copied, original)
        let originalSHA = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let copiedSHA = SHA256.hash(data: copied).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(copiedSHA, originalSHA)
        XCTAssertEqual(copiedSHA, "b841808c039cbbcf43f7134e5442c1526b484fb26f8026e5b2db6bee4e09f552")
        let receipt: [String: Any] = ["appIsolatedRoot": isolatedRoot.path,
            "canonicalParent": canonicalParent.path, "folder": folder.path,
            "folderPathLength": folder.path.count, "package": package.path,
            "packagePathLength": package.path.count, "originalPackage": originalPackage.path,
            "originalSHA256": originalSHA, "copiedSHA256": copiedSHA,
            "bytes": copied.count, "creation": "exclusive mkdir0700 + Data.withoutOverwriting",
            "disposition": "tiny ordinary fixture retained; original app root/markers unchanged"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "Short native input fixture identity"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (folder, package)
    }

    private func writeMinimalUIThemePackage(in root: URL) throws -> URL {
        // Two-entry deflated ZIP, regular0644 files, no directory/link/executable.
        // Token source: fixed candidate004 A manifest; preview is the existing
        // Stage8 corpus2x2 PNG. Schema mirrors validManifestData; app validation
        // still must accept it at runtime. Embedded bytes avoid dependency/tool I/O.
        let encoded = """
            UEsDBBQAAAAIAAAAKF1neqa9mwMAAN8HAAANAAAAbWFuaWZlc3QuanNvbpWUXW+rNhjHvwpyb9MIGzAmuxmQoFNpU4+6bkfT1AsH
            nMYqwcyYvijKd99jQ2jS5FyMmyjP+/P8f7BHvJE7bqRqvmvRCdOhxT+oUY1AM9SpjSl4JdDTDPG2FVzzphRosUdd37ZKG1H9rirh
            Umr5vDWQU3H9gp4OkNCbrdJogX5TJa+9R9EZr5Dvpte2NGSVWra2L4TcdarmUM1rYJJX4W1kLbxyq1QnNPw5Jol3I5oOUqDjHlps
            ebe13feo1eJVird52zxDuVBQePwoYeFmQ9aC+smmwht/jWEZQvwgKCkJY16GMSvDKMCbcBPxNaaUMZ/wAEHtmn+o3nzXys4CNTvD
            G9ituh0cv2KYp5YlzCPu9R+q1/Yw6F7LZ9nAusauO07+iwfHg1h3ZW/dy9rcysYz6kU03iuve9hhhnbCaFm6bdZKV0L/kJXZogWe
            oXVvjGpypRuhH3gle4hi9oal0q7ofctLaT7Qwp+hljeiPo/FFMxaPYPA3TfhhFqEsONOgvb9Lm3bv4TuBin8OZ77ME7Dd3ahP++8
            Ub+t2FkNlNOM1zlv+VrW0kin/9PY+MrBnN3da1QJnKd6zZAW//ZSi+pLzf1xiKmUGYd4PY6LD082vXP3H6noSoji00ZwP5d2V0Gl
            Uu3m4p3v2lrMe3lb1kAYqInGmM8zwBHcGZxIThQHNvzyEkSHA6KbNMoSlkPQYPqmYCxrz4KcJtlkt+9VJ2z3myRMk3jpPPaKjwC0
            NeMYJzgE85qXL89a9Y2LJpQwcm7+FHqexLMRFBtbuIckEL1RZd89SPcm3MRhyorI3R5ec/1xbFlEBV4x9MlFIev6bKmj41FD95MW
            diDN5bhREAQRKey3AmC0Ik0dcpItM2I9W16pt6zuYVBCjv9zVbuvw43vninuZEPCjsa/0QIQBgy0K72kLKIxchbTd+kbB2SGfVdR
            mkXB5MqVldqM11/mLAkn34rrZsz66tF6mK0gcUaTyf4gePXhFE4yluHJ/uOkv5+uosx5VDtKnjrJjdBGntwnpSlOYvepGd7IU7Ti
            kCWUXKJFWZxH7Bpa0SrGYXGB1iDaBVoFBfnjn6JFT9EiCWAYON3P0AqSmC3DS7SG+CtoTUtdoDWk4OIMLZh7WbBraMHHPRiOfIqW
            /z/Qwj9DK2XRMgyuopXBvoRcRysqWOp0uUDrq+eIVsZCEoSXaMVBHNDlNbQyynAQnaAVFXEU5lfQijFdUYoOh8N/UEsDBBQAAAAI
            AAAAKF178iiaRgAAAEwAAAALAAAAcHJldmlldy5wbmfrDPBz5+WS4mJgYOD19HAJAtJMIMwBIv9emVUMpEQ8XRxDKm4l/zl/gMGF
            h6enR4GRQYCJkaH2f4AZUJrB09XPZZ1TQhMAUEsBAhQDFAAAAAgAAAAoXWd6pr2bAwAA3wcAAA0AAAAAAAAAAAAAAKSBAAAAAG1h
            bmlmZXN0Lmpzb25QSwECFAMUAAAACAAAAChde/IomkYAAABMAAAACwAAAAAAAAAAAAAApIHGAwAAcHJldmlldy5wbmdQSwUGAAAA
            AAIAAgB0AAAANQQAAAAA
            """
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "b841808c039cbbcf43f7134e5442c1526b484fb26f8026e5b2db6bee4e09f552")
        let url = root.appendingPathComponent("ui-local.incomeclocktheme")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func isolatedRoot(_ suffix: String) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true).appendingPathComponent("IncomeClockStage9UITests-" + suffix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Retained for failure diagnostics; no real Application Support is used.
        return root
    }

    private func localTimestamp(hour: Int) throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: hour)))
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func launchIsolated(root: URL, now: Int64, rate: Int, timeZoneIdentifier: String? = nil,
                                nativeMenuDiagnostic: Bool = false,
                                nativeMenuRowsAppearance: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        if let timeZoneIdentifier { app.launchEnvironment["TZ"] = timeZoneIdentifier }
        if nativeMenuDiagnostic { app.launchEnvironment["INCOMECLOCK_NATIVE_MENU_DIAGNOSTIC"] = "1" }
        if let nativeMenuRowsAppearance {
            app.launchEnvironment["INCOMECLOCK_NATIVE_MENU_SUMMARY_ROWS"] = "1"
            app.launchEnvironment["INCOMECLOCK_NATIVE_MENU_SUMMARY_APPEARANCE"] = nativeMenuRowsAppearance
        }
        app.launchEnvironment["INCOMECLOCK_TEST_ROOT"] = root.path
        app.launchEnvironment["INCOMECLOCK_UI_ISOLATION_NONCE"] = UUID().uuidString
        app.launchArguments = ["--debug-now-ms", String(now), "--debug-time-rate", String(rate)]
        app.launch()
        try verifyIsolation(app, root: root)
        return app
    }

    private func verifyIsolation(_ app: XCUIApplication, root: URL) throws {
        let testBundle = Bundle(for: ShortcutUITests.self).bundleURL.resolvingSymlinksInPath()
        let runnerApp = testBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let productRoot = runnerApp.deletingLastPathComponent()
        guard testBundle.lastPathComponent == "IncomeClockUITests.xctest",
              testBundle.deletingLastPathComponent().lastPathComponent == "PlugIns",
              runnerApp.lastPathComponent == "IncomeClockUITests-Runner.app",
              ["Debug", "Debug-UIRunner"].contains(productRoot.lastPathComponent) else {
            throw NSError(domain: "Stage9UIIsolation", code: 3)
        }
        let allowedApp = productRoot.appendingPathComponent("IncomeClock.app").resolvingSymlinksInPath().path
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ffq.incomeclock")
        guard running.count == 1, let process = running.first,
              let bundleURL = process.bundleURL,
              bundleURL.resolvingSymlinksInPath().path == allowedApp else {
            throw NSError(domain: "Stage9UIIsolation", code: 1)
        }
        let receiptURL = root.appendingPathComponent("ui-isolation-receipt.json")
        let data: Data
        do { data = try Data(contentsOf: receiptURL) }
        catch { throw error }
        let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let receipt,
              receipt["pid"] as? Int32 == process.processIdentifier,
              receipt["nonce"] as? String == app.launchEnvironment["INCOMECLOCK_UI_ISOLATION_NONCE"],
              receipt["root"] as? String == root.resolvingSymlinksInPath().path,
              receipt["bundle"] as? String == bundleURL.resolvingSymlinksInPath().path,
              let arguments = receipt["arguments"] as? [String],
              app.launchArguments.allSatisfy({ arguments.contains($0) }) else {
            throw NSError(domain: "Stage9UIIsolation", code: 2)
        }
        // XCTest executes registered teardown blocks even when an Objective-C
        // assertion abort skips Swift defer. Capture only this verified process;
        // a later same-bundle app or reused PID must never become its target.
        let verifiedPID = process.processIdentifier
        let verifiedBundle = bundleURL.resolvingSymlinksInPath().path
        let verifiedLaunchDate = process.launchDate
        addTeardownBlock { [process] in
            guard !process.isTerminated else { return }
            func isSameVerifiedProcess() -> Bool {
                guard !process.isTerminated, let verifiedLaunchDate,
                      let current = NSRunningApplication(processIdentifier: verifiedPID),
                      !current.isTerminated,
                      current.launchDate == verifiedLaunchDate,
                      current.bundleURL?.resolvingSymlinksInPath().path == verifiedBundle else { return false }
                return true
            }
            guard isSameVerifiedProcess() else {
                XCTFail("Verified test process identity no longer matches; no teardown termination attempted")
                return
            }
            _ = process.terminate()
            let gracefulDeadline = Date().addingTimeInterval(2)
            while !process.isTerminated && Date() < gracefulDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if !process.isTerminated {
                guard isSameVerifiedProcess() else {
                    XCTFail("Test process identity changed before forced teardown; no force attempted")
                    return
                }
                _ = process.forceTerminate()
                let forcedDeadline = Date().addingTimeInterval(1)
                while !process.isTerminated && Date() < forcedDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            XCTAssertTrue(process.isTerminated, "Exact verified isolated test PID must finish bounded teardown")
        }
        // Record only the isolated test path, never the full process environment.
        let receiptAttachment = XCTAttachment(string: "Verified PID \(process.processIdentifier); temporary root \(root.path); launch arguments \(app.launchArguments)")
        receiptAttachment.name = "Isolated launch verified"
        receiptAttachment.lifetime = .keepAlways
        add(receiptAttachment)
    }

    private func openSettingsFromMenu(_ app: XCUIApplication) throws -> XCUIElement {
        let status = app.statusItems["income-clock-menu-bar-extra"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        let item = status.menuItems["打开设置…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        let menuFrame = item.frame
        let display = try primaryVisibleFrameInAccessibilityCoordinates()
        guard menuFrame.origin.x.isFinite, menuFrame.origin.y.isFinite,
              menuFrame.width > 0, menuFrame.height > 0, display.contains(menuFrame) else {
            XCTFail("Native Settings menu item must have finite visible bounds before click")
            throw NSError(domain: "Stage9NativeMenuGeometry", code: 1)
        }
        let menuGeometry = XCTAttachment(string: "Settings menu item before click: \(menuFrame)")
        menuGeometry.name = "Native Settings menu item click geometry"
        menuGeometry.lifetime = .keepAlways
        add(menuGeometry)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        return settings
    }

    private func primaryVisibleFrameInAccessibilityCoordinates() throws -> CGRect {
        let mainID = CGMainDisplayID()
        let screen = try XCTUnwrap(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID
        })
        // NSScreen is bottom-up; XCUITest screen coordinates are top-down.
        let frame = screen.visibleFrame
        let converted = CGRect(x: frame.minX, y: CGDisplayBounds(mainID).height - frame.maxY,
            width: frame.width, height: frame.height)
        let geometry = XCTAttachment(string: "Main display \(mainID); displays \(NSScreen.screens.count); native visibleFrame \(frame); AX visibleFrame \(converted)")
        geometry.name = "Actual primary display geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        return converted
    }

    private func assertDefaultPanelFrame(_ frame: CGRect, visibleFrame: CGRect) {
        XCTAssertEqual(visibleFrame.maxX - frame.maxX, 20, accuracy: 1)
        XCTAssertEqual(visibleFrame.maxY - frame.maxY, 20, accuracy: 1)
        XCTAssertTrue(visibleFrame.contains(frame), "Panel stays clear of the current Dock/menu-bar bounds")
    }

    private func dragPanelBackground(_ panel: XCUIElement, to origin: CGPoint) {
        // Empty central top strip, away from status text and both corner buttons.
        let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 6))
        let end = start.withOffset(CGVector(dx: origin.x - panel.frame.minX, dy: origin.y - panel.frame.minY))
        start.click(forDuration: 0.15, thenDragTo: end)
    }

    private func openSettings(_ app: XCUIApplication) throws -> XCUIElement {
        app.activate()
        let gear = app.dialogs["可视收入打卡机"].buttons["gearshape"]
        guard gear.waitForExistence(timeout: 5) else {
            print("Stage9 Settings entry missing AX: " + app.debugDescription)
            throw NSError(domain: "Stage9SettingsEntry", code: 1)
        }
        gear.click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        guard window.waitForExistence(timeout: 5) else {
            print("Stage9 Settings did not open AX: " + app.debugDescription)
            throw NSError(domain: "Stage9SettingsEntry", code: 2)
        }
        return window
    }

    private func nativeStaticText(_ element: XCUIElement) -> String {
        // Native macOS AXStaticText exposes its content in AXValue; labelled
        // accessibility elements may additionally carry a separate AXLabel.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func revealSettingsButton(
        _ identifier: String, in settings: XCUIElement, towardTop: Bool
    ) -> XCUIElement {
        let viewport = settings.scrollViews.firstMatch
        XCTAssertTrue(viewport.exists)
        for step in 0...10 {
            let button = settings.buttons[identifier]
            if button.exists, button.frame.width > 0, button.frame.height > 0,
               viewport.frame.insetBy(dx: -1, dy: -1).contains(button.frame) {
                return button
            }
            if step < 10 {
                viewport.scroll(byDeltaX: 0, deltaY: towardTop ? 350 : -350)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        XCTFail("Native Settings scroll did not reveal the concrete button: \(identifier)")
        return settings.buttons[identifier]
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        if value.count == 5, value.dropFirst(2).first == ":" {
            // Edit digit pairs around the real existing separator. This uses
            // native selection and typing without layout-dependent punctuation.
            XCTAssertEqual((field.value as? String)?.dropFirst(2).first, ":")
            editTimeDigits(value, into: field)
        } else {
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value)
        }
        XCTAssertEqual(field.value as? String, value, "Native input must match before testing validation or saving")
    }

    private func editTimeDigits(_ value: String, into target: XCUIElement) {
        let parts = value.split(separator: ":")
        precondition(parts.count == 2 && parts.allSatisfy { $0.count == 2 })
        target.typeKey(.leftArrow, modifierFlags: .command)
        target.typeKey(.rightArrow, modifierFlags: .shift)
        target.typeKey(.rightArrow, modifierFlags: .shift)
        target.typeText(String(parts[0]))
        target.typeKey(.rightArrow, modifierFlags: [])
        target.typeKey(.rightArrow, modifierFlags: .shift)
        target.typeKey(.rightArrow, modifierFlags: .shift)
        target.typeText(String(parts[1]))
    }

    private func record(_ root: URL, _ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Records/" + name))) as? [String: Any])
    }

    private func expectedAmount(_ today: [String: Any], at now: Int64, live: Bool) throws -> Int64 {
        let snapshot = try XCTUnwrap(today["settingsSnapshot"] as? [String: Any])
        let wage = try XCTUnwrap(snapshot["dailyWageCents"] as? Int64)
        let start = try XCTUnwrap(today["scheduledStartAtMs"] as? Int64)
        let end = try XCTUnwrap(today["scheduledEndAtMs"] as? Int64)
        let clockIn = try XCTUnwrap(today["clockInAtMs"] as? Int64)
        let earned = max(Int64(0), min(now, end) - max(clockIn, start))
        let duration = end - start
        XCTAssertGreaterThan(duration, 0)
        return (wage * earned * (live ? 10 : 1) + duration / 2) / duration
    }

    private func amountVoiceValue(_ value: Int64, live: Bool) -> String {
        if live { return "\(value / 1_000) 元 \((value / 100) % 10) 角 \((value / 10) % 10) 分 \(value % 10) 厘，实时收入估算" }
        return "\(value / 100) 元 \((value / 10) % 10) 角 \(value % 10) 分，已结算"
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
