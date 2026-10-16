import AppKit
import SwiftUI
import XCTest
@testable import IncomeClock

/// Hosted production views and AppKit objects. These tests do not claim to
/// exercise the system-owned MenuBarExtra popover or external-display gates.
@MainActor
final class PanelCloseoutIntegrationTests: XCTestCase {
    func testHiddenNativePanelReachesStopBoundaryAndMenuRestoreShowsCurrentAmount() async throws {
        let root = try ApplicationTestSupport.makeTemporaryRoot()
        let fixture = XCTAttachment(string: root.path)
        fixture.name = "Stage9-HiddenPanel-Retained-Fixture-Root"
        fixture.lifetime = .keepAlways
        add(fixture)
        let repository = RecordRepositoryActor(paths: .init(root: root))
        let settings = try await repository.saveSettings(
            ApplicationTestSupport.proposedSettings(wageCents: 30_000, panelVisible: false),
            expectedRevision: nil)
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        _ = try await repository.saveToday(today, expectedRevision: nil)
        let coordinated = PanelSettingsCoordinator(repository: repository,
            preferenceStore: EphemeralPanelPreferenceStore())
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 17, minute: 59))
        let store = try BusinessStore(repository: coordinated, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let themes = ThemeStore()
        let controller = PanelController(businessStore: store, themeStore: themes,
            repository: coordinated, nowMilliseconds: { clock.nowMilliseconds().rawValue })
        let environment = AppEnvironment(businessStore: store, panelController: controller, themeStore: themes)
        await environment.start()
        let panel = try XCTUnwrap(controller.windowForTesting)
        defer { controller.hide(persist: false) }
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(environment.isPanelVisible)
        XCTAssertEqual(store.viewState?.state, .earning)

        // Only AppEnvironment's production maintenance task can consume this
        // clock advance: the test does not invoke refresh or a render pulse.
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        try await eventually { store.viewState?.state == .awaitingClockOut }
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount), "¥300.00")
        let beforeShow = try XCTUnwrap(store.viewState)
        environment.togglePanelFromMenuBar()
        await controller.waitForPendingPersistence()
        try await eventually { panel.isVisible && environment.isPanelVisible }
        try await Stage9EnableHostedAccessibility()
        XCTAssertFalse(panel.isKeyWindow)
        let content = try XCTUnwrap(panel.contentView)
        try await eventually { self.nativeAmount(in: content)?.targetText == "¥300.00" }
        XCTAssertEqual(store.viewState?.state, beforeShow.state)
        XCTAssertEqual(nativeAmount(in: content)?.activeAnimationCount, 0)
        guard case let .loaded(saved, _) = await repository.loadSettings() else {
            return XCTFail("Showing the actual panel must persist visibility")
        }
        XCTAssertTrue(saved.panelVisible)
        XCTAssertEqual(saved.dailyWageCents, settings.dailyWageCents)
        environment.togglePanelFromMenuBar()
        await controller.waitForPendingPersistence()
        XCTAssertFalse(panel.isVisible)
        guard case let .loaded(hidden, _) = await repository.loadSettings() else {
            return XCTFail("Hiding the actual panel must persist visibility")
        }
        XCTAssertFalse(hidden.panelVisible)
    }

    func testNativeSettingsRouterDispatchesNestedCommandCommaAction() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let receiver = CloseoutMenuActionReceiver()
        let root = NSMenu(title: "IncomeClock test")
        let applicationItem = NSMenuItem(title: "Application", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Application")
        applicationMenu.autoenablesItems = false
        let settings = NSMenuItem(title: "Settings…", action: #selector(CloseoutMenuActionReceiver.openSettings(_:)),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = receiver
        applicationMenu.addItem(settings)
        applicationItem.submenu = applicationMenu
        root.addItem(applicationItem)
        NSApp.mainMenu = root

        XCTAssertTrue(NativeSettingsWindowRouter.open())
        XCTAssertEqual(receiver.openCount, 1)
        XCTAssertTrue(receiver.lastSender === settings)
        applicationMenu.removeItem(settings)
        XCTAssertFalse(NativeSettingsWindowRouter.open())
        XCTAssertEqual(receiver.openCount, 1)
    }

    func testHostedAmountCarriesKeepOtherControlsFixedAndClockOutActionUsable() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        // First pair is the exact Contract carry. Second pair crosses the
        // six-digit boundary at the legal maximum wage using real calculations.
        let cases: [(wage: Int64, before: Int64, after: Int64, expectedBefore: String, expectedAfter: String)] = [
            (3_240_000, 999_999, 1_000_000, "¥999.999", "¥1,000.000"),
            (99_999_999, 3_240_000, 3_240_001, "¥99,999.999", "¥100,000.030")
        ]
        for themeID in [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion] {
            for sample in cases {
                let settings = ApplicationTestSupport.committedSettings(wageCents: sample.wage)
                let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                    .proposedToday(from: settings, at: start)
                let clock = MutableTestClock(.init(rawValue: start.rawValue + sample.before))
                let store = try BusinessStore(repository: BusinessRecordRepositorySpy(
                    settings: .loaded(settings, migration: .current), today: .loaded(today, migration: .current)),
                    nowProvider: clock, timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
                await store.restore()
                let themes = ThemeStore()
                await themes.restore()
                await themes.selectTheme(id: themeID)
                let profile = PanelPresentationProfileRegistry().standard
                let pulse = PanelRenderPulseCoordinator(isVisible: false)
                let layout = PanelLayoutObservation()
                let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
                    profile: profile, onOpenSettings: {}, onHide: {}, renderPulse: pulse, layoutObservation: layout)
                    .environment(\.incomePanelTextScale, 1.2))
                let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless()
                try await Stage9EnableHostedAccessibility()
                defer { window.orderOut(nil); window.close() }
                try await eventually { self.nativeAmount(in: host)?.targetText == sample.expectedBefore }
                try await eventually { layout.frames["primaryAction"] != nil }
                host.layoutSubtreeIfNeeded()
                let amount = try XCTUnwrap(nativeAmount(in: host))
                let amountFrame = amount.convert(amount.bounds, to: host)
                let labels = ["计薪中", "打开设置", "隐藏收入面板", "计划工作进度", "打卡下班"]
                try await eventually { labels.allSatisfy { self.renderedText(host).contains($0) } }
                let before = try controlFrames(labels, in: host)
                let componentFrames = layout.frames
                XCTAssertEqual(componentFrames["status"], CGRect(x: 12, y: 8, width: 232, height: 28))
                XCTAssertEqual(componentFrames["settings"], CGRect(x: 252, y: 8, width: 28, height: 28))
                XCTAssertEqual(componentFrames["hide"], CGRect(x: 280, y: 8, width: 28, height: 28))
                XCTAssertEqual(componentFrames["amount"], CGRect(x: 12, y: 38, width: 296, height: 60))
                XCTAssertEqual(componentFrames["support"], CGRect(x: 12, y: 100, width: 228, height: 42))
                XCTAssertEqual(componentFrames["primaryAction"], CGRect(x: 12, y: 148, width: 296, height: 32))
                if themeID == BuiltinThemeID.windowCompanion {
                    XCTAssertEqual(componentFrames["decoration"], CGRect(x: 248, y: 92, width: 60, height: 50))
                    XCTAssertFalse(renderedIdentifiers(host).contains("income-panel-decoration"))
                }
                clock.set(.init(rawValue: start.rawValue + sample.after))
                await store.refresh()
                try await eventually { self.nativeAmount(in: host)?.targetText == sample.expectedAfter }
                host.layoutSubtreeIfNeeded()
                let after = try controlFrames(labels, in: host)
                XCTAssertEqual(before, after, "Non-amount controls moved at the carry in \(themeID)")
                XCTAssertEqual(layout.frames, componentFrames)
                XCTAssertEqual(amount.convert(amount.bounds, to: host), amountFrame)
                XCTAssertGreaterThanOrEqual(amount.appliedFontSize, 26)
                XCTAssertTrue(amount.renderedGlyphs.allSatisfy { $0.frame.minX >= 4 && $0.frame.maxX <= 276 })
                try capture(host, name: "Stage9-Carry-\(themeID)-\(sample.wage)")

                let action = try element(label: "打卡下班", in: host, buttonOnly: true)
                XCTAssertTrue(press(action), "The mounted production button must accept AXPress")
                try await eventually { store.confirmation != nil && self.renderedText(host).contains("确认下班") }
                let confirm = try element(label: "确认下班", in: host, buttonOnly: true)
                XCTAssertTrue(press(confirm))
                try await eventually { store.viewState?.state == .completed }
                XCTAssertNil(store.confirmation)
                XCTAssertEqual(Stage5AmountFormatter.string(for: try XCTUnwrap(store.viewState).amount)?.split(separator: ".").last?.count, 2)
            }
        }
    }

    func testMountedClockOutStartsDuringActiveCarryAnimationAndPersistsSettlement() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let settings = ApplicationTestSupport.committedSettings(wageCents: 3_240_000)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current))
        let clock = MutableTestClock(.init(rawValue: start.rawValue + 999_999))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let themes = ThemeStore()
        await themes.restore()
        let pulse = PanelRenderPulseCoordinator(isVisible: true)
        // Consume the initial resume calibration before the observed carry.
        await pulse.pulse(store)
        let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
            profile: PanelPresentationProfileRegistry().standard, onOpenSettings: {}, onHide: {},
            accessibilityInputs: .init(reduceMotion: false, reduceTransparency: false), renderPulse: pulse))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { pulse.setVisible(false); window.orderOut(nil); window.close() }
        try await Stage9EnableHostedAccessibility()
        try await eventually { self.nativeAmount(in: host)?.targetText == "¥999.999" }
        let amount = try XCTUnwrap(nativeAmount(in: host))
        clock.set(.init(rawValue: start.rawValue + 1_000_000))
        await store.refresh()
        try await eventually { amount.targetText == "¥1,000.000" && amount.activeAnimationCount > 0 }
        // No suspension or capture between this production animation witness and
        // invoking the actual mounted action: the click occurs while it rolls.
        let action = try element(label: "打卡下班", in: host, buttonOnly: true)
        XCTAssertGreaterThan(amount.activeAnimationCount, 0)
        XCTAssertEqual(store.viewState?.state, .earning)
        XCTAssertTrue(press(action))
        try await eventually { store.confirmation != nil && self.renderedText(host).contains("确认下班") }
        XCTAssertTrue(press(try element(label: "确认下班", in: host, buttonOnly: true)))
        try await eventually { store.viewState?.state == .completed }
        XCTAssertNil(store.confirmation)
        XCTAssertEqual(store.viewState?.amount, .rounded(try .init(validating: 100_000)))
        let persisted = await repository.currentToday()
        let saved = try XCTUnwrap(persisted)
        XCTAssertEqual(saved.clockOutAtMs, clock.nowMilliseconds().rawValue)
        XCTAssertEqual(store.todayRecordForValidation, saved)
        XCTAssertEqual(store.settingsRecordForValidation, settings)
    }

    func testMountedClockOutConfirmationRefreshesRetainsFailureAndCancelContinuesEarning() async throws {
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let settings = ApplicationTestSupport.committedSettings(wageCents: 3_240_000)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current))
        let clock = MutableTestClock(.init(rawValue: start.rawValue + 10_000))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let themes = ThemeStore()
        await themes.restore()
        await themes.selectTheme(id: BuiltinThemeID.windowCompanion)
        let pulse = PanelRenderPulseCoordinator()
        let layout = PanelLayoutObservation()
        let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
            profile: PanelPresentationProfileRegistry().standard, onOpenSettings: {}, onHide: {}, renderPulse: pulse,
            layoutObservation: layout)
            .environment(\.incomePanelTextScale, 1.2))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        try await Stage9EnableHostedAccessibility()
        defer { pulse.setVisible(false); window.orderOut(nil); window.close() }
        try await eventually { self.nativeAmount(in: host)?.targetText == "¥10.000" }
        XCTAssertTrue(press(try element(label: "打卡下班", in: host, buttonOnly: true)))
        try await eventually { self.renderedText(host).contains("预计结算 ¥10.00") }
        try await eventually { layout.frames["confirm"] != nil && layout.frames["decoration"] == nil }
        let confirmationFrames = layout.frames
        for (name, frame) in [
            "confirmationTitle": CGRect(x: 20, y: 46, width: 280, height: 22),
            "confirmationAmount": CGRect(x: 20, y: 72, width: 280, height: 36),
            "confirmationDuration": CGRect(x: 20, y: 112, width: 280, height: 18),
            "confirmationNotice": CGRect(x: 20, y: 132, width: 280, height: 12),
            "cancel": CGRect(x: 12, y: 148, width: 92, height: 32),
            "confirm": CGRect(x: 112, y: 148, width: 196, height: 32)
        ] { XCTAssertEqual(confirmationFrames[name], frame, name) }
        XCTAssertTrue(renderedText(host).contains("预计计薪 00:00:10"))
        clock.set(.init(rawValue: start.rawValue + 20_000))
        // The mounted production timeline updates both estimate fields.
        try await eventually { self.renderedText(host).contains("预计结算 ¥20.00") }
        XCTAssertTrue(renderedText(host).contains("预计计薪 00:00:20"))
        XCTAssertNil(nativeAmount(in: host), "Confirmation replaces the live amount and progress")
        XCTAssertEqual(layout.frames, confirmationFrames)
        try capture(host, name: "Stage9-ClockOut-Confirmation-Text120")

        await repository.failNextTodaySave(with: .atomicWriteFailed)
        await repository.holdNextTodaySave()
        defer { Task { await repository.releaseHeldTodaySave() } }
        XCTAssertTrue(press(try element(label: "确认下班", in: host, buttonOnly: true)))
        try await eventually { store.isCommandInFlight && self.renderedText(host).contains("正在保存…") }
        let loading = try await waitForAXControl(label: "正在保存…", in: host, enabled: false, role: "AXBusyIndicator")
        let cancel = try await waitForAXControl(label: "取消", in: host, enabled: false)
        XCTAssertEqual(boolAttribute(loading, "isAccessibilityEnabled"), false)
        XCTAssertEqual(boolAttribute(cancel, "isAccessibilityEnabled"), false)
        XCTAssertNil(findElement(label: "确认下班", in: host, buttonOnly: true), "Saving exposes no actionable confirmation")
        XCTAssertNil(layout.frames["decoration"])
        try capture(host, name: "Stage9-ClockOut-Confirmation-Loading-Text120")
        await repository.releaseHeldTodaySave()
        try await eventually { !store.isCommandInFlight && self.renderedText(host).contains("下班记录保存失败，请重试") }
        XCTAssertNotNil(store.confirmation)
        XCTAssertEqual(store.viewState?.state, .earning)
        let unchanged = await repository.currentToday()
        XCTAssertEqual(unchanged, today)
        let retry = try await waitForAXControl(label: "确认下班", in: host, enabled: true)
        XCTAssertEqual(boolAttribute(retry, "isAccessibilityEnabled"), true)
        try capture(host, name: "Stage9-ClockOut-Confirmation-Failure-Text120")
        XCTAssertTrue(press(try element(label: "取消", in: host, buttonOnly: true)))
        try await eventually { store.confirmation == nil && self.nativeAmount(in: host) != nil }
        clock.set(.init(rawValue: start.rawValue + 30_000))
        try await eventually { self.nativeAmount(in: host)?.targetText == "¥30.000" }
        XCTAssertEqual(store.viewState?.state, .earning)
        let afterCancel = await repository.currentToday()
        XCTAssertEqual(afterCancel, today)
    }

    func testPreviousWorkdayMountedSettlementKeepsDateAmountTimesBlessingAndCancel() async throws {
        let settings = ApplicationTestSupport.committedSettings(wageCents: 99_999_999)
        let start = ApplicationTestSupport.timestamp(hour: 9)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: start)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 18))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current))
        let store = try BusinessStore(repository: repository, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let outcome = await store.send(.requestClockOut, source: .panel)
        XCTAssertEqual(outcome, .committed)
        clock.set(ApplicationTestSupport.timestamp(day: 14, hour: 10))
        await store.refresh()
        XCTAssertEqual(store.viewState?.isPreviousWorkday, true)
        let preserved = await repository.currentToday()
        let themes = ThemeStore()
        await themes.restore()
        await themes.selectTheme(id: BuiltinThemeID.windowCompanion)
        let pulse = PanelRenderPulseCoordinator(isVisible: false)
        let layout = PanelLayoutObservation()
        let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
            profile: PanelPresentationProfileRegistry().standard, onOpenSettings: {}, onHide: {}, renderPulse: pulse,
            layoutObservation: layout)
            .environment(\.incomePanelTextScale, 1.2))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        try await Stage9EnableHostedAccessibility()
        defer { window.orderOut(nil); window.close() }
        try await eventually { self.nativeAmount(in: host)?.targetText == "¥999,999.99" && layout.frames["blessing"] != nil }
        let text = renderedText(host)
        for expected in [today.dateKey, "计薪时长 09:00:00", "上班 09:00:00", "下班 18:00:00",
                         "今日辛苦啦，喜提 ¥999,999.99，今天的努力已经成功变现。", "开始今天"] {
            XCTAssertTrue(text.contains(expected), "Missing previous-workday settlement field: \(expected)")
        }
        XCTAssertEqual(nativeAmount(in: host)?.activeAnimationCount, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(nativeAmount(in: host)).appliedFontSize, 26)
        XCTAssertEqual(layout.frames["amount"], CGRect(x: 12, y: 38, width: 296, height: 42))
        XCTAssertEqual(layout.frames["support"], CGRect(x: 12, y: 82, width: 296, height: 42))
        XCTAssertEqual(layout.frames["blessing"], CGRect(x: 12, y: 126, width: 296, height: 20))
        XCTAssertEqual(layout.frames["primaryAction"], CGRect(x: 12, y: 148, width: 296, height: 32))
        XCTAssertNil(layout.frames["decoration"])
        let compact = Stage5SettlementBlessing.compact(amount: "¥999,999.99")
        let font = NSFont.systemFont(ofSize: 11 * 1.2, weight: .medium)
        XCTAssertLessThanOrEqual((compact as NSString).size(withAttributes: [.font: font]).width, 296)
        XCTAssertLessThanOrEqual((compact as NSString).size(withAttributes: [.font: font]).height, 20)
        try capture(host, name: "Stage9-Previous-Settlement-Maximum-Text120")
        XCTAssertTrue(press(try element(label: "开始今天", in: host, buttonOnly: true)))
        try await eventually { store.confirmation == .startToday && self.renderedText(host).contains("清除并开始今天") }
        XCTAssertTrue(press(try element(label: "取消", in: host, buttonOnly: true)))
        try await eventually { store.confirmation == nil && self.nativeAmount(in: host)?.targetText == "¥999,999.99" }
        XCTAssertTrue(renderedText(host).contains(today.dateKey))
        let afterCancel = await repository.currentToday()
        XCTAssertEqual(afterCancel, preserved)
    }

    func testDamagedSettingsPreviousSettlementRetainsRepairEntryAndCrossdayClockOutDates() async throws {
        let settings = ApplicationTestSupport.committedSettings(wageCents: 99_999_999)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: ApplicationTestSupport.timestamp(hour: 9))
        for (day, changedZone) in [(14, "Pacific/Honolulu"), (16, "Asia/Tokyo")] {
            let damage = DamagedRecordResult(kind: .settings, issue: .invalidSchemaEnvelope,
                disposition: .requireSettingsRecovery)
            let repository = BusinessRecordRepositorySpy(settings: .damaged(damage),
                today: .loaded(today, migration: .current))
            let now = ApplicationTestSupport.timestamp(day: day, hour: 10)
            let clock = MutableTestClock(now)
            let zones = MutableTestTimeZoneIdentifierProvider(ApplicationTestSupport.timeZoneIdentifier)
            let store = try BusinessStore(repository: repository, nowProvider: clock,
                timeZoneIdentifierProvider: zones)
            await store.restore()
            XCTAssertEqual(store.viewState?.state, .awaitingClockOut)
            let outcome = await store.send(.requestClockOut, source: .panel)
            XCTAssertEqual(outcome, .committed)
            let savedToday = await repository.currentToday()
            let settled = try XCTUnwrap(savedToday)
            XCTAssertEqual(settled.clockOutAtMs, now.rawValue)
            XCTAssertEqual(settled.dateKey, today.dateKey)
            let settingsToken = await repository.currentSettingsToken()
            zones.set(changedZone)
            await store.refresh()
            let expectedDate = String(format: "2026-08-%02d", day)
            XCTAssertEqual(store.viewState?.state, .completed)
            XCTAssertEqual(store.viewState?.clockOutDateKey, expectedDate)
            XCTAssertEqual(store.viewState?.isPreviousWorkday, true)
            XCTAssertEqual(store.viewState?.canRequestStartToday, false)
            XCTAssertNotNil(store.settingsReadErrorViewState)
            let presentation = Stage5PanelPresentation.make(from: try XCTUnwrap(store.viewState))
            XCTAssertTrue(presentation.durationText.contains("下班 \(expectedDate) 10:00:00"))

            let themes = ThemeStore()
            await themes.restore()
            await themes.selectTheme(id: BuiltinThemeID.windowCompanion)
            var openedSettings = 0
            let layout = PanelLayoutObservation()
            let pulse = PanelRenderPulseCoordinator(isVisible: false)
            let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
                profile: PanelPresentationProfileRegistry().standard, onOpenSettings: { openedSettings += 1 },
                onHide: {}, renderPulse: pulse, layoutObservation: layout)
                .environment(\.incomePanelTextScale, 1.2))
            let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            try await Stage9EnableHostedAccessibility()
            defer { window.orderOut(nil); window.close() }
            try await eventually {
                self.nativeAmount(in: host)?.targetText == "¥999,999.99" && layout.frames["blessing"] != nil
                    && self.renderedText(host).contains("请先修复设置，再开始今天")
            }
            let text = renderedText(host)
            for field in [today.dateKey, "计薪时长 09:00:00", "上班 09:00:00",
                          "下班 \(expectedDate) 10:00:00", Stage5SettlementBlessing.full(amount: "¥999,999.99")] {
                XCTAssertTrue(text.contains(field), "Missing damaged-settings settlement field: \(field)")
            }
            let start = try element(label: "开始今天", in: host, buttonOnly: true)
            XCTAssertEqual(boolAttribute(start, "isAccessibilityEnabled"), false)
            XCTAssertEqual(layout.frames["amount"], CGRect(x: 12, y: 38, width: 296, height: 42))
            XCTAssertEqual(layout.frames["support"], CGRect(x: 12, y: 82, width: 296, height: 42))
            XCTAssertEqual(layout.frames["blessing"], CGRect(x: 12, y: 126, width: 296, height: 20))
            XCTAssertEqual(layout.frames["primaryAction"], CGRect(x: 12, y: 148, width: 296, height: 32))
            XCTAssertNil(layout.frames["decoration"])
            XCTAssertTrue(press(try element(label: "打开设置", in: host, buttonOnly: true)))
            XCTAssertEqual(openedSettings, 1)
            XCTAssertNil(store.confirmation)
            let retained = await repository.currentToday()
            let retainedSettingsToken = await repository.currentSettingsToken()
            let resetCount = await repository.resetTodayCount
            XCTAssertEqual(retained, settled)
            XCTAssertEqual(retainedSettingsToken, settingsToken)
            XCTAssertEqual(resetCount, 0)
            try capture(host, name: "Stage9-DamagedSettings-PreviousSettlement-Day\(day)-Text120")
        }
    }

    func testHostedMenuSevenBusinessStatesFollowContractOrderSummaryAndSharedState() async throws {
        let settings = ApplicationTestSupport.committedSettings(wageCents: 90_000)
        let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let damage = DamagedRecordResult(kind: .today, issue: .invalidSchemaEnvelope, disposition: .requireTodayReset)
        let rows: [(WorkdayState, Int, String, String, String?)] = [
            (.unconfigured, 8, "待完成设置", "请先设置工资与工作时间", nil),
            (.ready, 8, "今日未打卡", "今日已获得 ¥0.00", "打卡上班"),
            (.clockedInWaiting, 8, "已打卡 · 等待开工", "今日已获得 ¥0.000 · 距离开始 01:00:00", "打卡下班"),
            (.earning, 12, "计薪中", "今日已获得 ¥300.000 · 距离下班 06:00:00", "打卡下班"),
            (.awaitingClockOut, 18, "计薪已停止", "今日已获得 ¥900.00 · 请打卡下班", "打卡下班"),
            (.completed, 18, "今日已完成", "最终收入 ¥900.00", nil),
            (.recoveryRequired, 12, "记录需要恢复", "无法安全显示今日收入", nil)
        ]
        for (expectedState, hour, status, detail, action) in rows {
            let today = try calendar.proposedToday(from: settings, at:
                ApplicationTestSupport.timestamp(hour: expectedState == .clockedInWaiting ? 8 : 9))
            let repository = BusinessRecordRepositorySpy(
                settings: expectedState == .unconfigured ? .missing : .loaded(settings, migration: .current),
                today: expectedState == .recoveryRequired ? .damaged(damage) :
                    [.unconfigured, .ready].contains(expectedState) ? .missing : .loaded(today, migration: .current))
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: hour)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
                notificationService: FakeNotificationService())
            await store.restore()
            if expectedState == .completed {
                let settled = await store.send(.requestClockOut, source: .panel)
                XCTAssertEqual(settled, .committed)
            }
            XCTAssertEqual(store.viewState?.state, expectedState)
            let before = store.viewState
            let recordBefore = await repository.currentToday()
            let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                loginItemService: FakeLoginItemService())
            let menu = HostedSettings(VStack(alignment: .leading) { MenuBarContentView(environment: environment) })
            defer { menu.close() }
            try await Stage9EnableHostedAccessibility()
            let host = try XCTUnwrap(menu.window.contentView)
            try await eventually { self.renderedText(host).contains(status) }
            let texts = axElements(in: host).filter {
                self.axObject($0, "accessibilityRole") as? String == "AXStaticText"
            }.flatMap { self.axTexts($0) }
            XCTAssertTrue(texts.contains(status), "Exact noninteractive status: \(expectedState)")
            XCTAssertTrue(texts.contains(detail), "Exact noninteractive detail: \(expectedState), got \(texts)")
            try assertMenuControls(host, action: action)
            if let action {
                let button = try element(label: action, in: host, buttonOnly: true)
                XCTAssertEqual(boolAttribute(button, "isAccessibilityEnabled"), true)
            }
            XCTAssertEqual(store.viewState, before, "Rendering a menu cannot change the shared business state")
            let recordAfter = await repository.currentToday()
            XCTAssertEqual(recordAfter, recordBefore)
            let panelAmount = Stage5PanelPresentation.make(from: try XCTUnwrap(before)).amount
            switch expectedState {
            case .unconfigured:
                // UI Contract §6 gives the panel zero; §14.2 gives the menu setup copy.
                XCTAssertEqual(panelAmount, "¥0.00")
                XCTAssertFalse(texts.contains { $0.contains("¥") }, "Unconfigured menu uses setup summary, not panel amount")
            case .recoveryRequired:
                XCTAssertNil(panelAmount)
                XCTAssertFalse(texts.contains { $0.contains("¥") }, "Recovery must not display an unsafe amount")
            case .ready, .clockedInWaiting, .earning, .awaitingClockOut, .completed:
                let amount = try XCTUnwrap(panelAmount)
                XCTAssertTrue(detail.contains(amount), "Amount-bearing menu states share the authoritative panel amount")
            }
            let attachment = XCTAttachment(string: renderedText(host))
            attachment.name = "Stage9-Menu-AX-\(expectedState.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testHostedMenuRecoveryAndDamagedSettingsPreserveContractPriorityAndDisabledStartToday() async throws {
        let settings = ApplicationTestSupport.committedSettings(wageCents: 90_000)
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: ApplicationTestSupport.timestamp(hour: 9))
        let settingsDamage = DamagedRecordResult(kind: .settings, issue: .invalidSchemaEnvelope,
            disposition: .requireSettingsRecovery)
        let todayDamage = DamagedRecordResult(kind: .today, issue: .invalidSchemaEnvelope,
            disposition: .requireTodayReset)
        for variant in ["settings-only", "both-damaged", "previous-completed"] {
            let repository = BusinessRecordRepositorySpy(settings: .damaged(settingsDamage),
                today: variant == "both-damaged" ? .damaged(todayDamage) :
                    variant == "previous-completed" ? .loaded(today, migration: .current) : .missing)
            let store = try BusinessStore(repository: repository,
                nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(day: 14, hour: 10)),
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier,
                notificationService: FakeNotificationService())
            await store.restore()
            if variant == "previous-completed" {
                let settled = await store.send(.requestClockOut, source: .panel)
                XCTAssertEqual(settled, .committed)
                XCTAssertEqual(store.viewState?.canRequestStartToday, false)
            }
            let before = store.viewState
            let todayBefore = await repository.currentToday()
            let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
                loginItemService: FakeLoginItemService())
            let menu = HostedSettings(VStack(alignment: .leading) { MenuBarContentView(environment: environment) })
            defer { menu.close() }
            try await Stage9EnableHostedAccessibility()
            let host = try XCTUnwrap(menu.window.contentView)
            try await eventually { self.findElement(label: "打开设置…", in: host, buttonOnly: true) != nil }
            let texts = axElements(in: host).filter {
                self.axObject($0, "accessibilityRole") as? String == "AXStaticText"
            }.flatMap { self.axTexts($0) }
            if variant == "previous-completed" {
                XCTAssertTrue(texts.contains("上一工作日已结算 · 2026-08-13"))
                XCTAssertTrue(texts.contains("最终收入 ¥900.00"))
                XCTAssertTrue(texts.contains("设置需要修复"))
                try assertMenuControls(host, action: "开始今天…")
                let button = try element(label: "开始今天…", in: host, buttonOnly: true)
                XCTAssertEqual(boolAttribute(button, "isAccessibilityEnabled"), false)
                XCTAssertTrue(axTexts(button, includeHelp: true).contains("请先修复设置，再开始今天"))
            } else {
                let expected = variant == "both-damaged" ? ["今日记录需要恢复", "设置数据也无法读取"] :
                    ["设置数据无法读取", "请打开设置重新填写"]
                for text in expected { XCTAssertTrue(texts.contains(text), "\(variant): \(texts)") }
                XCTAssertFalse(texts.contains { $0.contains("¥") })
                try assertMenuControls(host, action: nil)
            }
            let settingsButton = try element(label: "打开设置…", in: host, buttonOnly: true)
            XCTAssertEqual(boolAttribute(settingsButton, "isAccessibilityEnabled"), true)
            XCTAssertEqual(store.viewState, before)
            let todayAfter = await repository.currentToday()
            XCTAssertEqual(todayAfter, todayBefore)
        }
    }

    func testHostedMenuWhileRestoreHeldDisablesPanelAndExposesNoBusinessAction() async throws {
        let repository = BusinessRecordRepositorySpy(settings: .loaded(ApplicationTestSupport.committedSettings(), migration: .current))
        await repository.holdNextBusinessSettingsLoad()
        let store = try BusinessStore(repository: repository,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        let restoring = Task { await store.restore() }
        defer { Task { await repository.resumeBusinessSettingsLoad() } }
        try await eventually { store.isRestoring }
        await repository.waitUntilBusinessSettingsLoadHeld()
        let environment = AppEnvironment(businessStore: store, panelController: PanelControllerSpy(),
            loginItemService: FakeLoginItemService())
        let menu = HostedSettings(VStack(alignment: .leading) { MenuBarContentView(environment: environment) })
        defer { menu.close() }
        try await Stage9EnableHostedAccessibility()
        let host = try XCTUnwrap(menu.window.contentView)
        try await eventually { self.renderedText(host).contains("正在恢复今日记录…") }
        XCTAssertTrue(renderedText(host).contains("本地读取完成后即可使用"))
        try assertMenuControls(host, action: nil)
        let panel = try element(label: "显示收入面板", in: host, buttonOnly: true)
        XCTAssertEqual(boolAttribute(panel, "isAccessibilityEnabled"), false)
        let settings = try element(label: "打开设置…", in: host, buttonOnly: true)
        XCTAssertEqual(boolAttribute(settings, "isAccessibilityEnabled"), true)
        await repository.resumeBusinessSettingsLoad()
        await restoring.value
        try await eventually { self.renderedText(host).contains("今日未打卡") }
        let restoredPanel = try element(label: "显示收入面板", in: host, buttonOnly: true)
        XCTAssertEqual(boolAttribute(restoredPanel, "isAccessibilityEnabled"), true)
    }

    func testDiagnosticNativeButtonExplicitFocusableComparison() async throws {
        let process = ProcessInfo.processInfo.environment
        guard process["XCTestConfigurationFilePath"] != nil || process["INCOMECLOCK_TEST_ROOT"] != nil else {
            XCTFail("Requires isolated XCTest application host")
            return
        }
        try await Stage9EnableHostedAccessibility()
        var outcomes: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: outcomes, options: [.sortedKeys]),
               data.count <= 24_000 {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Diagnostic-Button-Explicit-Focusable-Comparison"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Bounded diagnostic attachment could not be serialized") }
        }
        func frame(_ object: NSObject) -> CGRect? {
            guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        func describe(_ object: NSObject) -> [String: Any] {
            ["type": String(describing: type(of: object)),
             "role": self.axObject(object, "accessibilityRole") as? String ?? "nil",
             "text": self.axTexts(object), "frame": String(describing: frame(object)),
             "focused": self.boolAttribute(object, "isAccessibilityFocused").map(String.init) ?? "nil"]
        }
        func observe(explicitFocusable: Bool) async throws -> [String: Any] {
            let probe = FocusableComparisonProbe()
            let panel = IncomePanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 190),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.contentViewController = NSHostingController(rootView:
                FocusableComparisonView(probe: probe, explicitFocusable: explicitFocusable))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 160,
                    y: screen.visibleFrame.midY - 95))
            }
            defer { panel.orderOut(nil); panel.close() }
            let content = try XCTUnwrap(panel.contentView)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            try await eventually { panel.isVisible && panel.isKeyWindow }
            guard NSApp.isFullKeyboardAccessEnabled else {
                throw NSError(domain: "FocusableComparisonHostFKARequired", code: 1)
            }
            func buttons() -> [NSObject] {
                self.axElements(in: content).filter {
                    self.axObject($0, "accessibilityRole") as? String == "AXButton" &&
                    self.axTexts($0).contains("Probe action")
                }
            }
            try await eventually { buttons().count == 1 }
            func nativeFocusedObjects() -> [NSObject] {
                [NSApp as NSObject, content, panel].flatMap { root in
                    ["accessibilityFocusedUIElement", "accessibilityFocusedElement"].compactMap {
                        self.axObject(root, $0) as? NSObject
                    }
                }
            }
            func actualButtonFocus() -> Bool {
                guard panel.isKeyWindow, let button = buttons().first,
                      self.boolAttribute(button, "isAccessibilityEnabled") == true else { return false }
                if self.axElements(in: button).contains(where: {
                    self.boolAttribute($0, "isAccessibilityFocused") == true
                }) { return true }
                return nativeFocusedObjects().contains { focused in
                    if focused === button { return true }
                    guard self.axObject(focused, "accessibilityRole") as? String == "AXButton",
                          self.axTexts(focused).contains("Probe action"),
                          let actual = frame(focused), let expected = frame(button),
                          actual.width > 0, actual.height > 0 else { return false }
                    return abs(actual.minX - expected.minX) <= 0.5 &&
                        abs(actual.minY - expected.minY) <= 0.5 &&
                        abs(actual.width - expected.width) <= 0.5 &&
                        abs(actual.height - expected.height) <= 0.5
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let before = actualButtonFocus()
            // Only the controlled fixture writes its FocusState. Production
            // coordinator/view/test state is never modified by this diagnostic.
            probe.request += 1
            var observed = actualButtonFocus()
            for _ in 0..<100 where !observed {
                try await Task.sleep(nanoseconds: 10_000_000)
                observed = actualButtonFocus()
            }
            return ["explicitFocusable": explicitFocusable,
                "qualified": panel.isVisible && panel.isKeyWindow && NSApp.isFullKeyboardAccessEnabled,
                "window": panel.windowNumber, "appActive": NSApp.isActive,
                "key": panel.isKeyWindow, "fullKeyboardAccess": NSApp.isFullKeyboardAccessEnabled,
                "beforeRequestActualFocus": before, "observedActualButtonFocus": observed,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "fixtureFocusStateDiagnosticOnly": probe.appliedFocus,
                "buttonCount": buttons().count, "buttons": buttons().map(describe),
                "nativeAXFocus": nativeFocusedObjects().map(describe),
                "firstResponder": panel.firstResponder.map(describe) ?? [:],
                "actionCount": probe.actionCount]
        }
        // Two fresh panels with identical style/size/content; no order reuse or
        // repeated retries. false is a diagnostic outcome, not a test failure.
        for explicit in [true, false] {
            do { outcomes.append(try await observe(explicitFocusable: explicit)) }
            catch { outcomes.append(["explicitFocusable": explicit, "qualified": false,
                                     "error": String(describing: error)]) }
        }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0["qualified"] as? Bool == true },
            "Both diagnostic observations require actual key and host FKA; outcomes are not acceptance")
    }

    func testDiagnosticNativeButtonDisabledPulseComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil || environment["INCOMECLOCK_TEST_ROOT"] != nil else {
            XCTFail("Requires isolated XCTest application host")
            return
        }
        try await Stage9EnableHostedAccessibility()
        var outcomes: [[String: Any]] = []
        func frame(_ node: NSObject) -> CGRect? {
            guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        func describe(_ node: NSObject) -> [String: Any] {
            ["role": self.axObject(node, "accessibilityRole") as? String ?? "nil",
             "text": self.axTexts(node).prefix(2).map { String($0.prefix(32)) }, "frame": String(describing: frame(node)).prefix(96).description,
             "enabled": self.boolAttribute(node, "isAccessibilityEnabled").map(String.init) ?? "nil",
             "focused": self.boolAttribute(node, "isAccessibilityFocused").map(String.init) ?? "nil"]
        }
        func observe(_ id: String, disable: Bool, pulsing: Bool) async -> [String: Any] {
            let probe = DisabledPulseProbe()
            let pulse = DisabledPulseCounter()
            let panel = IncomePanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 190),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.contentViewController = NSHostingController(rootView: DisabledPulseView(probe: probe, pulse: pulse))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.midY - 95))
            }
            var pulseTask: Task<Void, Never>?
            defer { pulseTask?.cancel(); panel.orderOut(nil); panel.close(); panel.contentViewController = nil }
            guard let content = panel.contentView else { return ["id": id, "qualified": false, "failedPrecondition": "content"] }
            func buttons() -> [NSObject] {
                self.axElements(in: content).filter { self.axObject($0, "accessibilityRole") as? String == "AXButton" }
            }
            func button(_ label: String) -> NSObject? {
                let matches = buttons().filter { self.axTexts($0).contains(label) }
                return matches.count == 1 ? matches.first : nil
            }
            func nativeObjects() -> [NSObject] {
                let roots: [NSObject] = [NSApp, panel, content] + (panel.firstResponder.map { [$0] } ?? [])
                return roots.flatMap { root in
                    ["accessibilityFocusedUIElement", "accessibilityApplicationFocusedUIElement"].compactMap {
                        self.axObject(root, $0) as? NSObject
                    }
                }
            }
            func hostQualified() -> Bool {
                panel.isVisible && panel.isKeyWindow && NSApp.keyWindow === panel && NSApp.isActive &&
                    NSApp.isFullKeyboardAccessEnabled && buttons().count == 3 &&
                    ["Settings", "Hide", "Primary"].allSatisfy { button($0) != nil }
            }
            func actualFocus(_ label: String) -> Bool {
                guard hostQualified(), let target = button(label),
                      self.boolAttribute(target, "isAccessibilityEnabled") == true else { return false }
                if self.axElements(in: target).contains(where: { self.boolAttribute($0, "isAccessibilityFocused") == true }) { return true }
                return nativeObjects().contains { focused in
                    if focused === target { return true }
                    guard self.axObject(focused, "accessibilityRole") as? String == "AXButton",
                          self.axTexts(focused).contains(label), let actual = frame(focused),
                          let expected = frame(target), actual.width > 0, actual.height > 0 else { return false }
                    return abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5 &&
                        abs(actual.width - expected.width) <= 0.5 && abs(actual.height - expected.height) <= 0.5
                }
            }
            func snapshot(_ phase: String) -> [String: Any] {
                let native = nativeObjects()
                var seen = Set<String>()
                let unique = native.map(describe).filter { descriptor in
                    let key = String(describing: descriptor["role"]) + String(describing: descriptor["text"]) + String(describing: descriptor["frame"])
                    return seen.insert(key).inserted
                }
                return ["phase": phase, "elapsed": probe.elapsed, "panelWindow": panel.windowNumber,
                 "appKeyWindow": NSApp.keyWindow?.windowNumber ?? -1, "panelKey": panel.isKeyWindow,
                 "appKeyIsPanel": NSApp.keyWindow === panel, "appActive": NSApp.isActive,
                 "visible": panel.isVisible, "FKA": NSApp.isFullKeyboardAccessEnabled,
                 "localFocusDiagnosticOnly": probe.localFocus, "ticks": pulse.ticks,
                 "buttons": buttons().prefix(3).map(describe), "nativeAX": Array(unique.prefix(2)),
                 "nativeRawCount": native.count, "nativeUniqueCount": unique.count]
            }
            func waitFor(_ condition: () -> Bool) async throws -> Bool {
                for _ in 0..<100 {
                    if condition() { return true }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                return condition()
            }
            var row: [String: Any] = ["id": id, "disableReenable": disable, "nominalPulse": pulsing,
                                      "qualified": false, "coverageResult": "DIAGNOSTIC_ONLY"]
            var phases: [[String: Any]] = []
            do {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                guard try await waitFor(hostQualified) else { throw DisabledPulsePrecondition.failed("host-or-three-buttons") }
                probe.request = .primary
                guard try await waitFor({ actualFocus("Primary") }) else { throw DisabledPulsePrecondition.failed("initial-primary-native-focus") }
                phases.append(snapshot("initial-primary-qualified"))
                if disable {
                    probe.primaryDisabled = true
                    guard try await waitFor({ button("Primary").flatMap { self.boolAttribute($0, "isAccessibilityEnabled") } == false }) else {
                        throw DisabledPulsePrecondition.failed("disabled-AX-not-observed")
                    }
                    phases.append(snapshot("primary-disabled-AX"))
                    probe.primaryDisabled = false
                    guard try await waitFor({ button("Primary").flatMap { self.boolAttribute($0, "isAccessibilityEnabled") } == true }) else {
                        throw DisabledPulsePrecondition.failed("reenabled-AX-not-observed")
                    }
                    phases.append(snapshot("primary-reenabled-AX"))
                }
                if pulsing {
                    pulseTask = Task { @MainActor in
                        for _ in 0..<120 {
                            do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
                            guard !Task.isCancelled else { return }
                            pulse.tickTimes.append(probe.elapsed)
                            pulse.ticks += 1
                        }
                    }
                    guard try await waitFor({ pulse.ticks > 0 }) else { throw DisabledPulsePrecondition.failed("pulse-not-started") }
                }
                probe.request = .settings
                guard try await waitFor({ actualFocus("Settings") }) else { throw DisabledPulsePrecondition.failed("settings-native-focus") }
                phases.append(snapshot("before-final-primary-request"))
                row["ticksAtRequest"] = pulse.ticks
                row["requestElapsed"] = probe.elapsed
                probe.request = .primary
                // Sample the entire fixed window even after first focus success.
                // This measures overlap; it is not a delay used to repair focus.
                // No action, nil-reset, AX setter or direct responder assignment.
                let ticksAtRequest = pulse.ticks
                var firstFocusElapsed: Double? = actualFocus("Primary") ? probe.elapsed : nil
                var hostStayedQualified = hostQualified()
                for _ in 0..<100 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    hostStayedQualified = hostStayedQualified && hostQualified()
                    if firstFocusElapsed == nil && actualFocus("Primary") { firstFocusElapsed = probe.elapsed }
                }
                row["actualPrimaryFocusObserved"] = firstFocusElapsed != nil
                row["firstFocusElapsed"] = firstFocusElapsed.map { $0 as Any } ?? NSNull()
                row["finalActualPrimaryFocus"] = actualFocus("Primary")
                row["ticksDuringFinalObservation"] = pulse.ticks - ticksAtRequest
                row["pulseOverlap"] = pulsing ? (pulse.ticks > ticksAtRequest ? "OBSERVED" : "NOT_OBSERVED") : "NOT_REQUESTED"
                row["hostStayedQualified"] = hostStayedQualified
                row["qualified"] = hostStayedQualified && hostQualified() && probe.actionCount == 0
                if !hostStayedQualified || !hostQualified() { row["failedPrecondition"] = "host-lost-during-observation" }
                phases.append(snapshot("final"))
            } catch {
                row["failedPrecondition"] = String(String(describing: error).prefix(160))
                phases.append(snapshot("invalid-cell"))
            }
            pulseTask?.cancel()
            row["phases"] = phases
            row["focusEventsDiagnosticOnly"] = probe.events
            row["droppedFocusEvents"] = probe.droppedEvents
            let times = pulse.tickTimes
            let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
            row["tickTiming"] = [
                "count": times.count,
                "firstElapsed": times.first.map { $0 as Any } ?? NSNull(),
                "lastElapsed": times.last.map { $0 as Any } ?? NSNull(),
                "boundedElapsedSamples": Array(times.prefix(4)) + Array(times.dropFirst(min(4, times.count)).suffix(4)),
                "minIntervalSeconds": intervals.min().map { $0 as Any } ?? NSNull(),
                "maxIntervalSeconds": intervals.max().map { $0 as Any } ?? NSNull(),
                "meanIntervalSeconds": intervals.isEmpty ? NSNull() : (intervals.reduce(0, +) / Double(intervals.count)) as Any,
                "finalElapsed": probe.elapsed
            ] as [String: Any]
            row["ticks"] = pulse.ticks
            row["elapsedSeconds"] = probe.elapsed
            row["actionCount"] = probe.actionCount
            return row
        }
        for (id, disable, pulse) in [("control", false, false), ("disabled_only", true, false),
                                      ("pulse_only", false, true), ("disabled_and_pulse", true, true)] {
            outcomes.append(await observe(id, disable: disable, pulsing: pulse))
        }
        let result: [String: Any] = ["cells": outcomes,
            "interpretation": "Diagnostic only; PASS means qualified observations, not acceptance. One observation per cell. Nominal timer spacing does not measure render Hz or FPS."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 24_000, "Diagnostic payload must remain bounded")
        let attachmentData: Data
        if data.count <= 24_000 { attachmentData = data }
        else {
            // Always emit one bounded valid JSON, never silently lose an oversized result.
            attachmentData = try JSONSerialization.data(withJSONObject: [
                "qualified": false, "coverageResult": "DIAGNOSTIC_INVALID",
                "failedPrecondition": "payload-overflow", "attemptedBytes": data.count,
                "cellCount": outcomes.count
            ], options: [.sortedKeys])
        }
        let attachment = XCTAttachment(data: attachmentData, uniformTypeIdentifier: "public.json")
        attachment.name = "Diagnostic-Native-Button-Disabled-Pulse"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertTrue(outcomes.allSatisfy { $0["qualified"] as? Bool == true }, "Invalid cells cannot support causal inference")
    }

    func testDiagnosticFreshEarningProductionPanelNativeFocus() async throws {
        let process = ProcessInfo.processInfo.environment
        guard process["XCTestConfigurationFilePath"] != nil || process["INCOMECLOCK_TEST_ROOT"] != nil else {
            XCTFail("Requires isolated XCTest application host")
            return
        }
        let settings = ApplicationTestSupport.committedSettings()
        let today = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            .proposedToday(from: settings, at: ApplicationTestSupport.timestamp(hour: 9))
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current),
            today: .loaded(today, migration: .current))
        let coordinated = PanelSettingsCoordinator(repository: repository, preferenceStore: EphemeralPanelPreferenceStore())
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try BusinessStore(repository: coordinated, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        // Seeded repository is already earning before any production panel exists.
        // Never issue clock-in, clock-out, Settings, or other business actions.
        let earningBeforePanel = store.viewState?.state == .earning
        let idleBeforePanel = !store.isCommandInFlight && store.confirmation == nil
        guard earningBeforePanel && idleBeforePanel else {
            XCTFail("Seeded earning/idle precondition failed before panel creation")
            return
        }
        let controller = PanelController(businessStore: store, repository: coordinated,
            nowMilliseconds: { clock.nowMilliseconds().rawValue })
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        let content = try XCTUnwrap(panel.contentView)
        let epoch = ProcessInfo.processInfo.systemUptime
        var trace: [String] = []
        var droppedTrace = 0
        var snapshots: [[String: Any]] = []
        var result: [String: Any] = ["qualified": false, "coverageResult": "DIAGNOSTIC_ONLY",
            "earningBeforePanelCreation": earningBeforePanel, "idleBeforePanelCreation": idleBeforePanel]
        func record(_ text: String) {
            guard trace.count < 24 else { droppedTrace += 1; return }
            // Bound UTF-8 bytes per entry; diagnostics never expose unrelated windows.
            trace.append(String(decoding: Data(text.utf8.prefix(480)), as: UTF8.self))
        }
#if DEBUG
        controller.focusDeliveryTrace = { entry in record("t=\(ProcessInfo.processInfo.systemUptime - epoch) " + entry) }
#endif
        func frame(_ node: NSObject) -> CGRect? {
            guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        func buttons() -> [NSObject] {
            self.axElements(in: content).filter { self.axObject($0, "accessibilityRole") as? String == "AXButton" }
        }
        func nativeObjects() -> [NSObject] {
            let roots: [NSObject] = [NSApp, panel] + (panel.firstResponder.map { [$0] } ?? [])
            return roots.flatMap { root in
                ["accessibilityFocusedUIElement", "accessibilityApplicationFocusedUIElement"].compactMap {
                    self.axObject(root, $0) as? NSObject
                }
            }
        }
        func hostQualified() -> Bool {
            panel.isVisible && panel.isKeyWindow && NSApp.keyWindow === panel && NSApp.isActive && NSApp.isFullKeyboardAccessEnabled
        }
        func actualFocus(_ label: String) -> Bool {
            let matches = buttons().filter { self.axTexts($0).contains(label) }
            guard hostQualified(), matches.count == 1, let button = matches.first,
                  self.boolAttribute(button, "isAccessibilityEnabled") == true else { return false }
            if self.axElements(in: button).contains(where: { self.boolAttribute($0, "isAccessibilityFocused") == true }) { return true }
            return nativeObjects().contains { focused in
                if focused === button { return true }
                guard self.axObject(focused, "accessibilityRole") as? String == "AXButton",
                      self.axTexts(focused).contains(label), let actual = frame(focused), let expected = frame(button),
                      actual.width > 0, actual.height > 0 else { return false }
                return abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5 &&
                    abs(actual.width - expected.width) <= 0.5 && abs(actual.height - expected.height) <= 0.5
            }
        }
        func describe(_ node: NSObject) -> [String: Any] {
            ["role": self.axObject(node, "accessibilityRole") as? String ?? "nil",
             "text": self.axTexts(node).prefix(2).map { String($0.prefix(32)) },
             "frame": String(describing: frame(node)),
             "enabled": self.boolAttribute(node, "isAccessibilityEnabled").map(String.init) ?? "nil",
             "focused": self.boolAttribute(node, "isAccessibilityFocused").map(String.init) ?? "nil"]
        }
        func snapshot(_ phase: String) {
            let native = nativeObjects()
            var seen = Set<String>()
            let unique = native.map(describe).filter { d in
                seen.insert(String(describing: d["role"]) + String(describing: d["text"]) + String(describing: d["frame"])).inserted
            }
#if DEBUG
            let semantic = String(describing: panel.semanticFocusForTesting?())
#else
            let semantic = "unavailable"
#endif
            snapshots.append(["phase": phase, "elapsed": ProcessInfo.processInfo.systemUptime - epoch,
                "earning": store.viewState?.state == .earning, "busy": store.isCommandInFlight,
                "confirmation": store.confirmation != nil, "appActive": NSApp.isActive,
                "panelKey": panel.isKeyWindow, "appKeyIsPanel": NSApp.keyWindow === panel,
                "visible": panel.isVisible, "FKA": NSApp.isFullKeyboardAccessEnabled,
                "buttons": buttons().prefix(3).map(describe), "buttonCount": buttons().count,
                "nativeAX": Array(unique.prefix(2)), "nativeRawCount": native.count,
                "semanticFocusDiagnosticOnly": semantic])
        }
        defer {
#if DEBUG
            controller.focusDeliveryTrace = nil
#endif
            result["snapshots"] = snapshots
            result["routingTraceDiagnosticOnly"] = trace
            result["droppedTrace"] = droppedTrace
            result["interpretation"] = "One fresh earning production panel. No mounted clock-in lifecycle. Native focus outcome is diagnostic, not acceptance; semantic trace cannot satisfy native focus."
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachmentData: Data
                if data.count <= 24_000 { attachmentData = data }
                else {
                    XCTFail("Diagnostic payload overflow")
                    attachmentData = Data("{\"qualified\":false,\"failedPrecondition\":\"payload-overflow\"}".utf8)
                }
                let attachment = XCTAttachment(data: attachmentData, uniformTypeIdentifier: "public.json")
                attachment.name = "Diagnostic-Fresh-Earning-Production-Focus"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Diagnostic JSON serialization failed") }
            controller.hide(persist: false)
        }
        try await Stage9EnableHostedAccessibility()
        snapshot("created-before-show")
        controller.show(persist: false, focus: true)
        var settingsFocused = actualFocus("打开设置")
        for _ in 0..<100 where !settingsFocused {
            try await Task.sleep(nanoseconds: 10_000_000)
            settingsFocused = actualFocus("打开设置")
        }
        snapshot("settings-qualification")
        let primary = buttons().filter { self.axTexts($0).contains("打卡下班") }
        guard settingsFocused, primary.count == 1,
              self.boolAttribute(primary[0], "isAccessibilityEnabled") == true,
              store.viewState?.state == .earning, !store.isCommandInFlight, store.confirmation == nil else {
            result["failedPrecondition"] = "earning-enabled-primary-or-native-settings-focus"
            XCTFail("Fresh earning native Settings qualification failed")
            return
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        result["matchedKeyboardCommandDiagnosticOnly"] = String(describing: IncomePanel.keyboardCommand(for: event))
        result["sentShiftTabCount"] = 1
        NSApp.sendEvent(event)
        var firstFocusElapsed: Double? = actualFocus("打卡下班") ? ProcessInfo.processInfo.systemUptime - epoch : nil
        var qualificationHeld = hostQualified()
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            qualificationHeld = qualificationHeld && hostQualified() && store.viewState?.state == .earning &&
                !store.isCommandInFlight && store.confirmation == nil
            if firstFocusElapsed == nil && actualFocus("打卡下班") { firstFocusElapsed = ProcessInfo.processInfo.systemUptime - epoch }
        }
        snapshot("after-single-shift-tab")
        result["qualified"] = qualificationHeld
        result["firstNativePrimaryFocusElapsed"] = firstFocusElapsed.map { $0 as Any } ?? NSNull()
        result["actualPrimaryFocusObserved"] = firstFocusElapsed != nil
        result["finalActualPrimaryFocus"] = actualFocus("打卡下班")
        let retained = await repository.currentToday()
        result["recordUnchanged"] = retained == today
        XCTAssertEqual(retained, today, "Focus navigation must not mutate the seeded business record")
        XCTAssertTrue(qualificationHeld, "Host/state loss invalidates diagnostic interpretation")
    }

    func testDiagnosticMinimalClockInProductionPanelNativeFocus() async throws {
        try await diagnoseClockInProductionPanelNativeFocus(advanceClockAfterClockIn: false)
    }

    func testDiagnosticClockAdvanceProductionPanelNativeFocus() async throws {
        try await diagnoseClockInProductionPanelNativeFocus(advanceClockAfterClockIn: true)
    }

    private func diagnoseClockInProductionPanelNativeFocus(advanceClockAfterClockIn: Bool) async throws {
        let process = ProcessInfo.processInfo.environment
        guard process["XCTestConfigurationFilePath"] != nil || process["INCOMECLOCK_TEST_ROOT"] != nil else {
            XCTFail("Requires isolated XCTest application host")
            return
        }
        let settings = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(settings: .loaded(settings, migration: .current), today: .missing)
        let coordinated = PanelSettingsCoordinator(repository: repository, preferenceStore: EphemeralPanelPreferenceStore())
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try BusinessStore(repository: coordinated, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let readyBeforePanel = store.viewState?.state == .ready
        let idleBeforePanel = !store.isCommandInFlight && store.confirmation == nil
        guard readyBeforePanel && idleBeforePanel else {
            XCTFail("Ready/idle precondition failed before panel creation")
            return
        }
        let controller = PanelController(businessStore: store, repository: coordinated,
            nowMilliseconds: { clock.nowMilliseconds().rawValue })
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        let content = try XCTUnwrap(panel.contentView)
        let epoch = ProcessInfo.processInfo.systemUptime
        var trace: [String] = []
        var droppedTrace = 0
        var snapshots: [[String: Any]] = []
        var result: [String: Any] = ["qualified": false, "coverageResult": "DIAGNOSTIC_ONLY",
            "readyBeforePanelCreation": readyBeforePanel, "idleBeforePanelCreation": idleBeforePanel]
        func record(_ text: String) {
            guard trace.count < 24 else { droppedTrace += 1; return }
            // Bound UTF-8 bytes per entry; diagnostics never expose unrelated windows.
            trace.append(String(decoding: Data(text.utf8.prefix(480)), as: UTF8.self))
        }
#if DEBUG
        controller.focusDeliveryTrace = { entry in record("t=\(ProcessInfo.processInfo.systemUptime - epoch) " + entry) }
#endif
        func frame(_ node: NSObject) -> CGRect? {
            guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        func buttons() -> [NSObject] {
            self.axElements(in: content).filter { self.axObject($0, "accessibilityRole") as? String == "AXButton" }
        }
        func nativeObjects() -> [NSObject] {
            let roots: [NSObject] = [NSApp, panel] + (panel.firstResponder.map { [$0] } ?? [])
            return roots.flatMap { root in
                ["accessibilityFocusedUIElement", "accessibilityApplicationFocusedUIElement"].compactMap {
                    self.axObject(root, $0) as? NSObject
                }
            }
        }
        func hostQualified() -> Bool {
            panel.isVisible && panel.isKeyWindow && NSApp.keyWindow === panel && NSApp.isActive && NSApp.isFullKeyboardAccessEnabled
        }
        func actualFocus(_ label: String) -> Bool {
            let matches = buttons().filter { self.axTexts($0).contains(label) }
            guard hostQualified(), matches.count == 1, let button = matches.first,
                  self.boolAttribute(button, "isAccessibilityEnabled") == true else { return false }
            if self.axElements(in: button).contains(where: { self.boolAttribute($0, "isAccessibilityFocused") == true }) { return true }
            return nativeObjects().contains { focused in
                if focused === button { return true }
                guard self.axObject(focused, "accessibilityRole") as? String == "AXButton",
                      self.axTexts(focused).contains(label), let actual = frame(focused), let expected = frame(button),
                      actual.width > 0, actual.height > 0 else { return false }
                return abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5 &&
                    abs(actual.width - expected.width) <= 0.5 && abs(actual.height - expected.height) <= 0.5
            }
        }
        func describe(_ node: NSObject) -> [String: Any] {
            ["role": self.axObject(node, "accessibilityRole") as? String ?? "nil",
             "text": self.axTexts(node).prefix(2).map { String($0.prefix(32)) },
             "frame": String(describing: frame(node)),
             "enabled": self.boolAttribute(node, "isAccessibilityEnabled").map(String.init) ?? "nil",
             "focused": self.boolAttribute(node, "isAccessibilityFocused").map(String.init) ?? "nil"]
        }
        func snapshot(_ phase: String) {
            let native = nativeObjects()
            var seen = Set<String>()
            let unique = native.map(describe).filter { d in
                seen.insert(String(describing: d["role"]) + String(describing: d["text"]) + String(describing: d["frame"])).inserted
            }
#if DEBUG
            let semantic = String(describing: panel.semanticFocusForTesting?())
#else
            let semantic = "unavailable"
#endif
            snapshots.append(["phase": phase, "elapsed": ProcessInfo.processInfo.systemUptime - epoch,
                "earning": store.viewState?.state == .earning, "busy": store.isCommandInFlight,
                "confirmation": store.confirmation != nil, "appActive": NSApp.isActive,
                "panelKey": panel.isKeyWindow, "appKeyIsPanel": NSApp.keyWindow === panel,
                "visible": panel.isVisible, "FKA": NSApp.isFullKeyboardAccessEnabled,
                "buttons": buttons().prefix(3).map(describe), "buttonCount": buttons().count,
                "nativeAX": Array(unique.prefix(2)), "nativeRawCount": native.count,
                "semanticFocusDiagnosticOnly": semantic])
            if advanceClockAfterClockIn, let index = snapshots.indices.last {
                snapshots[index]["clockObservedMs"] = clock.nowMilliseconds().rawValue
                snapshots[index]["projectedAmountDiagnosticOnly"] = store.viewState.flatMap {
                    Stage5AmountFormatter.string(for: $0.amount)
                } ?? "nil"
                snapshots[index]["nativeAmountTargetTextDiagnosticOnly"] = self.nativeAmount(in: content)?.targetText ?? "nil"
            }
        }
        var busyPublications: [[String: Any]] = []
        var busyPublished = false
        var busyObservedDuringPoll = false
        let busyToken = store.$isCommandInFlight.sink { value in
            MainActor.assumeIsolated {
                busyPublished = busyPublished || value
                if busyPublications.count < 8 {
                    busyPublications.append(["deliveredBusy": value,
                        "elapsed": ProcessInfo.processInfo.systemUptime - epoch,
                        "storeBusyAtWillSetDiagnosticOnly": store.isCommandInFlight])
                }
            }
        }
        defer {
            busyToken.cancel()
            result["busyPublished"] = busyPublished
            result["busyObservedDuringPoll"] = busyObservedDuringPoll
            result["busyPublicationsDiagnosticOnly"] = busyPublications
#if DEBUG
            controller.focusDeliveryTrace = nil
#endif
            result["snapshots"] = snapshots
            result["routingTraceDiagnosticOnly"] = trace
            result["droppedTrace"] = droppedTrace
            result["interpretation"] = "One fresh ready production panel, one native clock-in, unchanged clock, no Settings window or hide. Focus outcome diagnostic only; busy publisher delivery precedes rendered disabled state and cannot prove rendered busy."
            if advanceClockAfterClockIn {
                result["interpretation"] = "One native clock-in at 10 then test clock advanced to 13 immediately before second focused-show. No explicit refresh or wait for updated projection. Compare minimal lifecycle diagnostically; no acceptance or repair conclusion."
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachmentData: Data
                if data.count <= 24_000 { attachmentData = data }
                else {
                    XCTFail("Diagnostic payload overflow")
                    attachmentData = Data("{\"qualified\":false,\"failedPrecondition\":\"payload-overflow\"}".utf8)
                }
                let attachment = XCTAttachment(data: attachmentData, uniformTypeIdentifier: "public.json")
                attachment.name = advanceClockAfterClockIn ? "Diagnostic-ClockAdvance-Production-Focus" : "Diagnostic-Minimal-ClockIn-Production-Focus"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Diagnostic JSON serialization failed") }
            controller.hide(persist: false)
        }
        try await Stage9EnableHostedAccessibility()
        snapshot("created-before-show")
        func waitFor(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        func sendKey(_ code: UInt16, _ characters: String, shift: Bool = false) throws {
            guard hostQualified() else { throw DisabledPulsePrecondition.failed("host-before-key") }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            record("key code=\(code) shift=\(shift) matched=\(String(describing: IncomePanel.keyboardCommand(for: event)))")
            NSApp.sendEvent(event)
        }
        controller.show(persist: false, focus: true)
        guard try await waitFor({ actualFocus("打开设置") }) else {
            result["failedPrecondition"] = "initial-settings-focus"
            XCTFail("Initial Settings native focus missing"); return
        }
        try sendKey(48, "\t", shift: true)
        guard try await waitFor({ actualFocus("打卡上班") }), store.viewState?.state == .ready else {
            result["failedPrecondition"] = "ready-clock-in-native-focus"
            XCTFail("Ready primary native focus missing"); return
        }
        snapshot("before-only-clock-in")
        result["sentClockInReturnCount"] = 1
        try sendKey(36, "\r")
        var transitionHostHeld = hostQualified()
        var sawEarning = false
        for _ in 0..<100 {
            transitionHostHeld = transitionHostHeld && hostQualified()
            if store.isCommandInFlight && !busyObservedDuringPoll {
                busyObservedDuringPoll = true
                snapshot("first-polled-busy")
            }
            if store.viewState?.state == .earning && !store.isCommandInFlight {
                sawEarning = true; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        snapshot("post-clock-in")
        let clockedInRecord = await repository.currentToday()
        result["clockInAtMs"] = clockedInRecord.map { $0.clockInAtMs as Any } ?? NSNull()
        result["clockOutAtMs"] = clockedInRecord?.clockOutAtMs.map { $0 as Any } ?? NSNull()
        guard sawEarning, transitionHostHeld,
              clockedInRecord?.clockInAtMs == clock.nowMilliseconds().rawValue,
              clockedInRecord?.clockOutAtMs == nil, store.confirmation == nil else {
            result["failedPrecondition"] = "clock-in-state-record-or-host"
            XCTFail("Clock-in transition qualification failed"); return
        }
        if advanceClockAfterClockIn {
            // The sole changed stimulus follows the original strict scenario.
            // Do not refresh or wait for projection changes before native navigation.
            result["clockBeforeAdvanceMs"] = clock.nowMilliseconds().rawValue
            result["advanceElapsed"] = ProcessInfo.processInfo.systemUptime - epoch
            clock.set(ApplicationTestSupport.timestamp(hour: 13))
            result["clockAfterAdvanceMs"] = clock.nowMilliseconds().rawValue
        }
        // Existing focused-show route; panel remains visible.
        controller.show(persist: false, focus: true)
        guard try await waitFor({ actualFocus("打开设置") }) else {
            result["failedPrecondition"] = "post-clock-in-settings-focus"
            XCTFail("Post-clock-in Settings native focus missing"); return
        }
        snapshot("post-clock-in-settings-qualification")
        let primary = buttons().filter { self.axTexts($0).contains("打卡下班") }
        guard primary.count == 1, self.boolAttribute(primary[0], "isAccessibilityEnabled") == true,
              store.viewState?.state == .earning, !store.isCommandInFlight, store.confirmation == nil else {
            result["failedPrecondition"] = "post-clock-in-enabled-primary"
            XCTFail("Clock-out primary qualification failed"); return
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        result["matchedKeyboardCommandDiagnosticOnly"] = String(describing: IncomePanel.keyboardCommand(for: event))
        result["sentPostClockInShiftTabCount"] = 1
        NSApp.sendEvent(event)
        var firstFocusElapsed: Double? = actualFocus("打卡下班") ? ProcessInfo.processInfo.systemUptime - epoch : nil
        var qualificationHeld = hostQualified()
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            qualificationHeld = qualificationHeld && hostQualified() && store.viewState?.state == .earning &&
                !store.isCommandInFlight && store.confirmation == nil
            if firstFocusElapsed == nil && actualFocus("打卡下班") { firstFocusElapsed = ProcessInfo.processInfo.systemUptime - epoch }
        }
        snapshot("after-single-shift-tab")
        result["qualified"] = qualificationHeld
        result["firstNativePrimaryFocusElapsed"] = firstFocusElapsed.map { $0 as Any } ?? NSNull()
        result["actualPrimaryFocusObserved"] = firstFocusElapsed != nil
        result["finalActualPrimaryFocus"] = actualFocus("打卡下班")
        let retained = await repository.currentToday()
        result["recordUnchanged"] = retained == clockedInRecord
        result["qualified"] = qualificationHeld && retained == clockedInRecord
        XCTAssertEqual(retained, clockedInRecord, "Focus navigation must not mutate the clocked-in record")
        XCTAssertTrue(qualificationHeld, "Host/state loss invalidates diagnostic interpretation")
    }

    func testMountedProductionPanelKeyboardFocusAndSafeActionsThroughConfirmation() async throws {
        // The real Settings command belongs to the application host. Refuse a
        // nonisolated host before opening its window; no main-menu replacement.
        let process = ProcessInfo.processInfo.environment
        guard process["XCTestConfigurationFilePath"] != nil || process["INCOMECLOCK_TEST_ROOT"] != nil else {
            XCTFail("Requires the existing isolated XCTest application-host bootstrap")
            throw NSError(domain: "PanelFocusIsolatedHostRequired", code: 1)
        }
        let initial = ApplicationTestSupport.committedSettings()
        let repository = BusinessRecordRepositorySpy(settings: .loaded(initial, migration: .current), today: .missing)
        let coordinated = PanelSettingsCoordinator(repository: repository, preferenceStore: EphemeralPanelPreferenceStore())
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let store = try BusinessStore(repository: coordinated, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await store.restore()
        let controller = PanelController(businessStore: store, repository: coordinated,
            nowMilliseconds: { clock.nowMilliseconds().rawValue })
        _ = await controller.restore()
        let panel = try XCTUnwrap(controller.windowForTesting)
        let content = try XCTUnwrap(panel.contentView)
        var ownedSettings: NSWindow?
        var trace: [String] = []
        // Observe only this test host's AppKit state; never enumerate other apps
        // or dump launch environment, user window titles, URLs, or AX contents.
        let traceEpoch = ProcessInfo.processInfo.systemUptime
        var notificationCount = 0
#if DEBUG
        controller.focusDeliveryTrace = { entry in
            trace.append("controller t=\(ProcessInfo.processInfo.systemUptime - traceEpoch) " + entry)
        }
#endif
        func windowIdentity(_ window: NSWindow?) -> String {
            guard let window else { return "nil" }
            let owner = window === panel ? "test-panel" : "other-host-window"
            return "\(owner)#\(window.windowNumber):\(type(of: window)),visible=\(window.isVisible),key=\(window.isKeyWindow),main=\(window.isMainWindow)"
        }
        func activationSnapshot(_ cause: String) {
            let elapsed = ProcessInfo.processInfo.systemUptime - traceEpoch
            let hostWindows = NSApp.windows.filter { $0.isVisible || $0 === panel }
            let windowIDs = hostWindows.prefix(8).map { windowIdentity($0) }.joined(separator: ";")
            trace.append("activation t=\(elapsed) cause=\(cause) active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) key=[\(windowIdentity(NSApp.keyWindow))] main=[\(windowIdentity(NSApp.mainWindow))] modal=[\(windowIdentity(NSApp.modalWindow))] windowsCount=\(hostWindows.count) windows=[\(windowIDs)]")
            trace.append("panel-capability canKey=\(panel.canBecomeKey),canMain=\(panel.canBecomeMain),nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)),onlyIfNeeded=\(panel.becomesKeyOnlyIfNeeded),onActiveSpace=\(panel.isOnActiveSpace),occlusion=\(panel.occlusionState.rawValue)")
        }
        let traceCenter = NotificationCenter.default
        let traceNames: [Notification.Name] = [
            NSApplication.willBecomeActiveNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification
        ]
        let traceTokens = traceNames.map { name in
            traceCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    if let window = notification.object as? NSWindow {
                        guard window === panel || NSApp.windows.contains(where: { $0 === window }) else { return }
                    } else {
                        guard (notification.object as AnyObject?) === NSApp else { return }
                    }
                    guard notificationCount < 64 else { return }
                    notificationCount += 1
                    let owner = windowIdentity(notification.object as? NSWindow)
                    activationSnapshot("notification#\(notificationCount):\(notification.name.rawValue):\(owner)")
                }
            }
        }
        activationSnapshot("observer-installed-before-show")
        // A SwiftUI KeyViewProxy can be first responder while its separate
        // public application AX focus object represents the rendered button.
        // Only exact native AX focus identity/role+label+frame can satisfy this
        // observation; semanticFocus and the proxy's type alone cannot pass it.
        func nativeFocusObjects() -> [NSObject] {
            let roots: [NSObject] = [NSApp, panel] + (panel.firstResponder.map { [$0] } ?? [])
            return roots.flatMap { root in
                ["accessibilityFocusedUIElement", "accessibilityApplicationFocusedUIElement"].compactMap {
                    self.axObject(root, $0) as? NSObject
                }
            }
        }
        func axFrame(_ node: NSObject) -> CGRect? {
            guard node.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
            return (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
        }
        func nativeFocusDescription(_ node: NSObject) -> String {
            "type=\(type(of: node)),role=\(self.axObject(node, "accessibilityRole") as? String ?? "nil"),text=\(self.axTexts(node)),frame=\(String(describing: axFrame(node))),focused=\(String(describing: self.boolAttribute(node, "isAccessibilityFocused")))"
        }
        func focusRoutingState() -> String {
            let controls = self.axElements(in: content).filter {
                self.axObject($0, "accessibilityRole") as? String == "AXButton"
            }.map { node in
                let focused = self.axElements(in: node).contains {
                    self.boolAttribute($0, "isAccessibilityFocused") == true
                }
                return "\(self.axTexts(node).joined(separator: "|")):enabled=\(String(describing: self.boolAttribute(node, "isAccessibilityEnabled"))),focused=\(focused)"
            }
#if DEBUG
            let semantic = panel.semanticFocusForTesting?()
#else
            let semantic: Stage5PanelKeyboardFocus? = nil
#endif
            return "semantic=\(String(describing: semantic)),businessState=\(String(describing: store.viewState?.state)),inFlight=\(store.isCommandInFlight),confirmation=\(store.confirmation != nil),visible=\(panel.isVisible),panelKey=\(panel.isKeyWindow),appKeyIsPanel=\(NSApp.keyWindow === panel),appActive=\(NSApp.isActive),buttons=[\(controls.joined(separator: ";"))],nativeAX=[\(nativeFocusObjects().map(nativeFocusDescription).joined(separator: ";"))]"
        }
        var advanceObservationCount = 0
        let advanceTraceToken = NotificationCenter.default.addObserver(
            forName: .incomePanelAdvanceKeyboardFocus, object: panel, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard advanceObservationCount < 64 else { return }
                advanceObservationCount += 1
                let reverse = notification.userInfo?["reverse"] as? Bool
                // This production notification precedes keyboardCommandHandler;
                // the semantic value here is deliberately the pre-handler value.
                trace.append("advance-notification#\(advanceObservationCount) t=\(ProcessInfo.processInfo.systemUptime - traceEpoch) reverse=\(String(describing: reverse)) " + focusRoutingState())
            }
        }
        func snapshot(_ step: String) {
            activationSnapshot(step)
            let controls = self.axElements(in: content).filter {
                self.axObject($0, "accessibilityRole") as? String == "AXButton"
            }.map { node in
                let focused = self.axElements(in: node).contains { self.boolAttribute($0, "isAccessibilityFocused") == true }
                return "\(self.axTexts(node).joined(separator: "|")):enabled=\(String(describing: self.boolAttribute(node, "isAccessibilityEnabled"))),focused=\(focused)"
            }
            trace.append("\(step): visible=\(panel.isVisible),key=\(panel.isKeyWindow),firstResponder=\(String(describing: panel.firstResponder)),buttons=[\(controls.joined(separator: ";"))]")
            trace.append("nativeAXFocus=[" + nativeFocusObjects().map(nativeFocusDescription).joined(separator: ";") + "]")
            if let responder = panel.firstResponder { trace.append("firstResponderAX=" + nativeFocusDescription(responder)) }
        }
        defer {
#if DEBUG
            controller.focusDeliveryTrace = nil
#endif
            NotificationCenter.default.removeObserver(advanceTraceToken)
            traceTokens.forEach(traceCenter.removeObserver)
            trace.append("final-routing " + focusRoutingState())
            snapshot("final-or-failure")
            // Keep recent failure state and cap UTF-8 bytes, not characters.
            let boundedTrace = Data(trace.joined(separator: "\n").utf8.suffix(24_000))
            let attachment = XCTAttachment(data: boundedTrace, uniformTypeIdentifier: "public.utf8-plain-text")
            attachment.name = "Stage9-Mounted-Panel-Native-Keyboard-Focus"
            attachment.lifetime = .keepAlways
            add(attachment)
            ownedSettings?.close()
            controller.hide(persist: false)
        }
        try await Stage9EnableHostedAccessibility()

        // Every event traverses NSApplication -> the production IncomePanel.
        // Do not call the coordinator, mutate FocusState, or press AX controls.
        func key(_ code: UInt16, _ characters: String, shift: Bool = false) throws {
            guard panel.isVisible, panel.isKeyWindow else {
                XCTFail("Keyboard event requires this actual mounted panel to be key")
                throw NSError(domain: "PanelFocusKeyWindowRequired", code: 1)
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            let matched = IncomePanel.keyboardCommand(for: event)
            trace.append("key-before t=\(ProcessInfo.processInfo.systemUptime - traceEpoch) eventTime=\(event.timestamp) code=\(code) modifiers=\(event.modifierFlags.rawValue) matched=\(String(describing: matched)) " + focusRoutingState())
            NSApp.sendEvent(event)
            trace.append("key-after t=\(ProcessInfo.processInfo.systemUptime - traceEpoch) code=\(code) " + focusRoutingState())
        }
        func focusedButton(_ label: String) -> Bool {
            // Resolve the current AX tree on each poll: SwiftUI replaces nodes.
            let matches = self.axElements(in: content).filter {
                self.axObject($0, "accessibilityRole") as? String == "AXButton" && self.axTexts($0).contains(label)
            }
            guard matches.count == 1, let button = matches.first,
                  self.boolAttribute(button, "isAccessibilityEnabled") == true else { return false }
            if self.axElements(in: button).contains(where: { self.boolAttribute($0, "isAccessibilityFocused") == true }) { return true }
            return nativeFocusObjects().contains { focused in
                if focused === button { return true }
                guard self.axObject(focused, "accessibilityRole") as? String == "AXButton",
                      self.axTexts(focused).contains(label), let actual = axFrame(focused),
                      let expected = axFrame(button), actual.width > 0, actual.height > 0 else { return false }
                return abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5 &&
                    abs(actual.width - expected.width) <= 0.5 && abs(actual.height - expected.height) <= 0.5
            }
        }
        func expectFocus(_ label: String, _ step: String) async throws {
            snapshot("before-" + step)
            var previousRoutingState: String?
            var routingChanges = 0
            try await self.eventually {
                let state = focusRoutingState()
                if state != previousRoutingState {
                    previousRoutingState = state
                    if routingChanges < 12 {
                        routingChanges += 1
                        trace.append("wait-change \(step)#\(routingChanges) t=\(ProcessInfo.processInfo.systemUptime - traceEpoch) " + state)
                    }
                }
                return panel.isVisible && panel.isKeyWindow && focusedButton(label)
            }
            _ = try self.controlFrames([label], in: content)
            snapshot(step)
        }
        func showFocused() async throws {
            controller.show(persist: false, focus: true)
            try await expectFocus("打开设置", "focused-show-settings")
        }
        func openClockOutConfirmation() async throws {
            try await showFocused()
            try key(48, "\t", shift: true)
            try await expectFocus("打卡下班", "shift-tab-clock-out")
            try key(36, "\r")
            try await self.eventually { store.confirmation != nil }
            // A native Tab resolves the newly presented confirmation's first
            // focus target; no direct coordinator/requestInitialFocus shortcut.
            try key(48, "\t")
            try await expectFocus("取消", "confirmation-tab-cancel")
        }

        XCTAssertEqual(store.viewState?.state, .ready)
        let settingsNav = "settings-nav-" + Stage5SettingsSection.workRules.rawValue
        let alreadyVisible = NSApp.windows.filter(\.isVisible)
        guard !alreadyVisible.contains(where: { window in
            self.axElements(in: window).contains { self.axObject($0, "accessibilityIdentifier") as? String == settingsNav }
        }) else {
            XCTFail("Existing visible Settings window must not be taken over by this test")
            throw NSError(domain: "PanelFocusSettingsAlreadyVisible", code: 1)
        }
        let visibleIDs = Set(alreadyVisible.map(ObjectIdentifier.init))
        try await showFocused()
        try key(36, "\r")
        try await eventually {
            let matches = NSApp.windows.filter { window in
                window.isVisible && !(window is NSPanel) && !visibleIDs.contains(ObjectIdentifier(window)) &&
                self.axElements(in: window).contains { self.axObject($0, "accessibilityIdentifier") as? String == settingsNav }
            }
            guard matches.count == 1 else { return false }
            ownedSettings = matches[0]
            return true
        }
        XCTAssertTrue(try XCTUnwrap(ownedSettings).isVisible)
        let afterSettings = await repository.currentToday()
        XCTAssertNil(afterSettings, "Opening actual Settings must not clock in")
        ownedSettings?.close()
        ownedSettings = nil
        snapshot("return-opened-production-settings")

        try await showFocused()
        try key(48, "\t")
        try await expectFocus("隐藏收入面板", "tab-hide")
        try key(48, "\t", shift: true)
        try await expectFocus("打开设置", "shift-tab-settings")
        try key(48, "\t")
        try await expectFocus("隐藏收入面板", "tab-hide-again")
        try key(49, " ")
        try await eventually { !panel.isVisible }
        await controller.waitForPendingPersistence()
        let afterHide = await repository.currentToday()
        XCTAssertNil(afterHide, "Hiding actual Panel must not clock in")
        snapshot("space-hid-production-panel")

        try await showFocused()
        try key(48, "\t", shift: true)
        try await expectFocus("打卡上班", "shift-tab-wrap-primary")
        try key(48, "\t")
        try await expectFocus("打开设置", "tab-wrap-settings")
        try key(48, "\t")
        try await expectFocus("隐藏收入面板", "tab-hide-before-primary")
        try key(48, "\t")
        try await expectFocus("打卡上班", "tab-primary")
        try key(36, "\r")
        try await eventually { store.viewState?.state == .earning && !store.isCommandInFlight }
        let clockedInBytes = try await repository.currentTodayCanonicalBytes()
        XCTAssertNotNil(clockedInBytes)
        clock.set(ApplicationTestSupport.timestamp(hour: 13))

        try await openClockOutConfirmation()
        try key(48, "\t")
        try await expectFocus("确认下班", "tab-confirm")
        try key(48, "\t", shift: true)
        try await expectFocus("取消", "shift-tab-cancel")
        try key(36, "\r")
        try await eventually { store.confirmation == nil && !store.isCommandInFlight }
        let afterCancel = try await repository.currentTodayCanonicalBytes()
        XCTAssertEqual(afterCancel, clockedInBytes, "Return on focused Cancel must preserve Today")

        try await openClockOutConfirmation()
        try key(53, "\u{1b}")
        try await eventually { store.confirmation == nil && !store.isCommandInFlight }
        let afterEscape = try await repository.currentTodayCanonicalBytes()
        XCTAssertEqual(afterEscape, clockedInBytes, "Escape must cancel without committing Today")
        snapshot("escape-cancelled-production-confirmation")

        try await openClockOutConfirmation()
        try key(48, "\t")
        try await expectFocus("确认下班", "tab-final-confirm")
        try key(36, "\r")
        try await eventually { store.viewState?.state == .completed && !store.isCommandInFlight }
        let savedToday = await repository.currentToday()
        let settled = try XCTUnwrap(savedToday)
        XCTAssertEqual(settled.clockOutAtMs, clock.nowMilliseconds().rawValue)
        let afterConfirm = try await repository.currentTodayCanonicalBytes()
        XCTAssertNotEqual(afterConfirm, clockedInBytes)
        let finalSettings = await repository.currentSettings()
        XCTAssertEqual(finalSettings?.dailyWageCents, initial.dailyWageCents)
        snapshot("return-confirmed-production-clock-out")
    }

    private func assertMenuControls(_ host: NSView, action: String?) throws {
        let expected = ["显示收入面板"] + (action.map { [$0] } ?? []) +
            ["打开设置…", "始终置顶", "全屏应用时隐藏", "登录时启动", "退出可视收入打卡机"]
        let controls = axElements(in: host).filter {
            ["AXButton", "AXCheckBox", "AXSwitch"].contains(self.axObject($0, "accessibilityRole") as? String ?? "")
        }
        let labels = controls.compactMap { node in self.axTexts(node).first }
        XCTAssertEqual(labels, expected, "Contract menu action/toggle order; no extra theme or recovery actions")
        for label in ["始终置顶", "全屏应用时隐藏", "登录时启动"] {
            let toggle = try element(label: label, in: host)
            XCTAssertTrue(["AXCheckBox", "AXSwitch"].contains(axObject(toggle, "accessibilityRole") as? String ?? ""))
        }
        // System-owned separator/shortcut presentation and actual quitting/login
        // effects are outside this hosted-view check. No toggle or quit is pressed.
    }

    private func renderedText(_ root: NSView) -> String {
        axElements(in: root).flatMap { self.axTexts($0, includeHelp: true) }.joined(separator: "\n")
    }

    private func renderedIdentifiers(_ root: NSView) -> [String] {
        axElements(in: root).compactMap { self.axObject($0, "accessibilityIdentifier") as? String }
    }

    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nativeAmount(in root: NSView) -> PanelAmountNativeView? {
        if let amount = root as? PanelAmountNativeView { return amount }
        return root.subviews.lazy.compactMap { self.nativeAmount(in: $0) }.first
    }

    private func controlFrames(_ labels: [String], in host: NSView) throws -> [String: CGRect] {
        try Dictionary(uniqueKeysWithValues: labels.map { label in
            let object = try element(label: label, in: host)
            let selector = NSSelectorFromString("accessibilityFrame")
            XCTAssertTrue(object.responds(to: selector), label)
            guard object.responds(to: selector) else { throw NSError(domain: "Missing accessibilityFrame", code: 1) }
            // KVC boxes the public NSRect getter correctly on both architectures.
            let value = try XCTUnwrap(object.value(forKey: "accessibilityFrame") as? NSValue)
            let frame = value.rectValue
            XCTAssertGreaterThan(frame.width, 0, label)
            XCTAssertGreaterThan(frame.height, 0, label)
            return (label, frame)
        })
    }

    private func element(label: String, in root: NSView, buttonOnly: Bool = false) throws -> NSObject {
        try XCTUnwrap(findElement(label: label, in: root, buttonOnly: buttonOnly),
            "Missing production AX element: \(label)")
    }

    private func findElement(label: String, in root: NSView, buttonOnly: Bool = false) -> NSObject? {
        axElements(in: root).first {
            self.axTexts($0).contains(label) && (!buttonOnly ||
                self.axObject($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue)
        }
    }

    private func waitForAXControl(label: String, in root: NSView, enabled: Bool, role: String = NSAccessibility.Role.button.rawValue) async throws -> NSObject {
        // The native saving ProgressView exposes AXBusyIndicator; normal
        // actionable controls expose AXButton. Match the observed native role,
        // exact label and disabled/enabled state, never a coincident text node.
        for _ in 0..<300 {
            if let control = axElements(in: root).first(where: {
                self.axTexts($0).contains(label) && self.axObject($0, "accessibilityRole") as? String == role
            }), boolAttribute(control, "isAccessibilityEnabled") == enabled { return control }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = axElements(in: root).map { node in
            let role = self.axObject(node, "accessibilityRole") as? String ?? "nil"
            let text = self.axTexts(node, includeHelp: true).joined(separator: " | ")
            return "role=\(role) enabled=\(String(describing: self.boolAttribute(node, "isAccessibilityEnabled"))) text=\(text)"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: snapshot)
        attachment.name = "Stage9-Button-AX-Timeout-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Timed out waiting for production AX control \(label), role=\(role), enabled=\(enabled)")
        throw NSError(domain: "PanelCloseoutButtonAXTimeout", code: 1)
    }

    private func press(_ object: NSObject) -> Bool {
        boolAttribute(object, "accessibilityPerformPress") ?? false
    }

    // SwiftUI AccessibilityNode instances implement public ObjC AX getters but
    // need not declare NSAccessibilityProtocol conformance. Dispatch by selector.
    private func axObject(_ object: NSObject, _ attribute: String) -> Any? {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func axElements(in root: NSObject) -> [NSObject] {
        var pending = [root]
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        while let next = pending.popLast(), result.count < 1_024 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = axObject(next, "accessibilityChildren") as? [NSObject]
                ?? (next as? NSView)?.subviews ?? []
            pending.append(contentsOf: children.reversed())
        }
        return result
    }

    private func axTexts(_ object: NSObject, includeHelp: Bool = false) -> [String] {
        let attributes = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
            + (includeHelp ? ["accessibilityHelp"] : [])
        return attributes.compactMap { self.axObject(object, $0) as? String }
    }

    private func boolAttribute(_ object: NSObject, _ attribute: String) -> Bool? {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let invoke = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return invoke(object, selector)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for a mounted production state")
        throw NSError(domain: "PanelCloseoutIntegrationTests", code: 1)
    }
}

@MainActor
private final class CloseoutMenuActionReceiver: NSObject {
    var openCount = 0
    var lastSender: NSMenuItem?
    @objc func openSettings(_ sender: NSMenuItem) {
        openCount += 1
        lastSender = sender
    }
}

@MainActor
private final class FocusableComparisonProbe: ObservableObject {
    @Published var request = 0
    var appliedFocus = false
    var actionCount = 0
}

@MainActor
private struct FocusableComparisonView: View {
    @ObservedObject var probe: FocusableComparisonProbe
    let explicitFocusable: Bool
    @FocusState private var focused: Bool

    private var button: some View {
        Button("Probe action") { probe.actionCount += 1 }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("focus-wrapper-probe")
    }

    var body: some View {
        Group {
            if explicitFocusable { button.focusable().focused($focused) }
            else { button.focused($focused) }
        }
        .frame(width: 320, height: 190)
        .onReceive(probe.$request) { value in
            if value > 0 { focused = true }
        }
        .onChange(of: focused) { probe.appliedFocus = $0 }
    }
}

private enum DisabledPulsePrecondition: Error { case failed(String) }
private enum DisabledPulseTarget: String, Hashable { case settings, hide, primary }

@MainActor
private final class DisabledPulseProbe: ObservableObject {
    @Published var request: DisabledPulseTarget?
    @Published var primaryDisabled = false
    let epoch = ProcessInfo.processInfo.systemUptime
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - epoch }
    var localFocus = "nil"
    var lastChangedFocus: DisabledPulseTarget?
    var actionCount = 0
    var events: [[String: Any]] = []
    var droppedEvents = 0
    func record(_ kind: String, before: DisabledPulseTarget?, after: DisabledPulseTarget?) {
        localFocus = after?.rawValue ?? "nil"
        guard events.count < 16 else { droppedEvents += 1; return }
        events.append(["kind": kind, "elapsed": elapsed, "requested": request?.rawValue ?? "nil",
                       "before": before?.rawValue ?? "nil", "after": localFocus])
    }
}

@MainActor
private final class DisabledPulseCounter: ObservableObject {
    @Published var ticks = 0
    var tickTimes: [Double] = []
}

@MainActor
private struct DisabledPulseView: View {
    @ObservedObject var probe: DisabledPulseProbe
    @ObservedObject var pulse: DisabledPulseCounter
    @FocusState private var focused: DisabledPulseTarget?
    var body: some View {
        VStack {
            Text("Pulse \(pulse.ticks)")
            Button("Settings") { probe.actionCount += 1 }.buttonStyle(.bordered).focused($focused, equals: .settings)
            Button("Hide") { probe.actionCount += 1 }.buttonStyle(.bordered).focused($focused, equals: .hide)
            Button("Primary") { probe.actionCount += 1 }.buttonStyle(.bordered)
                .disabled(probe.primaryDisabled).focused($focused, equals: .primary)
        }
        .frame(width: 320, height: 190)
        .onReceive(probe.$request) { request in
            guard let request else { return }
            let before = focused
            focused = request
            probe.record("publisher-receive", before: before, after: focused)
        }
        .onChange(of: focused) { value in
            probe.record("local-onChange", before: probe.lastChangedFocus, after: value)
            probe.lastChangedFocus = value
        }
    }
}
