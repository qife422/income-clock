import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var businessStore: BusinessStore
    @ObservedObject private var loginItemController: LoginItemController

    init(environment: AppEnvironment) {
        self.environment = environment
        businessStore = environment.businessStore
        loginItemController = environment.loginItemController
    }

    var body: some View {
        summary

        Divider()

        Button(environment.isPanelVisible ? "隐藏收入面板" : "显示收入面板") {
            environment.togglePanelFromMenuBar()
        }
        .disabled(businessStore.isRestoring)
        .keyboardShortcut("i", modifiers: [.option, .command])

        if let item = businessAction {
            Button(item.title) { perform(item.action) }
                .disabled(item.disabled || businessStore.isCommandInFlight)
                .help(businessStore.isCommandInFlight ? "正在处理，请稍候" : item.help)
        }

        Button("打开设置…") {
            NativeSettingsWindowRouter.open()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Toggle("始终置顶", isOn: Binding(
            get: { environment.panelPreferences.alwaysOnTop },
            set: environment.setAlwaysOnTop
        ))
        Toggle("全屏应用时隐藏", isOn: Binding(
            get: { environment.panelPreferences.hideInFullScreen },
            set: environment.setHideInFullScreen
        ))
        Toggle("登录时启动", isOn: Binding(
            get: { loginItemController.isEnabled },
            set: { value in Task { await loginItemController.setEnabled(value) } }
        ))
        .disabled(loginItemController.isProcessing)
        if loginItemController.isProcessing {
            Text("正在同步登录项…").foregroundStyle(.secondary)
        } else if loginItemController.error != nil {
            Text("登录项未更新，请在设置中查看原因。").foregroundStyle(.red)
        }

        Divider()

        Button("退出可视收入打卡机") {
            environment.terminateApplication()
        }
        .keyboardShortcut("q")
    }

    private var summary: some View {
        ForEach(Array(summaryTitles.enumerated()), id: \.offset) { row in
            summaryText(row.element)
        }
    }

    private var summaryTitles: [String] {
        if businessStore.isRestoring {
            return ["正在恢复今日记录…", "本地读取完成后即可使用"]
        } else if businessStore.viewState?.state == .recoveryRequired,
                  businessStore.settingsReadErrorViewState != nil {
            return ["今日记录需要恢复", "设置数据也无法读取"]
        } else if businessStore.hasBlockingScheduleError {
            return ["今日工作时间无法确定", "请在设置中调整上下班时间"]
        } else if businessStore.settingsReadErrorViewState?.isBlocking == true {
            return ["设置数据无法读取", "请打开设置重新填写"]
        } else if let state = businessStore.viewState {
            let presentation = Stage5PanelPresentation.make(from: state)
            var titles = [presentation.status, menuDetail(presentation, state: state)]
            if businessStore.settingsReadErrorViewState != nil { titles.append("设置需要修复") }
            return titles
        } else {
            return ["无法恢复当前状态", "请打开设置检查本地数据"]
        }
    }

    var nativeMenuFingerprint: NativeMenuSummaryContrast.Fingerprint {
        .init(summary: summaryTitles,
              panelTitle: environment.isPanelVisible ? "隐藏收入面板" : "显示收入面板",
              businessTitle: businessAction?.title,
              loginStatusTitle: loginItemController.isProcessing ? "正在同步登录项…" :
                (loginItemController.error != nil ? "登录项未更新，请在设置中查看原因。" : nil))
    }

    // Keep the native noninteractive menu row; only its attributed foreground is app-owned.
    private func summaryText(_ value: String) -> Text {
        var title = AttributedString(value)
        title.foregroundColor = Color(nsColor: .labelColor)
        return Text(title)
    }

    private func menuDetail(_ presentation: Stage5PanelPresentation,
                            state: BusinessViewState) -> String {
        if state.state == .recoveryRequired { return "无法安全显示今日收入" }
        let amount = presentation.amount ?? ""
        switch state.state {
        case .unconfigured: return "请先设置工资与工作时间"
        case .ready: return "今日已获得 \(amount)"
        case .completed: return "最终收入 \(amount)"
        case .awaitingClockOut:
            return state.isPreviousWorkday ? "计薪已停止 · 请打卡下班" : "今日已获得 \(amount) · 请打卡下班"
        default: return "今日已获得 \(amount) · \(presentation.supportText)"
        }
    }

    private var businessAction: (title: String, action: Stage5PanelPresentation.Action, disabled: Bool, help: String)? {
        guard !businessStore.isRestoring,
              !businessStore.hasBlockingScheduleError,
              businessStore.settingsReadErrorViewState?.isBlocking != true,
              let state = businessStore.viewState else { return nil }
        if state.state == .completed, state.isPreviousWorkday {
            let disabled = !state.canRequestStartToday
            return ("开始今天…", .startToday, disabled, disabled ? "请先修复设置，再开始今天" : "")
        }
        let presentation = Stage5PanelPresentation.make(from: state)
        guard let title = presentation.actionTitle else { return nil }
        switch presentation.action {
        case .clockIn:
            let disabled = isDisabled(presentation.action)
            return ("打卡上班", presentation.action, disabled, disabled ? presentation.supportText : "")
        case .clockOut:
            let disabled = isDisabled(presentation.action)
            return (title, presentation.action, disabled, disabled ? presentation.supportText : "")
        case .openSettings, .startToday, .resetToday, .none:
            return nil
        }
    }

    private func perform(_ action: Stage5PanelPresentation.Action) {
        switch action {
        case .openSettings:
            NativeSettingsWindowRouter.open()
        case .clockIn:
            Task { _ = await businessStore.send(.clockIn, source: .menuBar) }
        case .clockOut:
            Task { _ = await businessStore.send(.requestClockOut, source: .menuBar) }
        case .startToday:
            Task { _ = await businessStore.send(.requestStartToday, source: .menuBar) }
        case .resetToday:
            Task { _ = await businessStore.send(.requestTodayReset, source: .menuBar) }
        case .none: break
        }
    }

    private func isDisabled(_ action: Stage5PanelPresentation.Action) -> Bool {
        if case let .clockIn(enabled) = action { return !enabled }
        return false
    }
}

/// Owns only presentation of this app's exact informational summary prefix.
/// Native commands, enabled states, targets and actions remain owned by SwiftUI.
@MainActor
final class NativeMenuSummaryContrast {
    struct Fingerprint {
        let summary: [String]
        let panelTitle: String
        let businessTitle: String?
        let loginStatusTitle: String?
    }

    private let center: NotificationCenter
    private let fingerprint: @MainActor () -> Fingerprint?
    private var token: NSObjectProtocol?
    private var changeToken: NSObjectProtocol?
    private var isApplying = false

    init(center: NotificationCenter = .default,
         fingerprint: @escaping @MainActor () -> Fingerprint?) {
        self.center = center
        self.fingerprint = fingerprint
    }

    func start() {
        Self.recordDiagnosticStage("observer-start")
        guard token == nil else {
            Self.recordDiagnosticStage("observer-already-registered")
            return
        }
        token = center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                   object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.receive(notification, changesExistingRowsOnly: false)
            }
        }
        changeToken = center.addObserver(forName: NSMenu.didChangeItemNotification,
                                         object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.receive(notification, changesExistingRowsOnly: true)
            }
        }
        Self.recordDiagnosticStage("observer-registered")
    }

    private func receive(_ notification: Notification, changesExistingRowsOnly: Bool) {
        guard !isApplying, let menu = notification.object as? NSMenu else { return }
        if changesExistingRowsOnly {
            guard menu.items.prefix(2).contains(where: { $0.view is NativeMenuInformationRow }) else { return }
        }
        let informationalRows = true
        if changesExistingRowsOnly && !informationalRows { return }
        guard let expected = fingerprint() else { return }
        isApplying = true
        defer { isApplying = false }
        Self.recordDiagnosticStage("notification-ready-for-apply")
        Self.apply(to: menu, matching: expected, informationalRows: informationalRows,
                   isolatedAppearance: Self.requestedIsolatedAppearance)
    }

    private static var requestedIsolatedAppearance: NSAppearance? {
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
        guard prototypeRequested,
              let requested = ProcessInfo.processInfo.environment["INCOMECLOCK_NATIVE_MENU_SUMMARY_APPEARANCE"],
              ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"].contains(requested) else { return nil }
        return NSAppearance(named: NSAppearance.Name(rawValue: requested))
#else
        return nil
#endif
    }

    // Appearance fixtures are opt-in in the receipt-verified isolated Debug
    // build. Normal launches and Release use the system menu appearance.
    private static var prototypeRequested: Bool {
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
        let env = ProcessInfo.processInfo.environment
        guard env["INCOMECLOCK_NATIVE_MENU_SUMMARY_ROWS"] == "1",
              let value = env["INCOMECLOCK_TEST_ROOT"],
              let nonce = env["INCOMECLOCK_UI_ISOLATION_NONCE"] else { return false }
        let root = URL(fileURLWithPath: value, isDirectory: true).resolvingSymlinksInPath()
        let parent = URL(fileURLWithPath: "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true)
            .resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == parent,
              let data = try? Data(contentsOf: root.appendingPathComponent("ui-isolation-receipt.json")),
              data.count <= 16_384,
              let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              receipt["nonce"] as? String == nonce,
              receipt["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) else { return false }
        return true
#else
        return false
#endif
    }

    func stop() {
        if let token { center.removeObserver(token) }
        if let changeToken { center.removeObserver(changeToken) }
        token = nil
        changeToken = nil
    }

    deinit {
        if let token { center.removeObserver(token) }
        if let changeToken { center.removeObserver(changeToken) }
    }

    private static func summaryTitleMatches(_ actual: String, expected: String,
                                            index: Int, summary: [String]) -> Bool {
        if actual == expected { return true }
        // SwiftUI can render a newer live amount/countdown than the freshly
        // sampled fingerprint before the menu begins tracking. This exception
        // is confined to the earning detail; every other title stays exact.
        guard index == 1, summary[0] == "计薪中" else { return false }
        let liveDetail = #"\A今日已获得 ¥(?:0|[1-9][0-9]{0,2})(?:,[0-9]{3})*\.[0-9]{3} · 距离下班 (?:[0-9]{2}|[1-9][0-9]{2,}):[0-5][0-9]:[0-5][0-9]\z"#
        return expected.range(of: liveDetail, options: .regularExpression) != nil &&
               actual.range(of: liveDetail, options: .regularExpression) != nil
    }

    @discardableResult
    static func apply(to menu: NSMenu, matching expected: Fingerprint,
                      informationalRows: Bool = false,
                      isolatedAppearance: NSAppearance? = nil) -> Int {
        var diagnosticStage = "root-guard"
        var changed = 0
        defer { recordIsolatedDiagnostic(menu, summaryCount: expected.summary.count,
            stage: diagnosticStage, changed: changed) }
        guard menu.supermenu == nil, menu !== NSApp.mainMenu,
              (2...3).contains(expected.summary.count) else { return 0 }
        // The only supported third informational row is the conditional
        // nonblocking Settings warning. Reject any other three-row fingerprint
        // before touching this menu.
        guard !informationalRows || expected.summary.count == 2 ||
              expected.summary[2] == "设置需要修复" else { return 0 }
        let informationalCount = informationalRows ? expected.summary.count : 0
        // nil denotes a separator. Match the whole menu before changing any item.
        var titles: [String?] = expected.summary.map { Optional($0) }
        titles += [nil, expected.panelTitle]
        if let business = expected.businessTitle { titles.append(business) }
        titles += ["打开设置…", nil, "始终置顶", "全屏应用时隐藏", "登录时启动"]
        if let status = expected.loginStatusTitle { titles.append(status) }
        titles += [nil, "退出可视收入打卡机"]
        diagnosticStage = "count-guard"
        guard menu.items.count == titles.count else { return 0 }
        for (index, title) in titles.enumerated() {
            diagnosticStage = "item-structure-\(index)"
            let item = menu.items[index]
            guard !item.isHidden, item.submenu == nil else { return 0 }
            if let view = item.view {
                guard index < informationalCount, view is NativeMenuInformationRow else { return 0 }
            }
            guard let title else {
                guard item.isSeparatorItem else { return 0 }
                continue
            }
            diagnosticStage = "title-match-\(index)"
            guard !item.isSeparatorItem,
                  (item.title == title || (informationalRows &&
                    summaryTitleMatches(item.title, expected: title, index: index,
                                        summary: expected.summary))) else { return 0 }
            let key: String
            let modifiers: NSEvent.ModifierFlags
            if index == expected.summary.count + 1 {
                key = "i"; modifiers = [.option, .command]
            } else if title == "打开设置…" {
                key = ","; modifiers = .command
            } else if index == titles.count - 1 {
                key = "q"; modifiers = .command
            } else {
                key = ""; modifiers = []
            }
            diagnosticStage = "shortcut-match-\(index)"
            guard item.keyEquivalent == key,
                  key.isEmpty || item.keyEquivalentModifierMask == modifiers else { return 0 }
            if index < expected.summary.count {
                diagnosticStage = "summary-semantics-\(index)"
                guard !item.isEnabled, item.image == nil, item.state == .off,
                      item.attributedTitle == nil || item.attributedTitle?.string == item.title else { return 0 }
                if index < informationalCount {
                    guard item.action == nil else { return 0 }
                }
            }
        }
        if informationalRows {
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
            // A rejected menu must remain unchanged, including its appearance.
            if let isolatedAppearance { menu.appearance = isolatedAppearance }
#endif
            // The entire menu fingerprint has matched before any view changes.
            // Render only the matched informational prefix. A third item is
            // admitted solely when it is the exact nonblocking warning above.
            for item in menu.items.prefix(informationalCount) {
                if let row = item.view as? NativeMenuInformationRow {
                    if row.update(title: item.title, font: menu.font) { changed += 1 }
                } else {
                    item.view = NativeMenuInformationRow(title: item.title, font: menu.font)
                    changed += 1
                }
            }
            diagnosticStage = "matched-informational-rows"
            return changed
        }
        // Resolve the semantic color while this menu's actual appearance is
        // current, then detach its components from the disabled-item context.
        // Keep alpha and every native item's state/action unchanged.
        var resolvedForeground: NSColor?
        menu.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor.labelColor.usingColorSpace(.sRGB) else { return }
            resolvedForeground = NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                                         blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
        guard let resolvedForeground else {
            diagnosticStage = "matched-color-resolution-unavailable"
            return changed
        }
        let changesBeforeColor = changed
        diagnosticStage = "matched-already-label-color"
        for item in menu.items.prefix(expected.summary.count) {
            let title = item.attributedTitle.map { NSMutableAttributedString(attributedString: $0) }
                ?? NSMutableAttributedString(string: item.title)
            let range = NSRange(location: 0, length: title.length)
            var needsColor = false
            title.enumerateAttribute(.foregroundColor, in: range) { value, _, _ in
                if (value as? NSColor) != resolvedForeground { needsColor = true }
            }
            guard needsColor else { continue }
            title.addAttribute(.foregroundColor, value: resolvedForeground, range: range)
            item.attributedTitle = title
            changed += 1
        }
        if changed > changesBeforeColor {
            diagnosticStage = "matched-color-written"
        }
        return changed
    }

#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
    private static var diagnosticStageCount = 0
#endif

    // Static stage codes only; bounded stderr remains observable even when a
    // rejected root/receipt correctly prevents any diagnostic file write.
    private static func recordDiagnosticStage(_ stage: String) {
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
        guard ProcessInfo.processInfo.environment["INCOMECLOCK_NATIVE_MENU_DIAGNOSTIC"] == "1",
              diagnosticStageCount < 64 else { return }
        diagnosticStageCount += 1
        FileHandle.standardError.write(Data("native-menu-diagnostic: \(stage)\n".utf8))
#endif
    }

    private static func recordIsolatedDiagnostic(_ menu: NSMenu, summaryCount: Int,
                                                 stage: String, changed: Int) {
#if DEBUG && STAGE9_ISOLATED_TEST_BUILD
        recordDiagnosticStage("apply-" + stage)
        let env = ProcessInfo.processInfo.environment
        guard env["INCOMECLOCK_NATIVE_MENU_DIAGNOSTIC"] == "1" else { return }
        guard let value = env["INCOMECLOCK_TEST_ROOT"],
              let nonce = env["INCOMECLOCK_UI_ISOLATION_NONCE"] else {
            recordDiagnosticStage("diagnostic-environment-incomplete")
            return
        }
        let root = URL(fileURLWithPath: value, isDirectory: true).resolvingSymlinksInPath()
        let parent = URL(fileURLWithPath: "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData", isDirectory: true)
            .resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == parent else {
            recordDiagnosticStage("diagnostic-parent-rejected")
            return
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("ui-isolation-receipt.json")),
              let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              receipt["nonce"] as? String == nonce,
              receipt["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) else {
            recordDiagnosticStage("diagnostic-receipt-rejected")
            return
        }
        recordDiagnosticStage("diagnostic-root-and-receipt-accepted")
        let target = root.appendingPathComponent("native-menu-contrast-diagnostic.json")
        var entries: [[String: Any]] = []
        if let bytes = try? Data(contentsOf: target), bytes.count < 16_384,
           let stored = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]] { entries = stored }
        guard entries.count < 16 else {
            recordDiagnosticStage("diagnostic-entry-limit")
            return
        }
        entries.append(["stage": stage, "changedCount": changed, "itemCount": menu.items.count,
            "summaryCount": summaryCount, "hasSupermenu": menu.supermenu != nil,
            "isMainMenu": menu === NSApp.mainMenu,
            "summaryEnabled": menu.items.prefix(summaryCount).map(\.isEnabled),
            "summaryHasAttributedTitle": menu.items.prefix(summaryCount).map { $0.attributedTitle != nil },
            "summaryHasAction": menu.items.prefix(summaryCount).map { $0.action != nil },
            "summaryHasInformationRow": menu.items.prefix(summaryCount).map { $0.view is NativeMenuInformationRow },
            "effectiveAppearance": menu.effectiveAppearance.name.rawValue,
            "bestMatchingAppearance": menu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"])
        if let bytes = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) {
            do {
                try bytes.write(to: target, options: .atomic)
                recordDiagnosticStage("diagnostic-file-written")
            } catch {
                recordDiagnosticStage("diagnostic-file-write-failed")
            }
        }
#endif
    }
}

/// Public AppKit label inside an informational NSMenuItem. The disabled menu
/// item retains its title for native type selection, but never gains an action.
/// No custom painting, event synthesis, accessibility announcements or timers.
@MainActor
final class NativeMenuInformationRow: NSView {
    private(set) var textField: NSTextField
    private static let horizontalInset: CGFloat = 16
    private static let verticalInset: CGFloat = 4

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(title: String, font: NSFont) {
        textField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        configure()
        _ = update(title: title, font: font, force: true)
    }

    required init?(coder: NSCoder) {
        textField = NSTextField(labelWithString: coder.decodeObject(forKey: "summaryText") as? String ?? "")
        super.init(coder: coder)
        // NSMenuItem copies custom views by archiving. Recreate our one label
        // rather than retaining both the decoded subview and a new label.
        subviews.forEach { $0.removeFromSuperview() }
        configure()
        let font = coder.decodeObject(forKey: "summaryFont") as? NSFont ?? NSFont.menuFont(ofSize: 0)
        _ = update(title: textField.stringValue, font: font, force: true)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(textField.stringValue, forKey: "summaryText")
        coder.encode(textField.font, forKey: "summaryFont")
    }

    private func configure() {
        autoresizingMask = [.width]
        setAccessibilityElement(false)
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.textColor = .labelColor
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.setAccessibilityElement(true)
        textField.setAccessibilityRole(.staticText)
        addSubview(textField)
    }

    @discardableResult
    func update(title: String, font: NSFont, force: Bool = false) -> Bool {
        guard force || textField.stringValue != title || textField.font != font else { return false }
        textField.stringValue = title
        textField.font = font
        textField.setAccessibilityValue(title)
        let measured = (title as NSString).size(withAttributes: [.font: font])
        let height = ceil(font.ascender - font.descender + font.leading)
        setFrameSize(NSSize(width: ceil(measured.width) + Self.horizontalInset * 2,
                            height: height + Self.verticalInset * 2))
        needsLayout = true
        return true
    }

    override func layout() {
        super.layout()
        let height = ceil(textField.font.map { $0.ascender - $0.descender + $0.leading } ?? 0)
        textField.frame = NSRect(x: Self.horizontalInset, y: (bounds.height - height) / 2,
                                 width: max(0, bounds.width - Self.horizontalInset * 2), height: height)
    }
}
