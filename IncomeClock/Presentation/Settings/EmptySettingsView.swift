import AppKit
import SwiftUI
import UniformTypeIdentifiers


// The existing rendering-only input also applies to these named Settings core
// labels. At 1.0, leave native buttons untouched and retain semantic .headline.
// No preference, persisted field, global font, control action or role is added.
@MainActor
enum SettingsCoreTextMetrics {
    enum Role { case errorHeadline, nativePrimary }

    static func baseline(_ role: Role) -> NSFont {
        switch role {
        case .errorHeadline:
            return NSFont.preferredFont(forTextStyle: .headline, options: [:])
        case .nativePrimary:
            let probe = NSButton(title: "", target: nil, action: nil)
            probe.setButtonType(.momentaryPushIn)
            probe.bezelStyle = .rounded
            probe.controlSize = .regular
            // Read the native regular push-button default; no guessed point size.
            return probe.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        }
    }

    static func font(_ role: Role, scale: CGFloat) -> NSFont {
        let original = baseline(role)
        return NSFontManager.shared.convert(original, toSize: original.pointSize * min(1.2, max(1, scale)))
    }
}

private struct SettingsCoreTextScale: ViewModifier {
    let role: SettingsCoreTextMetrics.Role
    var enabled = true
    @Environment(\.incomePanelTextScale) private var scale

    @ViewBuilder func body(content: Content) -> some View {
        if enabled && scale > 1 {
            content.font(Font(SettingsCoreTextMetrics.font(role, scale: scale)))
        } else if case .errorHeadline = role {
            content.font(.headline)
        } else {
            content
        }
    }
}


// Native borderedProminent can ignore a requested label font. Transform its
// complete rendered control instead, and reserve the resulting width/height.
// This preserves native label, bezel, tint, focus, hit testing and Button actions.
private struct SettingsPrimaryTextScale: ViewModifier {
    @Environment(\.incomePanelTextScale) private var requestedScale

    @ViewBuilder func body(content: Content) -> some View {
        let scale = min(1.2, max(1, requestedScale))
        if scale > 1 {
            SettingsScaledPrimaryLayout(scale: scale) {
                content.buttonStyle(.borderedProminent).scaleEffect(scale)
            }
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

// Public Layout APIs are available from macOS 13. The child keeps its native
// intrinsic size; only its rendered transform and its allocated footprint grow.
private struct SettingsScaledPrimaryLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let native = child.sizeThatFits(.unspecified)
        return CGSize(width: native.width * scale, height: native.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let native = child.sizeThatFits(.unspecified)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(native))
    }
}

enum Stage5SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case workRules = "工作规则"
    case panel = "面板与启动"
    case appearance = "外观与皮肤"
    case data = "数据与隐私"
    case shortcuts = "快捷键"
    case about = "关于"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .workRules: return "clock.badge.checkmark"
        case .panel: return "macwindow"
        case .appearance: return "paintbrush"
        case .data: return "internaldrive"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

enum WorkRuleDraftError: Error, Equatable {
    case wage
    case startTime
    case endTime
    case scheduleOrder
}

enum WorkRuleDraftParser {
    static func parse(wage: String, start: String, end: String) throws -> WorkRuleSettingsInput {
        let wageCents = try parseWage(wage)
        let startMinute = try parseTime(start, error: .startTime)
        let endMinute = try parseTime(end, error: .endTime)
        guard startMinute < endMinute else { throw WorkRuleDraftError.scheduleOrder }
        return .init(dailyWageCents: wageCents,
            workStartMinuteOfDay: startMinute, workEndMinuteOfDay: endMinute)
    }

    static func wageString(_ cents: Int64) -> String {
        String(format: "%lld.%02lld", cents / 100, cents % 100)
    }

    static func timeString(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func parseWage(_ source: String) throws -> Int64 {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !text.isEmpty, pieces.count <= 2,
              pieces[0].allSatisfy(\.isNumber), !pieces[0].isEmpty,
              let whole = Int64(pieces[0]), whole >= 0 else { throw WorkRuleDraftError.wage }
        let fractionText = pieces.count == 2 ? String(pieces[1]) : ""
        guard fractionText.count <= 2, fractionText.allSatisfy(\.isNumber) else { throw WorkRuleDraftError.wage }
        let padded = fractionText.padding(toLength: 2, withPad: "0", startingAt: 0)
        guard let fraction = Int64(padded),
              whole <= DailyWageCents.maximum / 100,
              let total = try? CheckedInteger.add(try CheckedInteger.multiply(whole, 100), fraction),
              DailyWageCents.minimum...DailyWageCents.maximum ~= total else {
            throw WorkRuleDraftError.wage
        }
        return total
    }

    private static func parseTime(_ source: String, error: WorkRuleDraftError) throws -> Int {
        let pieces = source.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { throw error }
        return hour * 60 + minute
    }
}

/// Presentation-only feedback. Its lifetime and announcement cannot change a
/// committed business result, and replaying the same receipt cannot announce twice.
@MainActor
final class SettingsSuccessToastController: ObservableObject {
    static let displayDurationNanoseconds: UInt64 = 2_000_000_000
    @Published private(set) var text: String?
    private var activeID: String?
    private var presentedIDs: [String] = []
    private var expiry: Task<Void, Never>?
    private let announce: @MainActor (String) -> Void
    private let sleep: @MainActor (UInt64) async throws -> Void

    init(announce: @escaping @MainActor (String) -> Void = { message in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }, sleep: @escaping @MainActor (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }) {
        self.announce = announce
        self.sleep = sleep
    }

    func present(_ message: String, id: String) {
        guard !presentedIDs.contains(id) else { return }
        presentedIDs.append(id)
        if presentedIDs.count > 64 { presentedIDs.removeFirst(presentedIDs.count - 64) }
        expiry?.cancel()
        activeID = id
        text = message
        announce(message)
        expiry = Task { @MainActor [weak self, sleep] in
            do { try await sleep(Self.displayDurationNanoseconds) }
            catch { return }
            guard !Task.isCancelled, self?.activeID == id else { return }
            self?.text = nil
            self?.activeID = nil
        }
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        activeID = nil
        text = nil
    }

    deinit { expiry?.cancel() }
}

struct SettingsThemeGroups {
    let builtIn: [ValidatedTheme]
    let installed: [ValidatedTheme]
    var showsInstalledEmptyState: Bool { installed.isEmpty }
    static let installedEmptyTitle = "还没有导入皮肤"

    init(themes: [ValidatedTheme]) {
        builtIn = themes.filter(\.isBuiltIn)
        installed = themes.filter { !$0.isBuiltIn }
    }
}

private struct SettingsSuccessToast: View {
    @ObservedObject var controller: SettingsSuccessToastController
    var body: some View {
        if let text = controller.text {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("settings-success-toast")
                .allowsHitTesting(false)
        }
    }
}

/// Attached only by IncomeSettingsView. SwiftUI owns the window and its size
/// constraints; this bridge restores the native user-resizable style bit.
struct SettingsWindowResizeBridge: NSViewRepresentable {
    // Changing pages installs a different set of native controls.
    var section: Stage5SettingsSection? = nil
    func makeNSView(context: Context) -> SettingsWindowResizeView {
        let view = SettingsWindowResizeView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SettingsWindowResizeView, context: Context) {
        nsView.requestOwnedWindowResizability()
    }
}

final class SettingsWindowResizeView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestOwnedWindowResizability()
    }

    func requestOwnedWindowResizability() {
        guard let ownedWindow = window else { return }
        // Defer until the attachment transaction finishes. Never act on an old
        // window if SwiftUI detached or reparented this exact bridge meanwhile.
        DispatchQueue.main.async { [weak self, weak ownedWindow] in
            guard let self, let ownedWindow,
                  self.window === ownedWindow,
                  !(ownedWindow is NSPanel),
                  ownedWindow.styleMask.contains(.titled),
                  ownedWindow.styleMask.contains(.closable) else { return }
            if !ownedWindow.styleMask.contains(.resizable) {
                ownedWindow.styleMask.insert(.resizable)
            }
            ownedWindow.autorecalculatesKeyViewLoop = true
            ownedWindow.recalculateKeyViewLoop()
        }
    }
}

private struct SettingsFocusedControlPreferenceKey: PreferenceKey {
    static var defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

struct IncomeSettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: Stage5SettingsSection? = .workRules
    @FocusState private var focusedSection: Stage5SettingsSection?

    private var businessStore: BusinessStore { environment.businessStore }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Stage5SettingsSection.allCases) { section in
                    Button { selection = section } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedSection, equals: section)
                    .keyboardShortcut(focusedSection == section ? KeyboardShortcut(.space, modifiers: []) : nil)
                    .accessibilityIdentifier("settings-nav-" + section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(minWidth: 168, idealWidth: 176, maxWidth: 196)

            ScrollViewReader { reader in
                ScrollView {
                    settingsPage(selection ?? .workRules)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings-page-" + (selection ?? .workRules).rawValue)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
                .onPreferenceChange(SettingsFocusedControlPreferenceKey.self) { target in
                    // Native keyboard focus can reach a detail action below the
                    // viewport. Reveal that same action without moving focus.
                    if let target { reader.scrollTo(target, anchor: .center) }
                }
            }
            .frame(minWidth: 484)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 540)
        .background(SettingsWindowResizeBridge(section: selection)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true))
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(Color.primary)
        .preferredColorScheme(environment.themeStore.preferredAppearance.colorScheme)
    }

    @ViewBuilder private func settingsPage(_ section: Stage5SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(businessStore: businessStore, themeStore: environment.themeStore)
        case .workRules:
            WorkRulesSettingsView(businessStore: businessStore)
        case .panel:
            PanelBehaviorSettingsView(environment: environment)
        case .appearance:
            ThemeAppearanceSettingsView(themeStore: environment.themeStore)
        case .data:
            DataSettingsView(businessStore: businessStore)
        case .shortcuts:
            PlaceholderSettingsPage(title: "快捷键", subtitle: "面板快捷键使用 macOS 原生菜单命令。",
                rows: [("显示 / 隐藏面板", "⌥⌘I"), ("打开设置", "⌘,"), ("退出应用", "⌘Q")])
        case .about:
            PlaceholderSettingsPage(title: "关于", subtitle: "一款本地优先、专注每一天的可视收入打卡工具。",
                rows: [("可视收入打卡机", "Product 0.8"), ("最低系统", "macOS 13"), ("数据策略", "本地优先")])
        }
    }
}

struct ThemeAppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeStore
    @StateObject private var successToast: SettingsSuccessToastController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showingImporter = false
    @State private var isDropTargeted = false
    @State private var deleteTarget: ValidatedTheme?
    @State private var previewThemeID: String?
    @FocusState private var focusedThemeID: String?
    @FocusState private var useThemeFocused: Bool
    @FocusState private var resetThemeFocused: Bool

    init(themeStore: ThemeStore, successToast: SettingsSuccessToastController? = nil) {
        self.themeStore = themeStore
        _successToast = StateObject(wrappedValue: successToast ?? SettingsSuccessToastController())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                SettingsHeader(
                    title: "外观与皮肤",
                    subtitle: "浏览内置与已验证皮肤；导入不会改变工资、时间或打卡状态。"
                )
                Spacer()
                Button("导入皮肤…") { showingImporter = true }
                    .accessibilityIdentifier("theme-import-open")
                    .disabled(themeStore.importProgress != nil)
                    .settingsDisabledReason(themeStore.importProgress != nil ? "正在处理一个皮肤文件，请先完成或取消导入。" : nil)
            }

            let groups = SettingsThemeGroups(themes: themeStore.viewState.themes)
            Text("内置").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                ForEach(groups.builtIn) { theme in themeCard(theme) }
            }
            Text("已导入").font(.headline)
            if groups.showsInstalledEmptyState {
                HStack {
                    Text(SettingsThemeGroups.installedEmptyTitle).foregroundStyle(.secondary)
                        .accessibilityIdentifier("themes-installed-empty")
                    Spacer()
                    Button("导入皮肤…") { showingImporter = true }
                        .disabled(themeStore.importProgress != nil)
                    .settingsDisabledReason(themeStore.importProgress != nil ? "正在处理一个皮肤文件，请先完成或取消导入。" : nil)
                }
                .padding(12)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                    ForEach(groups.installed) { theme in themeCard(theme) }
                }
            }

            if let preview = themeStore.viewState.themes.first(where: { $0.id == previewThemeID }) {
                themeDetails(preview)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("theme-details-preview")
            }

            if !themeStore.disabledInstalledThemes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已禁用的皮肤").font(.headline)
                    ForEach(themeStore.disabledInstalledThemes) { theme in
                        HStack {
                            Label("\(theme.displayName)：\(theme.reason)", systemImage: "exclamationmark.shield")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("删除", role: .destructive) {
                                Task { await themeStore.deleteDisabledTheme(id: theme.id) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button {
                    switchTheme(to: BuiltinThemeID.warmIsland)
                } label: {
                    settingsContrastTitle("恢复默认皮肤",
                        disabled: themeStore.selectedTheme.id == BuiltinThemeID.warmIsland || themeStore.viewState.isProcessing,
                        isDark: colorScheme == .dark)
                }
                .id("settings-focused-theme-reset")
                .focused($resetThemeFocused)
                .preference(key: SettingsFocusedControlPreferenceKey.self,
                    value: resetThemeFocused ? "settings-focused-theme-reset" : nil)
                .disabled(
                    themeStore.selectedTheme.id == BuiltinThemeID.warmIsland ||
                    themeStore.viewState.isProcessing
                )
                .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" :
                    (themeStore.selectedTheme.id == BuiltinThemeID.warmIsland ? "正在使用默认皮肤，无需再次恢复。" : nil))
                if themeStore.selectedTheme.id == BuiltinThemeID.warmIsland {
                    Text("正在使用默认皮肤").font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal) { importDropZone }

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("明暗外观").font(.headline)
                        Text("可跟随 macOS，或固定为浅色、深色。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("明暗外观", selection: Binding(
                        get: { themeStore.preferredAppearance },
                        set: { value in Task { await themeStore.setAppearance(value) } }
                    )) {
                        Text("跟随系统").tag(PreferredThemeAppearance.system)
                        Text("浅色").tag(PreferredThemeAppearance.light)
                        Text("深色").tag(PreferredThemeAppearance.dark)
                    }
                    .labelsHidden()
                    .frame(width: 132)
                }
                .padding(14)
                Divider()
                Toggle(isOn: Binding(
                    get: { themeStore.soundsEnabled },
                    set: { value in Task { await themeStore.setSoundsEnabled(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("皮肤提示音").font(.headline)
                        Text("默认关闭；开启后仅使用皮肤内置提示。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
            }
            .background(.quaternary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(themeStore.viewState.isProcessing)
            .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" : nil)

            if themeStore.viewState.isProcessing {
                Label("正在保存皮肤偏好…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            if let progress = themeStore.importProgress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fractionCompleted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.stage.rawValue).font(.callout.weight(.medium))
                        Text(progress.fileName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if progress.canCancel {
                        Button("取消") { themeStore.cancelImport() }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let installedID = themeStore.lastInstalledThemeID {
                HStack {
                    Text("安装后操作").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即使用") { switchTheme(to: installedID) }
                        .accessibilityIdentifier("theme-use-imported")
                    Button("稍后") { themeStore.dismissImportMessage() }
                }
            }
            if let notice = themeStore.viewState.fallbackNotice ?? themeStore.appearanceFallbackNotice(systemIsDark: colorScheme == .dark) {
                Label(notice, systemImage: themeStore.viewState.error == nil ? "info.circle.fill" : "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(themeStore.viewState.error == nil ? Color.secondary : Color.red)
            }
            Spacer(minLength: 0)
        }
        .animation(
            ThemeAppearanceTransitionPolicy.resolve(
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            ).swiftUIAnimation,
            value: ThemeAppearanceResolver.resolve(
                theme: themeStore.selectedTheme,
                preferred: themeStore.preferredAppearance,
                systemIsDark: colorScheme == .dark
            )
        )
        .overlay(alignment: .topTrailing) { SettingsSuccessToast(controller: successToast) }
        .onChange(of: themeStore.importMessage) { message in
            guard let message else { successToast.dismiss(); return }
            successToast.present(message, id: "theme-install-" + UUID().uuidString)
        }
        .onChange(of: themeStore.importError) { error in
            if error != nil { successToast.dismiss() }
        }
        .onDisappear { successToast.dismiss() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await themeStore.beginImport(from: url) }
        }
        .sheet(
            isPresented: Binding(
                get: { themeStore.importCandidate != nil },
                set: { presented in
                    if !presented { Task { await themeStore.dismissImportCandidate() } }
                }
            )
        ) {
            if let candidate = themeStore.importCandidate {
                ThemeImportPreviewView(candidate: candidate, themeStore: themeStore)
            }
        }
        .sheet(isPresented: Binding(
            get: { themeStore.importError != nil },
            set: { if !$0 { themeStore.dismissImportError() } }
        )) {
            if let error = themeStore.importError {
                ScrollView { importErrorView(error) }.frame(width: 560, height: 360)
                    .accessibilityIdentifier("theme-import-error")
                    .onExitCommand { themeStore.dismissImportError() }
            }
        }
        .onExitCommand {
            // A preview is temporary; Escape restores focus to the originating card.
            if let preview = previewThemeID, deleteTarget == nil,
               themeStore.importCandidate == nil, themeStore.importError == nil, !showingImporter {
                previewThemeID = nil
                focusedThemeID = preview
            }
        }
        .confirmationDialog(
            "删除皮肤？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            if let target = deleteTarget {
                Button("删除", role: .destructive) {
                    deleteTarget = nil
                    Task { await themeStore.deleteTheme(id: target.id) }
                }
                .accessibilityIdentifier("theme-delete-confirm")
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            if deleteTarget?.id == themeStore.selectedTheme.id {
                Text("将先切换为默认皮肤「暖屿」，再删除此皮肤。")
            } else {
                Text("删除后需要重新导入才能使用。")
            }
        }
    }

    private var importDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.title2)
            Text("将 .incomeclocktheme 拖到此处，或选择文件")
            Button("选择文件") { showingImporter = true }
        }
        .frame(minWidth: 544, maxWidth: .infinity, minHeight: 96)
        .background((isDropTargeted ? Color.accentColor : Color.secondary).opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                guard let url else { return }
                Task { @MainActor in await themeStore.beginImport(from: url) }
            }
            return true
        }
        .accessibilityLabel("导入皮肤文件区域")
    }

    private func switchTheme(to id: String) {
        guard id != themeStore.selectedTheme.id, !themeStore.viewState.isProcessing else { return }
        successToast.dismiss()
        Task {
            await themeStore.selectTheme(id: id)
            guard themeStore.selectedTheme.id == id,
                  themeStore.viewState.error == nil,
                  !themeStore.viewState.isProcessing else { return }
            successToast.present("已切换为“\(themeStore.selectedTheme.name)”", id: "theme-switch-" + UUID().uuidString)
        }
    }

    private func themeCard(_ theme: ValidatedTheme) -> some View {
        let selected = theme.id == themeStore.selectedTheme.id
        return Button { previewThemeID = theme.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                ThemeImportStandardPanelPreview(theme: theme,
                    renderGroup: ThemeAppearanceResolver.resolve(theme: theme,
                        preferred: themeStore.preferredAppearance, systemIsDark: colorScheme == .dark),
                    state: .ready)
                    .frame(width: 240, height: 143)
                    .scaleEffect(152.0 / 240.0)
                    .frame(width: 152, height: 90)
                    .clipped().allowsHitTesting(false).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(theme.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill") }
                }
                Text(theme.isDefault ? "默认 · 内置 · 不可删除" : (theme.isBuiltIn ? "内置验证皮肤" : "已安装"))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
            .frame(width: 168, height: 132)
            .background(.quaternary.opacity(previewThemeID == theme.id ? 0.72 : 0.38))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("预览皮肤\(theme.name)\(selected ? "，正在使用" : "")")
        .accessibilityIdentifier("theme-preview-" + theme.id)
        .focusable()
        .focused($focusedThemeID, equals: theme.id)
        .keyboardShortcut(focusedThemeID == theme.id ? KeyboardShortcut(.space, modifiers: []) : nil)
        .disabled(themeStore.viewState.isProcessing)
        .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" : nil)
    }

    private func themeDetails(_ theme: ValidatedTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(theme.name).font(.headline)
            Text("\(theme.manifest.author) · \(theme.manifest.themeVersion)")
            Text(theme.manifest.licenseOrSource).font(.caption).foregroundStyle(.secondary)
            Text(theme.isDefault ? "默认 · 内置 · 不可删除" : (theme.isBuiltIn ? "内置验证皮肤" : "已安装"))
            Text("支持外观：" + [theme.supportsLight ? "浅色" : nil, theme.supportsDark ? "深色" : nil].compactMap { $0 }.joined(separator: "、"))
            Text("兼容当前应用").font(.caption).foregroundStyle(.secondary)
            ThemeImportStandardPanelPreview(theme: theme,
                renderGroup: ThemeAppearanceResolver.resolve(theme: theme,
                    preferred: themeStore.preferredAppearance, systemIsDark: colorScheme == .dark),
                state: .earning)
                .frame(width: 240, height: 143)
                .allowsHitTesting(false)
            HStack {
                Button("使用此皮肤") { switchTheme(to: theme.id) }
                    .accessibilityIdentifier("theme-use")
                    .id("settings-focused-theme-use")
                    .focused($useThemeFocused)
                    .preference(key: SettingsFocusedControlPreferenceKey.self,
                        value: useThemeFocused ? "settings-focused-theme-use" : nil)
                    .disabled(theme.id == themeStore.selectedTheme.id || themeStore.viewState.isProcessing)
                    .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" :
                        (theme.id == themeStore.selectedTheme.id ? "正在使用此皮肤，无需再次应用。" : nil))
                if !theme.isBuiltIn { Button("删除", role: .destructive) { deleteTarget = theme }
                    .accessibilityIdentifier("theme-delete-request") }
            }
        }
    }

    private func importErrorView(_ error: ThemeImportError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("无法导入此皮肤", systemImage: "exclamationmark.triangle.fill")
                .modifier(SettingsCoreTextScale(role: .errorHeadline)).foregroundStyle(.red)
            if error.diagnostics.isEmpty {
                Text(importRepositoryErrorText(error)).font(.callout)
            } else {
                ForEach(error.diagnostics) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.category.rawValue)：\(item.reason)").font(.callout.weight(.medium))
                        if let name = item.item { Text(name).font(.caption).textSelection(.enabled) }
                        Text(item.suggestion).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Button("复制诊断信息") { copyDiagnostics(error) }; Button("关闭") { themeStore.dismissImportError() } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func importRepositoryErrorText(_ error: ThemeImportError) -> String {
        switch error {
        case .sourceAccessDenied: return "无法读取所选文件，请重新选择。"
        case .installFailed: return "安装失败，原有皮肤和当前选择未改变。"
        case .deleteFailed: return "删除失败，当前皮肤和业务数据保持安全状态。"
        case .preferencesFailed: return "默认皮肤选择未能保存，因此没有删除当前皮肤。"
        default: return "验证未完成，临时文件已清理。"
        }
    }

    private func copyDiagnostics(_ error: ThemeImportError) {
        let text = error.diagnostics.map {
            "[\($0.category.rawValue)] \($0.code) \($0.item ?? "-"): \($0.reason)；\($0.suggestion)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? importRepositoryErrorText(error) : text, forType: .string)
    }
}

struct ThemeImportPreviewView: View {
    let candidate: ThemeImportCandidate
    @ObservedObject var themeStore: ThemeStore
    @State private var previewState: WorkdayState

    init(
        candidate: ThemeImportCandidate,
        themeStore: ThemeStore,
        initialState: WorkdayState = .ready
    ) {
        self.candidate = candidate
        self.themeStore = themeStore
        _previewState = State(initialValue: initialState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(candidate.manifest.name).font(.title2.weight(.semibold))
            Text("\(candidate.manifest.author) · \(candidate.manifest.themeVersion)")
                .foregroundStyle(.secondary)
            if candidate.disposition == .reinstall {
                Text("此版本已安装，可取消或重新安装。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if case let .upgrade(previousVersion) = candidate.disposition {
                Text("版本更新：\(previousVersion) → \(candidate.manifest.themeVersion)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(candidate.manifest.licenseOrSource).font(.caption).foregroundStyle(.secondary)
            Picker("预览状态", selection: $previewState) {
                Text("准备").tag(WorkdayState.ready)
                Text("计薪中").tag(WorkdayState.earning)
                Text("等待下班").tag(WorkdayState.awaitingClockOut)
                Text("已完成").tag(WorkdayState.completed)
                Text("恢复").tag(WorkdayState.recoveryRequired)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 16) {
                safeThemePreview(candidate.lightPreview, title: "浅色")
                safeThemePreview(candidate.darkPreview, title: "深色")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("安全修正").font(.headline)
                if candidate.safetyAdjustments.isEmpty && candidate.ignoredOptionalCapabilities.isEmpty {
                    Text("未发现需要修正的视觉参数").foregroundStyle(.secondary)
                } else {
                    ForEach(candidate.safetyAdjustments) { item in
                        Text("• \(item.token)：\(item.reason)").font(.caption)
                    }
                    ForEach(candidate.ignoredOptionalCapabilities, id: \.name) { capability in
                        Text("• \(capability.name)@\(capability.version)：将使用标准外观降级").font(.caption)
                    }
                }
            }
            Label("此皮肤不能运行代码、访问网络或修改打卡记录", systemImage: "lock.shield")
                .font(.callout)
            Spacer()
            HStack {
                Spacer()
                Button("取消") { Task { await themeStore.dismissImportCandidate() } }
                    .accessibilityIdentifier("theme-import-cancel")
                    .disabled(themeStore.importProgress?.stage == .committing)
                    .settingsDisabledReason(themeStore.importProgress?.stage == .committing ? "正在完成安装，暂时不能取消。" : nil)
                Button(installButtonTitle(candidate.disposition)) {
                    Task { await themeStore.installImportCandidate() }
                }
                .accessibilityIdentifier("theme-import-confirm")
                .modifier(SettingsPrimaryTextScale())
                .disabled(themeStore.importProgress?.stage == .committing)
            }
        }
        .padding(24)
        .frame(width: 680, height: 500)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme-import-preview")
        .interactiveDismissDisabled(themeStore.importProgress?.stage == .committing)
        .onExitCommand {
            guard themeStore.importProgress?.stage != .committing else { return }
            Task { await themeStore.dismissImportCandidate() }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func safeThemePreview(_ group: ThemeRenderGroup, title: String) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ThemeImportStandardPanelPreview(
                theme: candidate.validatedTheme,
                renderGroup: group,
                state: previewState
            )
            .frame(width: 240, height: 143)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func installButtonTitle(_ disposition: ThemeInstallDisposition) -> String {
        switch disposition {
        case .firstInstall: return "安装皮肤"
        case .reinstall: return "重新安装"
        case .upgrade: return "更新皮肤"
        }
    }

}

struct WorkRulesSettingsView: View {
    @ObservedObject var businessStore: BusinessStore
    // Read-only observation of the real SwiftUI feedback handler; nil in production.
    var messageObserver: ((BusinessFeedback, String, Bool) -> Void)? = nil
    @StateObject private var successToast: SettingsSuccessToastController
    @State private var wage = ""
    @State private var start = "09:00"
    @State private var end = "18:00"
    @State private var validationError: WorkRuleDraftError?
    @State private var message: SettingsMessage?
    @State private var loadedInitialValue = false
    @State private var showResetConfirmation = false
    private enum Field: Hashable { case wage, start, end }
    @FocusState private var focusedField: Field?

    private struct SettingsMessage: Equatable {
        let text: String
        let isError: Bool
    }

    init(businessStore: BusinessStore,
         messageObserver: ((BusinessFeedback, String, Bool) -> Void)? = nil,
         successToast: SettingsSuccessToastController? = nil) {
        self.businessStore = businessStore
        self.messageObserver = messageObserver
        _successToast = StateObject(wrappedValue: successToast ?? SettingsSuccessToastController())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "工作规则", subtitle: "设置每日工资和固定上下班时间。")
            if businessStore.hasDamagedSettings {
                settingsBanner(title: "设置数据无法读取",
                    detail: "原文件未被改写。请重新填写并确认替换，或将损坏设置重置为未配置。", color: .red, scalesErrorTitle: true)
            } else if businessStore.hasBlockingScheduleError {
                settingsBanner(title: "今日工作时间无法确定",
                    detail: "原有设置和记录未被修改。请调整上下班时间后重试。", color: .red, scalesErrorTitle: true)
            } else if let state = businessStore.viewState?.state,
                      state != .unconfigured, state != .ready, state != .recoveryRequired {
                settingsBanner(title: "修改将于明日生效", detail: "当日已创建的记录继续使用其已冻结的工作规则。", color: .blue)
            }

            VStack(alignment: .leading, spacing: 16) {
                formField("日工资", hint: "最多两位小数") {
                    HStack(spacing: 6) { Text("¥").foregroundStyle(.secondary); TextField("300.00", text: $wage).textFieldStyle(.roundedBorder).focused($focusedField, equals: .wage).overlay { fieldFocusIndicator(.wage) }.accessibilityIdentifier("settings-wage") }
                }
                if validationError == .wage { fieldError("请输入范围内的日工资，最多两位小数。") }
                HStack(alignment: .top, spacing: 18) {
                    formField("固定上班时间", hint: "24 小时制") { TextField("09:00", text: $start).textFieldStyle(.roundedBorder).focused($focusedField, equals: .start).overlay { fieldFocusIndicator(.start) }.accessibilityIdentifier("settings-start") }
                    formField("固定下班时间", hint: "24 小时制") { TextField("18:00", text: $end).textFieldStyle(.roundedBorder).focused($focusedField, equals: .end).overlay { fieldFocusIndicator(.end) }.accessibilityIdentifier("settings-end") }
                }
                if validationError == .startTime || validationError == .endTime {
                    fieldError("请使用 HH:mm 的 24 小时时间。")
                } else if validationError == .scheduleOrder {
                    fieldError("固定下班时间必须晚于上班时间。")
                } else if businessStore.scheduleTimeErrorViewState?.context == .proposedSettings {
                    fieldError("当前时区下，此时间不存在或无法唯一确定，请选择其他时间。")
                }
            }
            .padding(16).background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 12))

            if let message, message.isError {
                Label(message.text, systemImage: message.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(message.isError ? Color.red : Color.green)
            }

            HStack {
                if businessStore.hasDamagedSettings {
                    Button("重置设置…", role: .destructive) { showResetConfirmation = true }
                }
                Spacer()
                if businessStore.isCommandInFlight { ProgressView().controlSize(.small) }
                Button(saveTitle) { save() }
                    .accessibilityIdentifier("settings-save")
                    .modifier(SettingsPrimaryTextScale())
                    .tint(Color(red: 0.10, green: 0.28, blue: 0.60))
                    .disabled(businessStore.isCommandInFlight || !hasEdits)
                    .settingsDisabledReason(businessStore.isCommandInFlight ? "正在检查或保存设置，请等待本次操作完成。" :
                        (!hasEdits ? (businessStore.currentWorkRules == nil ? "请先填写日工资。" : "设置尚未修改，无需再次保存。") : nil))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.trailing, 24)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) { SettingsSuccessToast(controller: successToast) }
        .onDisappear { successToast.dismiss() }
        .onAppear { loadCurrentRulesOnce(); focusScheduleError() }
        .onChange(of: businessStore.scheduleTimeErrorViewState) { _ in focusScheduleError() }
        .onChange(of: businessStore.feedback) { feedback in handle(feedback) }
        .confirmationDialog("重置设置？", isPresented: $showResetConfirmation) {
            Button("确认重置", role: .destructive) { requestSettingsReset() }
            Button("取消", role: .cancel) {}
        } message: { Text("这会将无法读取的设置重置为未配置，不会删除今日记录。") }
    }

    private var hasEdits: Bool {
        guard let current = businessStore.currentWorkRules else { return !wage.isEmpty }
        return (try? WorkRuleDraftParser.parse(wage: wage, start: start, end: end)) != current
    }

    private func focusScheduleError() {
        guard let error = businessStore.scheduleTimeErrorViewState?.error else { return }
        switch error {
        case let .nonexistentLocalTime(boundary, _, _), let .ambiguousLocalTime(boundary, _, _):
            focusedField = boundary == .start ? .start : .end
        }
    }

    private var saveTitle: String {
        switch businessStore.commandPhase {
        case .checking: return "正在检查…"
        case .saving: return "正在保存…"
        case .idle: return businessStore.hasDamagedSettings ? "确认替换设置" : "保存"
        }
    }

    private func loadCurrentRulesOnce() {
        guard !loadedInitialValue else { return }
        loadedInitialValue = true
        guard let rules = businessStore.currentWorkRules else { return }
        wage = WorkRuleDraftParser.wageString(rules.dailyWageCents)
        start = WorkRuleDraftParser.timeString(rules.workStartMinuteOfDay)
        end = WorkRuleDraftParser.timeString(rules.workEndMinuteOfDay)
    }

    private func save() {
        validationError = nil; message = nil
        successToast.dismiss()
        do {
            let input = try WorkRuleDraftParser.parse(wage: wage, start: start, end: end)
            Task { _ = await businessStore.send(.saveWorkRules(input), source: .settings) }
        } catch let error as WorkRuleDraftError {
            validationError = error
            switch error {
            case .wage: focusedField = .wage
            case .startTime: focusedField = .start
            case .endTime, .scheduleOrder: focusedField = .end
            }
        } catch {
            validationError = .wage
        }
    }

    private func requestSettingsReset() {
        Task {
            let requested = await businessStore.send(.requestSettingsReset, source: .settings)
            guard requested == .confirmationPresented else { return }
            _ = await businessStore.send(.confirmSettingsReset, source: .settings)
        }
    }

    private func handle(_ feedback: BusinessFeedback?) {
        guard let feedback else { return }
        switch feedback {
        case let .settingsSaved(receipt):
            message = .init(text: "设置已保存", isError: false)
            successToast.present("设置已保存", id: receipt.context.commandID.uuidString)
        case let .commandFailed(.saveWorkRules, failure):
            successToast.dismiss()
            message = .init(text: settingsFailureText(failure), isError: true)
        case .settingsResetSucceeded:
            message = .init(text: "设置已重置为未配置，今日记录未改变。", isError: false)
            successToast.present("设置已重置为未配置，今日记录未改变。", id: "settings-reset-" + UUID().uuidString)
        default: return
        }
        if let message { messageObserver?(feedback, message.text, message.isError) }
    }

    private func settingsFailureText(_ failure: BusinessFailure) -> String {
        switch failure {
        case .scheduleTime: return "设置未保存：当前时区下的时间不存在或无法唯一确定。原设置未改变。"
        case .persistence: return "设置未保存，原设置未改变。请重试。"
        default: return "设置未保存，原设置和界面状态未改变。"
        }
    }

    private func settingsBanner(title: String, detail: String, color: Color, scalesErrorTitle: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).modifier(SettingsCoreTextScale(role: .errorHeadline, enabled: scalesErrorTitle))
                Text(detail).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formField<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); content(); Text(hint).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Supplements the native ring without changing first-responder or validation routing.
    @ViewBuilder private func fieldFocusIndicator(_ field: Field) -> some View {
        if focusedField == field {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func fieldError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.primary)
    }
}

private struct DataSettingsView: View {
    @ObservedObject var businessStore: BusinessStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "数据与隐私", subtitle: "工资设置和今日记录仅保存在这台 Mac 上。")
            GroupBox("本地数据") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("应用使用 Application Support 中的原子文件存储，不上传收入或打卡记录。")
                    Text("通知不保证必达，权威状态始终以本地记录为准。").foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("重置今日记录").font(.headline)
                Text("仅在今日记录需要恢复时可用；不删除工资和工作时间设置。").foregroundStyle(.secondary)
                Button(role: .destructive) { showReset = true } label: {
                    settingsContrastTitle("重置今日记录…",
                        disabled: businessStore.viewState?.canRequestTodayReset != true || businessStore.isCommandInFlight,
                        isDark: colorScheme == .dark)
                }
                    .disabled(businessStore.viewState?.canRequestTodayReset != true || businessStore.isCommandInFlight)
                    .settingsDisabledReason(businessStore.isCommandInFlight ? "正在处理打卡记录，请稍候。" :
                        (businessStore.viewState?.canRequestTodayReset != true ? "仅在今日记录需要恢复时可重置；有效记录不会被删除。" : nil))
            }
            Spacer()
        }
        .confirmationDialog("重置今日记录？", isPresented: $showReset) {
            Button("确认重置", role: .destructive) { resetToday() }
            Button("取消", role: .cancel) {}
        } message: { Text("这会删除今天的打卡记录，但保留工资与工作时间设置。此操作无法撤销。") }
    }

    private func resetToday() {
        Task {
            let requested = await businessStore.send(.requestTodayReset, source: .settings)
            guard requested == .confirmationPresented else { return }
            _ = await businessStore.send(.confirmTodayReset, source: .settings)
        }
    }
}

private struct PanelBehaviorSettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var loginItemController: LoginItemController

    init(environment: AppEnvironment) {
        self.environment = environment
        loginItemController = environment.loginItemController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "面板与启动", subtitle: "控制标准收入面板在 macOS 桌面上的行为。")
            VStack(spacing: 0) {
                behaviorToggle("始终置顶", detail: "让收入面板保持在普通窗口上方。",
                    isOn: Binding(get: { environment.panelPreferences.alwaysOnTop }, set: environment.setAlwaysOnTop))
                Divider()
                behaviorToggle("锁定面板位置", detail: "防止鼠标拖动改变已保存的位置。",
                    isOn: Binding(get: { environment.panelPreferences.lockPanelPosition }, set: environment.setLockPanelPosition))
                Divider()
                behaviorToggle("全屏应用时隐藏", detail: "不让面板进入其他应用的全屏空间。",
                    isOn: Binding(get: { environment.panelPreferences.hideInFullScreen }, set: environment.setHideInFullScreen))
                Divider()
                behaviorToggle("登录时启动", detail: "登录 Mac 后自动打开可视收入打卡机。",
                    isOn: Binding(
                        get: { loginItemController.isEnabled },
                        set: { value in Task { await loginItemController.setEnabled(value) } }
                    ),
                    isDisabled: loginItemController.isProcessing)
            }.padding(.horizontal, 14).background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 12))
            Button("恢复默认面板位置") { environment.resetPanelPlacement() }
                .disabled(environment.isResettingPanelPlacement)
                .settingsDisabledReason(environment.isResettingPanelPlacement ? "正在保存默认位置，请稍候。" : nil)
            Text("将面板恢复到主显示器右下角，不改变计薪。")
                .font(.caption).foregroundStyle(.secondary)
            if environment.panelPreferenceError != nil {
                Label("面板设置未保存，原状态已恢复。请重试。", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if loginItemController.isProcessing {
                Label("正在与系统登录项同步…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            if let error = loginItemController.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(loginItemErrorText(error), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    if loginItemController.requiresApproval {
                        Button("打开系统“登录项”设置") {
                            loginItemController.openSystemSettings()
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func behaviorToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isDisabled { ProgressView().controlSize(.small) }
            Toggle("", isOn: isOn).labelsHidden()
                .overlay {
                    if !isOn.wrappedValue && !isDisabled {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary, lineWidth: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(isDisabled)
                .accessibilityLabel(title)
                .settingsDisabledReason(isDisabled ? "正在与系统登录项同步，请稍候。" : nil)
        }.padding(.vertical, 12)
    }

    private func loginItemErrorText(_ error: LoginItemServiceError) -> String {
        switch error {
        case .denied: return "macOS 需要你在“登录项”设置中完成批准。"
        case .settingsPersistenceFailed: return "登录项状态未能保存，已恢复原状态。"
        case .rollbackFailed: return "保存失败且系统回滚未确认；开关已显示当前系统实际状态。"
        case .inconsistentStatus: return "系统复查结果与请求不一致，未显示虚假成功。"
        default: return "无法更新登录项，原有最终状态已保留。"
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var businessStore: BusinessStore
    @ObservedObject var themeStore: ThemeStore
    @FocusState private var soundsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "通用", subtitle: "控制通知和应用级偏好。")
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下班通知").font(.headline)
                        Text("开启时才请求权限；计薪和应用内提醒不依赖系统通知。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if businessStore.isNotificationPreferenceInFlight {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("", isOn: Binding(
                        get: { businessStore.notificationsEnabled },
                        set: { value in Task { _ = await businessStore.setNotificationsEnabled(value) } }
                    ))
                    .labelsHidden()
                    .overlay {
                        if !businessStore.notificationsEnabled &&
                            !businessStore.isNotificationPreferenceInFlight && !businessStore.isRestoring {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.primary, lineWidth: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(businessStore.isNotificationPreferenceInFlight || businessStore.isRestoring)
                    .settingsDisabledReason(businessStore.isRestoring ? "正在恢复本地记录，请稍候。" :
                        (businessStore.isNotificationPreferenceInFlight ? "正在同步通知偏好，请稍候。" : nil))
                    .accessibilityLabel("下班通知")
                }
                .padding(.vertical, 12)
                Divider()
                Toggle("皮肤提示音", isOn: Binding(get: { themeStore.soundsEnabled },
                    set: { value in Task { await themeStore.setSoundsEnabled(value) } }))
                    .focused($soundsFocused)
                    .overlay(alignment: .leading) {
                        if !themeStore.viewState.isProcessing {
                            // Decorate only the native checkbox; its label, hit target,
                            // binding and accessibility role remain on the Toggle.
                            ZStack {
                                if !themeStore.soundsEnabled {
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.primary, lineWidth: 1)
                                        .frame(width: 16, height: 16)
                                }
                                if soundsFocused {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: 16, height: 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .disabled(themeStore.viewState.isProcessing)
            .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" : nil)
                    .padding(.vertical, 12)
                Divider()
                Picker("应用外观", selection: Binding(get: { themeStore.preferredAppearance },
                    set: { value in Task { await themeStore.setAppearance(value) } })) {
                    Text("跟随系统").tag(PreferredThemeAppearance.system)
                    Text("浅色").tag(PreferredThemeAppearance.light)
                    Text("深色").tag(PreferredThemeAppearance.dark)
                }.pickerStyle(.segmented)
                    .tint(Color(red: 0.10, green: 0.28, blue: 0.60))
                    .disabled(themeStore.viewState.isProcessing)
            .settingsDisabledReason(themeStore.viewState.isProcessing ? "正在保存皮肤偏好，请稍候。" : nil)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = businessStore.notificationPreferenceError {
                Label(notificationInlineErrorText(error), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("notification-inline-error")
            }
            if let error = themeStore.viewState.error {
                Text(error == .persistenceFailed ? "外观或提示音偏好未保存，原值已保留。" : "皮肤偏好无法读取，正在使用安全默认外观。")
                    .foregroundStyle(.red)
            }
            Text("系统可能因勿扰模式或通知策略不展示通知，因此不保证必达。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

}

func notificationInlineErrorText(_ error: NotificationFeatureError) -> String {
    switch error {
    case .permissionDenied: return "通知权限未允许，下班通知仍保持关闭。"
    case .permissionQueryFailed: return "无法读取通知权限，下班通知仍保持原值。"
    case .permissionRequestFailed: return "通知权限请求失败，下班通知仍保持关闭。"
    case .settingsPersistenceFailed: return "通知偏好未保存，原值已恢复。"
    case .addFailed, .addNotConfirmed, .pendingQueryFailed, .markerPersistenceFailed:
        return "下班通知未能完整确认，不影响计薪和应用内提醒。"
    case .cancellationFailed:
        return "下班已完成，但系统通知取消失败；不影响最终金额。"
    case .cancellationPendingQueryFailed:
        return "下班已完成，但无法确认系统通知已取消；不影响最终金额。"
    case .cancellationNotConfirmed:
        return "下班已完成，但系统通知仍在等待列表；不影响最终金额。"
    }
}

private struct PlaceholderSettingsPage: View {
    let title: String
    let subtitle: String
    let rows: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack { Text(row.0); Spacer(); Text(row.1).foregroundStyle(.secondary) }.padding(.vertical, 12)
                    if index < rows.count - 1 { Divider() }
                }
            }.padding(.horizontal, 14).background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }
}

private struct SettingsHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}


// Native Button still owns enablement, hit testing, AX and action routing.
// Attribute only the disabled label; enabled/destructive styling remains native.
private func settingsContrastTitle(_ value: String, disabled: Bool, isDark: Bool) -> Text {
    var title = AttributedString(value)
    if disabled { title.foregroundColor = isDark ? Color.white : Color.black }
    return Text(title)
}

private extension View {
    /// Keep disabled controls understandable to pointer and assistive-technology users.
    /// Enabled controls retain their normal labels; this changes no action or state.
    func settingsDisabledReason(_ reason: String?) -> some View {
        help(Text(reason ?? ""))
            .accessibilityHint(Text(reason ?? ""))
    }
}
