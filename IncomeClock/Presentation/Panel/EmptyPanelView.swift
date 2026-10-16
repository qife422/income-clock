import AppKit
import CoreText
import SwiftUI

@MainActor
final class Stage5PanelKeyboardCoordinator: ObservableObject {
    struct FocusRequest: Equatable {
        let generation: UInt64
        let target: Stage5PanelKeyboardFocus?
    }

    @Published private(set) var focusRequest = FocusRequest(generation: 0, target: nil)
    var semanticFocus: Stage5PanelKeyboardFocus? { focusRequest.target }
#if DEBUG
    var focusBindingTrace: (@MainActor (String) -> Void)?
    private var focusBindingTraceCount = 0
    private var focusBindingReceiveCount = 0
    private var lastFocusBindingTrace: String?

    func recordFocusBinding(_ source: String, requested: Stage5PanelKeyboardFocus?,
                            before: String, actual: Stage5PanelKeyboardFocus?) {
        guard let trace = focusBindingTrace else { return }
        if source == "onAppearRequest" || source == "onChangeRequest" { focusBindingReceiveCount += 1 }
        let state = "source=\(source),requested=\(String(describing: requested)),before=\(before),actual=\(String(describing: actual)),semantic=\(String(describing: semanticFocus)),businessState=\(String(describing: businessStore?.viewState?.state)),inFlight=\(businessStore?.isCommandInFlight == true),confirmation=\(businessStore?.confirmation != nil)"
        // Count repeated publisher deliveries, but log only changed observations.
        // Time and count are outside the fingerprint, so 60Hz rendering alone
        // cannot fill the attachment with equivalent records.
        guard state != lastFocusBindingTrace, focusBindingTraceCount < 128 else { return }
        lastFocusBindingTrace = state
        focusBindingTraceCount += 1
        trace("local-binding#\(focusBindingTraceCount),uptime=\(ProcessInfo.processInfo.systemUptime),receiveCount=\(focusBindingReceiveCount)," + state)
    }
#endif
    private weak var businessStore: BusinessStore?
    private var onOpenSettings: (() -> Void)?
    private var onHide: (() -> Void)?

    func configure(
        businessStore: BusinessStore,
        onOpenSettings: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.businessStore = businessStore
        self.onOpenSettings = onOpenSettings
        self.onHide = onHide
    }

    func requestInitialFocus() {
        requestFocus(focusOrder.first)
    }

    private func requestFocus(_ target: Stage5PanelKeyboardFocus?) {
        // Repeat requests are meaningful even when the semantic target is unchanged.
        // Publish target and identity together; native delivery must not mutate this.
        focusRequest = FocusRequest(generation: focusRequest.generation &+ 1, target: target)
    }

    func send(_ command: IncomePanel.KeyboardCommand) {
        switch command {
        case let .advanceFocus(reverse):
            advance(reverse: reverse)
        case .activateFocus:
            activate()
        case .cancelConfirmation:
            guard businessStore?.confirmation != nil else { return }
            sendBusiness(.cancelConfirmation)
        }
    }

    private var focusOrder: [Stage5PanelKeyboardFocus] {
        guard let businessStore else { return [] }
        return Stage5PanelKeyboardModel.focusOrder(
            confirmationPresented: businessStore.confirmation != nil,
            hasUsablePrimaryAction: hasUsablePrimaryAction(in: businessStore)
        )
    }

    private func hasUsablePrimaryAction(in store: BusinessStore) -> Bool {
        if store.confirmation != nil || store.isRestoring { return true }
        if store.hasBlockingScheduleError { return true }
        if store.settingsReadErrorViewState?.isBlocking == true { return true }
        guard let state = store.viewState else { return true }
        if state.state == .recoveryRequired { return true }
        return Stage5PanelKeyboardModel.hasUsablePrimaryAction(
            in: Stage5PanelPresentation.make(from: state),
            commandInFlight: store.isCommandInFlight
        )
    }

    private func advance(reverse: Bool) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = semanticFocus,
              let index = order.firstIndex(of: current) else {
            requestFocus(reverse ? order.last : order.first)
            return
        }
        let delta = reverse ? -1 : 1
        requestFocus(order[(index + delta + order.count) % order.count])
    }

    private func activate() {
        guard let store = businessStore else { return }
        switch semanticFocus {
        case .settings:
            onOpenSettings?()
        case .hide:
            onHide?()
        case .cancel:
            guard store.confirmation != nil else { return }
            sendBusiness(.cancelConfirmation)
        case .confirm:
            guard let confirmation = store.confirmation else { return }
            sendBusiness(confirmCommand(for: confirmation))
        case .primary:
            activatePrimary(in: store)
        case nil:
            break
        }
    }

    private func activatePrimary(in store: BusinessStore) {
        if store.isRestoring ||
            store.hasBlockingScheduleError ||
            store.viewState == nil {
            onOpenSettings?()
            return
        }
        if store.settingsReadErrorViewState?.isBlocking == true {
            sendBusiness(.requestSettingsReset)
            return
        }
        guard let state = store.viewState else { return }
        if state.state == .recoveryRequired {
            sendBusiness(.requestTodayReset)
            return
        }
        let presentation = Stage5PanelPresentation.make(from: state)
        guard Stage5PanelKeyboardModel.hasUsablePrimaryAction(
            in: presentation,
            commandInFlight: store.isCommandInFlight
        ) else { return }
        switch presentation.action {
        case .openSettings: onOpenSettings?()
        case .clockIn: sendBusiness(.clockIn)
        case .clockOut: sendBusiness(.requestClockOut)
        case .startToday: sendBusiness(.requestStartToday)
        case .resetToday: sendBusiness(.requestTodayReset)
        case .none: break
        }
    }

    private func confirmCommand(for confirmation: BusinessConfirmation) -> BusinessCommand {
        switch confirmation {
        case .clockOut: .confirmClockOut
        case .resetToday: .confirmTodayReset
        case .startToday: .confirmStartToday
        case .resetSettings: .confirmSettingsReset
        }
    }

    private func sendBusiness(_ command: BusinessCommand) {
        guard let businessStore else { return }
        Task { _ = await businessStore.send(command, source: .panel) }
    }
}

enum Stage5PanelKeyboardFocus: Hashable {
    case settings
    case hide
    case primary
    case cancel
    case confirm
}

enum Stage5PanelKeyboardModel {
    static func focusOrder(
        confirmationPresented: Bool,
        hasUsablePrimaryAction: Bool
    ) -> [Stage5PanelKeyboardFocus] {
        if confirmationPresented { return [.cancel, .confirm] }
        return hasUsablePrimaryAction ? [.settings, .hide, .primary] : [.settings, .hide]
    }

    static func hasUsablePrimaryAction(
        in presentation: Stage5PanelPresentation,
        commandInFlight: Bool = false
    ) -> Bool {
        guard presentation.actionTitle != nil, !commandInFlight else { return false }
        if case let .clockIn(enabled) = presentation.action { return enabled }
        return presentation.action != .none
    }
}

struct Stage5PanelPresentation: Equatable {
    enum Action: Equatable {
        case openSettings
        case clockIn(enabled: Bool)
        case clockOut
        case startToday
        case resetToday
        case none
    }

    let symbol: String
    let status: String
    let amount: String?
    let precisionNote: String?
    let progress: Double?
    let progressLabel: String
    let supportText: String
    let durationText: String
    let actionTitle: String?
    let action: Action
    let destructive: Bool

    static func make(from state: BusinessViewState) -> Self {
        let amount = Stage5AmountFormatter.string(for: state.amount)
        let progress = state.scheduledProgress.map { min(1, max(0, $0)) }
        let duration = "已计薪 \(Stage5DurationFormatter.string(state.earnedDuration ?? .zero))"
        switch state.state {
        case .unconfigured:
            return .init(symbol: "gearshape", status: "待完成设置", amount: amount,
                precisionNote: nil, progress: nil, progressLabel: "—",
                supportText: "设置工资与工作时间", durationText: "尚未计薪",
                actionTitle: "打开设置", action: .openSettings, destructive: false)
        case .ready:
            let support: String
            if let remaining = state.remainingToStart, remaining > .zero {
                support = "距离开始 \(Stage5DurationFormatter.string(remaining))"
            } else if state.canClockIn {
                support = "计划进行中"
            } else {
                support = "今日计划已结束"
            }
            return .init(symbol: "circle", status: "今日未打卡", amount: amount,
                precisionNote: nil, progress: progress,
                progressLabel: Stage5AmountFormatter.percent(progress), supportText: support,
                durationText: duration, actionTitle: state.canClockIn ? "打卡上班" : "今日无法打卡",
                action: .clockIn(enabled: state.canClockIn), destructive: false)
        case .clockedInWaiting:
            return .init(symbol: "clock", status: "已打卡 · 等待开工", amount: amount,
                precisionNote: nil, progress: 0, progressLabel: "0%",
                supportText: "距离开始 \(Stage5DurationFormatter.string(state.remainingToStart ?? .zero))",
                durationText: duration, actionTitle: "打卡下班", action: .clockOut, destructive: false)
        case .earning:
            return .init(symbol: "circle.fill", status: "计薪中", amount: amount,
                precisionNote: "实时收入估算", progress: progress,
                progressLabel: Stage5AmountFormatter.percent(progress),
                supportText: "距离下班 \(Stage5DurationFormatter.string(state.remainingToEnd ?? .zero))",
                durationText: duration, actionTitle: "打卡下班", action: .clockOut, destructive: false)
        case .awaitingClockOut:
            return .init(symbol: "exclamationmark.circle.fill",
                status: state.isPreviousWorkday ? "上一个工作日未完成 · \(state.todayDateKey ?? "")" : "计薪已停止",
                amount: amount, precisionNote: "已停止计薪", progress: 1, progressLabel: "100%",
                supportText: state.isPreviousWorkday ? "计薪已于计划下班时间停止" : "请打卡下班",
                durationText: duration, actionTitle: "打卡下班", action: .clockOut, destructive: false)
        case .completed:
            return .init(symbol: "checkmark.circle.fill",
                status: state.isPreviousWorkday ? "上一工作日已结算 · \(state.todayDateKey ?? "")" : "今日已完成",
                amount: amount, precisionNote: nil, progress: nil, progressLabel: "",
                supportText: "计薪时长 \(Stage5DurationFormatter.string(state.earnedDuration ?? .zero))",
                durationText: "上班 \(Stage5TimestampFormatter.string(state.clockInAt, zone: state.todayTimeZoneIdentifier)) · 下班 \(Stage5TimestampFormatter.clockOutString(state))",
                actionTitle: state.canRequestStartToday ? "开始今天" : nil,
                action: state.canRequestStartToday ? .startToday : .none, destructive: false)
        case .recoveryRequired:
            return .init(symbol: "exclamationmark.triangle.fill", status: "记录需要恢复",
                amount: nil, precisionNote: nil, progress: nil, progressLabel: "",
                supportText: "记录不完整或校验失败", durationText: "暂时无法确定今日收入",
                actionTitle: "重置今日记录", action: .resetToday, destructive: true)
        }
    }
}

enum Stage5AmountFormatter {
    static func string(for amount: BusinessEarnedAmount) -> String? {
        switch amount {
        case .hidden: return nil
        case let .live(value): return string(minorUnits: value.rawValue, fractionDigits: 3)
        case let .rounded(value): return string(minorUnits: value.rawValue, fractionDigits: 2)
        }
    }

    static func string(minorUnits: Int64, fractionDigits: Int) -> String {
        let divisor: Int64 = fractionDigits == 3 ? 1_000 : 100
        return "¥\(grouped(minorUnits / divisor)).\(String(format: "%0*lld", fractionDigits, minorUnits % divisor))"
    }

    static func measuredFont(size: CGFloat, weight: Font.Weight = .medium,
                             design: Font.Design = .default) -> NSFont {
        let nativeWeight: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : .medium
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: nativeWeight)
        guard design == .rounded,
              let descriptor = font.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else { return font }
        return rounded
    }

    static func amountHeight(textScale: CGFloat) -> CGFloat {
        60 - 25 * min(1.2, max(1, textScale))
    }

    static func numericInkBounds(font: NSFont) -> CGRect {
        // Include the whole numeric alphabet so a changed digit cannot change the
        // font tier or baseline inside the same integer-count / text-scale range.
        let text = NSAttributedString(string: "¥0123456789,.", attributes: [.font: font])
        return CTLineGetImageBounds(CTLineCreateWithAttributedString(text as CFAttributedString), nil)
    }

    static func amountBaseline(font: NSFont, height: CGFloat) -> CGFloat {
        let ink = numericInkBounds(font: font)
        return (height - ink.height) / 2 - ink.minY
    }

    static func fontSize(for formatted: String, weight: Font.Weight = .medium,
                         design: Font.Design = .default, textScale: CGFloat = 1,
                         availableHeight: CGFloat? = nil) -> CGFloat {
        let availableHeight = availableHeight ?? amountHeight(textScale: textScale)
        // Measure the actual tabular font. Both fixed decimal-anchor columns and
        // the complete amount retain a four-point inset; no continuous scaling.
        let pieces = formatted.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = String(pieces.first ?? "")
        let fraction = pieces.count == 2 ? ".\(pieces[1])" : ""
        for size in [CGFloat(34), 32, 30, 28, 26] {
            let font = measuredFont(size: size, weight: weight, design: design)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            func glyphWidth(_ value: String) -> CGFloat {
                value.reduce(0) { $0 + (String($1) as NSString).size(withAttributes: attributes).width }
            }
            if glyphWidth(integer) <= 162,
               glyphWidth(fraction) <= 110,
               glyphWidth(formatted) <= 272,
               numericInkBounds(font: font).height <= availableHeight - 2 {
                return size
            }
        }
        return 26
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func accessibilityValue(for amount: BusinessEarnedAmount) -> String {
        switch amount {
        case .hidden: return "收入不可用"
        case let .live(value):
            let rest = value.rawValue % 1_000
            return "\(value.rawValue / 1_000) 元 \(rest / 100) 角 \((rest / 10) % 10) 分 \(rest % 10) 厘，实时收入估算"
        case let .rounded(value):
            return "\(value.rawValue / 100) 元 \((value.rawValue / 10) % 10) 角 \(value.rawValue % 10) 分，已结算"
        }
    }

    private static func grouped(_ value: Int64) -> String {
        var result = ""
        for (offset, character) in String(value).reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

// App text scale is a rendering environment, not a persisted work-rule setting.
// Native dynamic-type metrics and explicit host environments share the same cap.
private struct IncomePanelTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}
private struct IncomePanelAmountMotionKey: EnvironmentKey {
    static let defaultValue = false
}
private struct IncomePanelCalibrationKey: EnvironmentKey {
    static let defaultValue = 0
}
extension EnvironmentValues {
    var incomePanelTextScale: CGFloat {
        get { self[IncomePanelTextScaleKey.self] }
        set { self[IncomePanelTextScaleKey.self] = min(1.2, max(1, newValue)) }
    }
    var incomePanelAmountMotion: Bool {
        get { self[IncomePanelAmountMotionKey.self] }
        set { self[IncomePanelAmountMotionKey.self] = newValue }
    }
    var incomePanelCalibration: Int {
        get { self[IncomePanelCalibrationKey.self] }
        set { self[IncomePanelCalibrationKey.self] = newValue }
    }
}
private struct IncomePanelScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.incomePanelTextScale) private var requestedScale
    @ScaledMetric(relativeTo: .body) private var nativeScale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(.system(size: size * min(1.2, max(requestedScale, nativeScale)), weight: weight))
    }
}
private extension View {
    func incomePanelFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(IncomePanelScaledFont(size: size, weight: weight))
    }
}

/// Optional layout observations for hosted verification. Production callers
/// leave this nil, so no geometry readers or observation publications are made.
@MainActor
final class PanelLayoutObservation {
    var frames: [String: CGRect] = [:]
}

private struct PanelLayoutObservationKey: EnvironmentKey {
    static let defaultValue: PanelLayoutObservation? = nil
}

private struct PanelLayoutFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension EnvironmentValues {
    var panelLayoutObservation: PanelLayoutObservation? {
        get { self[PanelLayoutObservationKey.self] }
        set { self[PanelLayoutObservationKey.self] = newValue }
    }
}

private struct PanelFrameObservation: ViewModifier {
    let name: String
    @Environment(\.panelLayoutObservation) private var observation
    func body(content: Content) -> some View {
        if observation != nil {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PanelLayoutFramesKey.self,
                        value: [name: geometry.frame(in: .named("income-panel-layout"))])
                }
            }
        } else { content }
    }
}

private extension View {
    func observePanelFrame(_ name: String) -> some View {
        modifier(PanelFrameObservation(name: name))
    }

    func fixedPanelFrame(_ name: String, _ frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .observePanelFrame(name)
            .offset(x: frame.minX, y: frame.minY)
    }
}

struct PanelOdometerPreset: Equatable {
    let duration: TimeInterval
    let displacementEm: CGFloat
    // Zero staggering is inside both Contract maxima and keeps a carry atomic.
    let staggerMilliseconds = 0
    static func resolve(themeID: String) -> Self {
        themeID == BuiltinThemeID.windowCompanion
            ? Self(duration: 0.180, displacementEm: 0.68)
            : Self(duration: 0.160, displacementEm: 0.72)
    }
    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
}

struct PanelAmountGlyph: Equatable {
    let key: String
    let text: String
    let frame: CGRect
}

enum PanelAmountGeometry {
    static let columnAnchor: CGFloat = 166
    static let panelAnchor: CGFloat = 12 + columnAnchor

    static func glyphs(_ formatted: String, font: NSFont, height: CGFloat) -> [PanelAmountGlyph] {
        let parts = formatted.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var glyphs: [PanelAmountGlyph] = []
        var x = columnAnchor
        for (place, character) in String(parts.first ?? "").reversed().enumerated() {
            let text = String(character)
            let width = (text as NSString).size(withAttributes: attributes).width
            x -= width
            glyphs.append(.init(key: "integer-\(place)", text: text,
                                frame: CGRect(x: x, y: 0, width: width, height: height)))
        }
        x = columnAnchor
        let fraction = parts.count == 2 ? ".\(parts[1])" : ""
        for (place, character) in fraction.enumerated() {
            let text = String(character)
            let width = (text as NSString).size(withAttributes: attributes).width
            glyphs.append(.init(key: "fraction-\(place)", text: text,
                                frame: CGRect(x: x, y: 0, width: width, height: height)))
            x += width
        }
        return glyphs
    }
}

private final class PanelAmountGlyphTextLayer: CATextLayer {
    var numericBaseline: CGFloat = 0

    override init() { super.init() }
    override init(layer: Any) {
        super.init(layer: layer)
        numericBaseline = (layer as? PanelAmountGlyphTextLayer)?.numericBaseline ?? 0
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(in context: CGContext) {
        guard let text = string as? NSAttributedString else { return }
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (bounds.width - width) / 2, y: numericBaseline)
        CTLineDraw(line, context)
    }
}

/// A native layer-backed odometer. Each changed glyph moves; unchanged digits,
/// punctuation, container and decimal anchor stay still. New targets replace the
/// old animation in one CATransaction using its current presentation position.
@MainActor
final class PanelAmountNativeView: NSView {
    private struct Slot {
        var glyph: PanelAmountGlyph
        let container: CALayer
        var incoming: CATextLayer
    }
    private var slots: [String: Slot] = [:]
    private var previousAmount: BusinessEarnedAmount?
    private var previousFont: NSFont?
    private var previousColor: NSColor?
    private var previousCalibration: Int?
    private(set) var targetText = ""
    private(set) var lastDirection = 0
    private(set) var lastDuration: TimeInterval = 0
    private(set) var renderedGlyphs: [PanelAmountGlyph] = []
    private(set) var appliedFontSize: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 35) }

    func apply(amount: BusinessEarnedAmount, font: NSFont, color: NSColor,
               preset: PanelOdometerPreset, motionEnabled: Bool, calibration: Int,
               height: CGFloat) {
        let text = Stage5AmountFormatter.string(for: amount) ?? ""
        let fontChanged = previousFont != font || previousColor != color
        let recalibrated = previousCalibration != calibration
        var direction = 0
        if motionEnabled, !fontChanged, !recalibrated,
           case let .live(old)? = previousAmount, case let .live(new) = amount {
            direction = new.rawValue == old.rawValue ? 0 : new.rawValue > old.rawValue ? 1 : -1
        }
        let glyphs = PanelAmountGeometry.glyphs(text, font: font, height: height)
        let unchanged = text == targetText && !fontChanged && !recalibrated
            && renderedGlyphs == glyphs
        previousAmount = amount
        previousFont = font
        previousColor = color
        previousCalibration = calibration
        targetText = text
        renderedGlyphs = glyphs
        appliedFontSize = font.pointSize
        // Rounded/hidden values end every live roll, including unchanged digit slots.
        if case .live = amount {} else { cancelAnimations() }
        if unchanged {
            if !motionEnabled { cancelAnimations() }
            return
        }
        lastDirection = direction
        lastDuration = direction == 0 ? 0 : preset.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let liveKeys = Set(glyphs.map(\.key))
        for key in Array(slots.keys) where !liveKeys.contains(key) {
            slots.removeValue(forKey: key)?.container.removeFromSuperlayer()
        }
        for glyph in glyphs {
            if let slot = slots[glyph.key], slot.glyph == glyph, !fontChanged,
               !recalibrated, motionEnabled { continue }
            let oldSlot = slots[glyph.key]
            let container = oldSlot?.container ?? CALayer()
            // Snapshot the actual presentation before canceling an interrupted roll.
            let image = direction == 0 ? nil : oldSlot.flatMap { snapshot($0.container) }
            let currentIncomingY = oldSlot?.incoming.presentation()?.position.y
            let priorTargetY = oldSlot?.incoming.position.y
            let existingOffset = zipOptional(currentIncomingY, priorTargetY).map { pair in pair.0 - pair.1 }
            container.removeAllAnimations()
            container.sublayers?.forEach { $0.removeFromSuperlayer() }
            container.frame = glyph.frame
            container.masksToBounds = true
            if container.superlayer == nil { layer?.addSublayer(container) }
            let incoming = makeText(glyph.text, font: font, color: color, size: glyph.frame.size)
            container.addSublayer(incoming)
            if direction != 0, glyph.text.first?.isNumber == true {
                let displacement = CGFloat(direction) * preset.displacementEm * font.pointSize
                if let image {
                    let outgoing = CALayer()
                    outgoing.frame = container.bounds
                    outgoing.contents = image
                    outgoing.contentsScale = window?.backingScaleFactor ?? 2
                    container.insertSublayer(outgoing, below: incoming)
                    let exit = CABasicAnimation(keyPath: "transform.translation.y")
                    exit.fromValue = 0
                    exit.toValue = displacement
                    exit.duration = preset.duration
                    exit.timingFunction = preset.timingFunction
                    exit.isRemovedOnCompletion = false
                    exit.fillMode = .forwards
                    outgoing.add(exit, forKey: "roll-out")
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 1
                    fade.toValue = 0
                    fade.duration = preset.duration
                    fade.isRemovedOnCompletion = false
                    fade.fillMode = .forwards
                    outgoing.add(fade, forKey: "roll-out-opacity")
                }
                let enter = CABasicAnimation(keyPath: "position.y")
                enter.fromValue = incoming.position.y + (existingOffset ?? -displacement)
                enter.toValue = incoming.position.y
                enter.duration = preset.duration
                enter.timingFunction = preset.timingFunction
                incoming.add(enter, forKey: "roll-in")
            }
            slots[glyph.key] = Slot(glyph: glyph, container: container, incoming: incoming)
        }
        CATransaction.commit()
    }

    private func zipOptional(_ lhs: CGFloat?, _ rhs: CGFloat?) -> (CGFloat, CGFloat)? {
        guard let lhs, let rhs else { return nil }
        return (lhs, rhs)
    }

    private func makeText(_ text: String, font: NSFont, color: NSColor, size: CGSize) -> CATextLayer {
        let result = PanelAmountGlyphTextLayer()
        result.frame = CGRect(origin: .zero, size: size)
        result.numericBaseline = Stage5AmountFormatter.amountBaseline(font: font, height: size.height)
        result.string = NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ])
        result.alignmentMode = .center
        result.contentsScale = window?.backingScaleFactor ?? 2
        result.truncationMode = .none
        return result
    }

    private func snapshot(_ source: CALayer) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        guard source.bounds.width > 0, source.bounds.height > 0,
              let context = CGContext(data: nil,
                width: Int(ceil(source.bounds.width * scale)),
                height: Int(ceil(source.bounds.height * scale)),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        (source.presentation() ?? source).render(in: context)
        return context.makeImage()
    }

    func cancelAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in slots.values {
            slot.container.sublayers?.filter { $0 !== slot.incoming }.forEach { $0.removeFromSuperlayer() }
            slot.incoming.removeAllAnimations()
        }
        CATransaction.commit()
        lastDirection = 0
        lastDuration = 0
    }

    var activeAnimationCount: Int {
        slots.values.reduce(0) { count, slot in
            count + (slot.container.sublayers ?? []).reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
        }
    }
    func incomingAnimation(for key: String) -> CABasicAnimation? {
        slots[key]?.incoming.animation(forKey: "roll-in") as? CABasicAnimation
    }
}

private struct PanelAmountView: NSViewRepresentable {
    let amount: BusinessEarnedAmount
    let font: NSFont
    let color: NSColor
    let preset: PanelOdometerPreset
    let height: CGFloat
    @Environment(\.incomePanelAmountMotion) private var motionEnabled
    @Environment(\.incomePanelCalibration) private var calibration

    func makeNSView(context: Context) -> PanelAmountNativeView {
        PanelAmountNativeView(frame: CGRect(x: 0, y: 0, width: 280, height: height))
    }
    func updateNSView(_ view: PanelAmountNativeView, context: Context) {
        view.apply(amount: amount, font: font, color: color, preset: preset,
                   motionEnabled: motionEnabled, calibration: calibration, height: height)
    }
    static func dismantleNSView(_ view: PanelAmountNativeView, coordinator: ()) {
        view.cancelAnimations()
    }
}

enum Stage5DurationFormatter {
    static func string(_ duration: DurationMilliseconds) -> String {
        let seconds = duration.rawValue / 1_000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}

enum Stage5TimestampFormatter {
    static func clockOutString(_ state: BusinessViewState) -> String {
        let time = string(state.clockOutAt, zone: state.todayTimeZoneIdentifier)
        guard let date = state.clockOutDateKey, date != state.todayDateKey else { return time }
        // The application already froze this date in Today snapshot timezone.
        // Never reinterpret the workday using the current system timezone.
        return "\(date) \(time)"
    }

    static func string(_ timestamp: TimestampMilliseconds?, zone: String?) -> String {
        guard let timestamp else { return "--:--:--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp.rawValue) / 1_000))
    }
}

private struct WarmIslandPalette {
    let themeID: String
    let tokens: ThemeColorTokens
    let background: Color
    let raised: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let accent: Color
    let accentHover: Color
    let accentPressed: Color
    let start: Color
    let stop: Color
    let actionText: Color
    let progressFill: Color
    let statusReady: Color
    let statusWaiting: Color
    let statusEarning: Color
    let statusAwaiting: Color
    let statusCompleted: Color
    let error: Color
    let focusRing: Color
    let shadowColor: Color
    let border: Color
    let track: Color
    let backgroundOpacity: Double
    let shadowY: Double
    let shadowBlur: Double
    let shadowOpacity: Double
    let metrics: ThemeMetricTokens
    let amountFontDesign: Font.Design
    let amountFontWeight: Font.Weight

    static func make(theme: ValidatedTheme, renderGroup: ThemeRenderGroup) -> Self {
        let tokens = renderGroup.colors
        let safeFallback = ValidatedTheme.warmIslandFallback.colors(
            dark: renderGroup.appearance == .dark
        )
        func status(_ role: ThemeStatusRole) -> Color {
            let resolved = ThemeStatusStyleResolver.resolve(
                role: role,
                tokens: tokens,
                safeFallback: safeFallback
            )
            return Color(themeHex: resolved?.emphasis ?? safeFallback.primaryText)
        }
        return .init(
            themeID: theme.id,
            tokens: tokens,
            background: Color(themeHex: tokens.background),
            raised: Color(themeHex: tokens.raised),
            primary: Color(themeHex: tokens.primaryText),
            secondary: Color(themeHex: tokens.secondaryText),
            tertiary: Color(themeHex: tokens.tertiaryText),
            accent: Color(themeHex: tokens.accent),
            accentHover: Color(themeHex: tokens.accentHover),
            accentPressed: Color(themeHex: tokens.accentPressed),
            start: Color(themeHex: tokens.start),
            stop: Color(themeHex: tokens.stop),
            actionText: Color(themeHex: tokens.actionText),
            progressFill: Color(themeHex: tokens.progressFill),
            statusReady: status(.ready),
            statusWaiting: status(.waiting),
            statusEarning: status(.earning),
            statusAwaiting: status(.awaiting),
            statusCompleted: status(.completed),
            error: status(.error),
            focusRing: Color(themeHex: tokens.focusRing),
            shadowColor: Color(themeHex: tokens.shadowColor),
            border: Color(themeHex: tokens.border),
            track: Color(themeHex: tokens.progressTrack),
            backgroundOpacity: tokens.backgroundOpacity,
            shadowY: tokens.shadowY,
            shadowBlur: tokens.shadowBlur,
            shadowOpacity: tokens.shadowOpacity,
            metrics: theme.manifest.metrics,
            amountFontDesign: theme.manifest.amountFontDesign == .rounded ? .rounded : .default,
            amountFontWeight: fontWeight(theme.manifest.amountFontWeight)
        )
    }

    private static func fontWeight(_ token: String) -> Font.Weight {
        switch token.lowercased() {
        case "bold": return .bold
        case "semibold": return .semibold
        default: return .medium
        }
    }
}

extension Color {
    init(themeHex: String) {
        let hex = themeHex.dropFirst()
        let value = UInt64(hex, radix: 16) ?? 0
        let hasAlpha = hex.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(value & 0xff) / 255 : 1
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct StandardPanelSemanticInput: Equatable, Sendable {
    let state: WorkdayState
    let amount: BusinessEarnedAmount
    let presentation: Stage5PanelPresentation
    let isPreviousWorkday: Bool
    let todayDateKey: String?
    let settingsRequireRepair: Bool
    let hasCrossdayClockOut: Bool
    let clockInText: String
    let clockOutText: String

    init(viewState: BusinessViewState, settingsRequireRepair: Bool = false) {
        state = viewState.state
        amount = viewState.amount
        presentation = Stage5PanelPresentation.make(from: viewState)
        isPreviousWorkday = viewState.isPreviousWorkday
        todayDateKey = viewState.todayDateKey
        self.settingsRequireRepair = settingsRequireRepair
        hasCrossdayClockOut = viewState.clockOutDateKey != nil && viewState.clockOutDateKey != viewState.todayDateKey
        clockInText = "上班 \(Stage5TimestampFormatter.string(viewState.clockInAt, zone: viewState.todayTimeZoneIdentifier))"
        clockOutText = "下班 \(Stage5TimestampFormatter.clockOutString(viewState))"
    }
}

enum Stage5SettlementBlessing {
    static func full(amount: String) -> String {
        "今日辛苦啦，喜提 \(amount)，今天的努力已经成功变现。"
    }

    // UI §17.3 permits an application-owned semantic equivalent when the full
    // blessing exceeds the available width. Its accessible label stays complete.
    static func compact(amount: String) -> String {
        "辛苦啦，已结算 \(amount)。"
    }
}

enum ThemeImportPreviewScenario {
    static let supportedStates: [WorkdayState] = [
        .ready, .earning, .awaitingClockOut, .completed, .recoveryRequired
    ]

    static func renderInput(for state: WorkdayState) -> StandardPanelSemanticInput? {
        guard supportedStates.contains(state) else { return nil }
        return StandardPanelSemanticInput(viewState: viewState(for: state))
    }

    private static func viewState(for state: WorkdayState) -> BusinessViewState {
        let amount: BusinessEarnedAmount
        let earnedDuration: DurationMilliseconds?
        let scheduledProgress: Double?
        let remainingToEnd: DurationMilliseconds?
        let clockInAt: TimestampMilliseconds?
        let clockOutAt: TimestampMilliseconds?
        let recoveryReason: RecoveryReason?
        let canClockIn: Bool
        let canRequestClockOut: Bool
        let canRequestTodayReset: Bool

        switch state {
        case .ready:
            amount = .rounded(try! RoundedEarnedCents(validating: 0))
            earnedDuration = .zero
            scheduledProgress = 0.25
            remainingToEnd = nil
            clockInAt = nil
            clockOutAt = nil
            recoveryReason = nil
            canClockIn = true
            canRequestClockOut = false
            canRequestTodayReset = false
        case .earning:
            amount = .live(try! LiveEarnedMilliYuan(validating: 120_000))
            earnedDuration = duration(5 * 60 * 60 * 1_000 + 15 * 60 * 1_000)
            scheduledProgress = 0.625
            remainingToEnd = duration(3 * 60 * 60 * 1_000 + 45 * 60 * 1_000)
            clockInAt = TimestampMilliseconds(rawValue: 1 * 60 * 60 * 1_000)
            clockOutAt = nil
            recoveryReason = nil
            canClockIn = false
            canRequestClockOut = true
            canRequestTodayReset = false
        case .awaitingClockOut:
            amount = .rounded(try! RoundedEarnedCents(validating: 30_000))
            earnedDuration = duration(8 * 60 * 60 * 1_000)
            scheduledProgress = 1
            remainingToEnd = .zero
            clockInAt = TimestampMilliseconds(rawValue: 1 * 60 * 60 * 1_000)
            clockOutAt = nil
            recoveryReason = nil
            canClockIn = false
            canRequestClockOut = true
            canRequestTodayReset = false
        case .completed:
            amount = .rounded(try! RoundedEarnedCents(validating: 30_000))
            earnedDuration = duration(8 * 60 * 60 * 1_000)
            scheduledProgress = nil
            remainingToEnd = nil
            clockInAt = TimestampMilliseconds(rawValue: 1 * 60 * 60 * 1_000)
            clockOutAt = TimestampMilliseconds(rawValue: 9 * 60 * 60 * 1_000)
            recoveryReason = nil
            canClockIn = false
            canRequestClockOut = false
            canRequestTodayReset = false
        case .recoveryRequired:
            amount = .hidden
            earnedDuration = nil
            scheduledProgress = nil
            remainingToEnd = nil
            clockInAt = nil
            clockOutAt = nil
            recoveryReason = .missingClockIn
            canClockIn = false
            canRequestClockOut = false
            canRequestTodayReset = true
        case .unconfigured, .clockedInWaiting:
            preconditionFailure("Unsupported installation-preview state")
        }

        return BusinessViewState(
            state: state,
            recoveryReason: recoveryReason,
            amount: amount,
            earnedDuration: earnedDuration,
            scheduledProgress: scheduledProgress,
            remainingToStart: nil,
            remainingToEnd: remainingToEnd,
            clockInAt: clockInAt,
            clockOutAt: clockOutAt,
            todayDateKey: "2026-08-21",
            todayTimeZoneIdentifier: "Asia/Shanghai",
            isPreviousWorkday: false,
            clockOutDateKey: state == .completed ? "2026-08-21" : nil,
            canClockIn: canClockIn,
            canRequestClockOut: canRequestClockOut,
            canRequestTodayReset: canRequestTodayReset,
            canRequestStartToday: false,
            canRequestSettingsReset: false,
            previousDayCleanupPending: false
        )
    }

    private static func duration(_ milliseconds: Int64) -> DurationMilliseconds {
        try! DurationMilliseconds(validating: milliseconds)
    }
}

// Native Buttons already participate in keyboard focus. Only the static
// import preview needs an explicit focus opt-out; adding a focusable layer to
// live Buttons can expose that layer instead of the actual AXButton.
private struct PanelPreviewFocusModifier: ViewModifier {
    let interactionsEnabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if interactionsEnabled {
            content
        } else {
            content.focusable(false)
        }
    }
}

private struct StandardPanelSemanticContent: View {
    let input: StandardPanelSemanticInput
    let palette: WarmIslandPalette
    let commandInFlight: Bool
    let interactionsEnabled: Bool
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    let onAction: (Stage5PanelPresentation.Action) -> Void
    @FocusState.Binding var keyboardFocus: Stage5PanelKeyboardFocus?
    @Environment(\.incomePanelTextScale) private var requestedTextScale
    @ScaledMetric(relativeTo: .body) private var nativeTextScale: CGFloat = 1
    private var textScale: CGFloat { min(1.2, max(requestedTextScale, nativeTextScale)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            topBar.fixedPanelFrame("topBar", CGRect(x: 12, y: 8, width: 296, height: 28))
            if input.state == .recoveryRequired {
                recoveryBody.fixedPanelFrame("recovery", CGRect(x: 12, y: 38, width: 296, height: 142))
            } else if input.state == .completed {
                if input.isPreviousWorkday {
                    completedAmountBlock.fixedPanelFrame("amount", CGRect(x: 12, y: 38, width: 296, height: 42))
                    supportBlock.fixedPanelFrame("support", CGRect(x: 12, y: 82, width: 296, height: 42))
                    compactBlessing.fixedPanelFrame("blessing", CGRect(x: 12, y: 126, width: 296, height: 20))
                    actionBlock.fixedPanelFrame("primaryAction", CGRect(x: 12, y: 148, width: 296, height: 32))
                } else {
                    completedAmountBlock.fixedPanelFrame("amount", CGRect(x: 12, y: 38, width: 296, height: 48))
                    supportBlock.fixedPanelFrame("support", CGRect(x: 12, y: 91, width: 228, height: 48))
                    actionBlock.fixedPanelFrame("blessing", CGRect(x: 12, y: 145, width: 296, height: 33))
                }
            } else {
                amountBlock.fixedPanelFrame("amount", CGRect(x: 12, y: 38, width: 296, height: 60))
                supportBlock.fixedPanelFrame("support", CGRect(x: 12, y: 100, width: 228, height: 42))
                actionBlock.fixedPanelFrame("primaryAction", CGRect(x: 12, y: 148, width: 296, height: 32))
            }
        }
        .frame(width: 320, height: 190, alignment: .topLeading)
        .allowsHitTesting(interactionsEnabled)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: input.presentation.symbol)
                    .foregroundStyle(statusColor(input.state))
                Text(input.state == .completed && input.isPreviousWorkday ? "上一工作日已结算" : input.presentation.status)
                    .incomePanelFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .accessibilityLabel(input.presentation.status)
                Spacer(minLength: 0)
            }.frame(width: 232, height: 28).observePanelFrame("status")
            Spacer().frame(width: 8)
            iconButton("gearshape", "打开设置", focus: .settings, action: onOpenSettings)
                .observePanelFrame("settings")
            iconButton("eye.slash", "隐藏收入面板", focus: .hide, action: onHide)
                .observePanelFrame("hide")
        }
    }

    private var completedAmountBlock: some View {
        let labelHeight = 13 * textScale
        let height = (input.isPreviousWorkday ? 42 : 48) - labelHeight
        let formatted = Stage5AmountFormatter.string(for: input.amount) ?? ""
        let size = Stage5AmountFormatter.fontSize(for: formatted, weight: palette.amountFontWeight,
            design: palette.amountFontDesign, textScale: textScale, availableHeight: height)
        return VStack(spacing: 0) {
            Text(input.isPreviousWorkday ? "工作日 \(input.todayDateKey ?? "")" : "今日已获得")
                .incomePanelFont(size: 11).foregroundStyle(palette.secondary)
                .frame(height: labelHeight)
            PanelAmountView(amount: input.amount,
                font: Stage5AmountFormatter.measuredFont(size: size, weight: palette.amountFontWeight, design: palette.amountFontDesign),
                color: NSColor(palette.primary), preset: .resolve(themeID: palette.themeID), height: height)
                .frame(width: 280, height: height).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日已获得")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(Stage5AmountFormatter.accessibilityValue(for: input.amount))
    }

    private var compactBlessing: some View {
        let amount = Stage5AmountFormatter.string(for: input.amount) ?? ""
        return Text(Stage5SettlementBlessing.compact(amount: amount))
            .incomePanelFont(size: 11, weight: .medium).lineLimit(1)
            .accessibilityLabel(Stage5SettlementBlessing.full(amount: amount))
    }

    private var amountBlock: some View {
        let formatted = Stage5AmountFormatter.string(for: input.amount) ?? ""
        let size = Stage5AmountFormatter.fontSize(for: formatted, weight: palette.amountFontWeight,
                                                 design: palette.amountFontDesign, textScale: textScale)
        let amountHeight = Stage5AmountFormatter.amountHeight(textScale: textScale)
        return VStack(spacing: 0) {
            Text("今日已获得")
                .incomePanelFont(size: 11)
                .foregroundStyle(palette.secondary)
                .frame(height: 13 * textScale)
            PanelAmountView(amount: input.amount,
                font: Stage5AmountFormatter.measuredFont(size: size, weight: palette.amountFontWeight, design: palette.amountFontDesign),
                color: NSColor(palette.primary), preset: .resolve(themeID: palette.themeID), height: amountHeight)
                .frame(width: 280, height: amountHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(input.presentation.precisionNote ?? " ")
                .incomePanelFont(size: 10)
                .foregroundStyle(palette.secondary)
                .frame(height: 12 * textScale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日已获得")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(Stage5AmountFormatter.accessibilityValue(for: input.amount))
    }

    private var supportBlock: some View {
        let presentation = input.presentation
        return VStack(spacing: 3) {
            if input.state == .completed, input.hasCrossdayClockOut {
                HStack(spacing: 8) {
                    Text(presentation.supportText).incomePanelFont(size: 10, weight: .medium)
                    Spacer(minLength: 8)
                    Text(input.clockInText).incomePanelFont(size: 10).foregroundStyle(palette.secondary)
                }.lineLimit(1).monospacedDigit()
                Text(input.clockOutText).incomePanelFont(size: 10).foregroundStyle(palette.secondary)
                    .lineLimit(1).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            } else if presentation.progress == nil, presentation.progressLabel.isEmpty {
                Text(presentation.supportText)
                    .lineLimit(1)
                    .monospacedDigit()
                    .incomePanelFont(size: 10, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(presentation.durationText)
                    .lineLimit(1)
                    .monospacedDigit()
                    .incomePanelFont(size: 10)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let progress = presentation.progress {
                HStack {
                    Text("计划工作进度")
                    Spacer()
                    Text(presentation.progressLabel).monospacedDigit()
                }
                .incomePanelFont(size: 10, weight: .medium)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track)
                        Capsule().fill(palette.progressFill)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: palette.metrics.progressHeight)
            } else {
                HStack {
                    Text("计划工作进度")
                    Spacer()
                    Text(presentation.progressLabel)
                }
                .incomePanelFont(size: 10, weight: .medium)
                Capsule().fill(palette.track).frame(height: palette.metrics.progressHeight)
            }
            if !(presentation.progress == nil && presentation.progressLabel.isEmpty) {
                HStack(spacing: 8) {
                    Text(presentation.supportText).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(presentation.durationText).lineLimit(1).monospacedDigit()
                }
                .incomePanelFont(size: 10)
                .foregroundStyle(palette.secondary)
            }
        }
    }

    private var recoveryBody: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .incomePanelFont(size: 23)
                .foregroundStyle(palette.error)
            Text("今日记录无法安全恢复")
                .incomePanelFont(size: 14, weight: .semibold)
            Text("记录不完整或校验失败，暂时无法确定今日收入。")
                .incomePanelFont(size: 11)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重置今日记录") { onAction(.resetToday) }
                .buttonStyle(WarmIslandPrimaryButtonStyle(
                    role: .destructive,
                    palette: palette,
                    focused: keyboardFocus == .primary
                ))
                .modifier(PanelPreviewFocusModifier(interactionsEnabled: interactionsEnabled))
                .focused($keyboardFocus, equals: .primary)
                .frame(height: 32)
        }
    }

    @ViewBuilder private var actionBlock: some View {
        if input.state == .completed, input.isPreviousWorkday, input.settingsRequireRepair {
            Button {} label: {
                HStack(spacing: 8) {
                    Text("开始今天")
                    Spacer(minLength: 0)
                    Text("请先修复设置，再开始今天").incomePanelFont(size: 10)
                }.lineLimit(1)
            }
            .buttonStyle(WarmIslandPrimaryButtonStyle(role: .stop, palette: palette, focused: false))
            .disabled(true)
            .accessibilityLabel("开始今天")
            .accessibilityHint("请先修复设置，再开始今天")
            .help("请先修复设置，再开始今天")
        } else if let title = input.presentation.actionTitle {
            Button { onAction(input.presentation.action) } label: {
                if commandInFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(loadingTitle(input.presentation.action))
                    }
                } else {
                    Text(title)
                }
            }
            .buttonStyle(WarmIslandPrimaryButtonStyle(
                role: actionRole(input.presentation.action, input.presentation.destructive),
                palette: palette,
                focused: keyboardFocus == .primary
            ))
            .disabled(isDisabled(input.presentation.action) || commandInFlight)
            .modifier(PanelPreviewFocusModifier(interactionsEnabled: interactionsEnabled))
            .focused($keyboardFocus, equals: .primary)
        } else if input.state == .completed {
            let amount = Stage5AmountFormatter.string(for: input.amount) ?? "¥0.00"
            Text(Stage5SettlementBlessing.full(amount: amount))
                .incomePanelFont(size: 11, weight: .medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityLabel(Stage5SettlementBlessing.full(amount: amount))
        }
    }

    private func iconButton(
        _ symbol: String,
        _ label: String,
        focus: Stage5PanelKeyboardFocus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).incomePanelFont(size: 13, weight: .medium)
        }
        .buttonStyle(WarmIslandIconButtonStyle(
            palette: palette,
            focused: keyboardFocus == focus
        ))
        .modifier(PanelPreviewFocusModifier(interactionsEnabled: interactionsEnabled))
        .focused($keyboardFocus, equals: focus)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }

    private func statusColor(_ state: WorkdayState) -> Color {
        switch state {
        case .ready, .unconfigured: return palette.statusReady
        case .clockedInWaiting: return palette.statusWaiting
        case .earning: return palette.statusEarning
        case .awaitingClockOut: return palette.statusAwaiting
        case .completed: return palette.statusCompleted
        case .recoveryRequired: return palette.error
        }
    }

    private func actionRole(
        _ action: Stage5PanelPresentation.Action,
        _ destructive: Bool
    ) -> ThemePrimaryActionRole {
        if destructive { return .destructive }
        switch action {
        case .openSettings: return .accent
        case .clockIn: return .start
        case .clockOut, .startToday, .resetToday, .none: return .stop
        }
    }

    private func isDisabled(_ action: Stage5PanelPresentation.Action) -> Bool {
        if case let .clockIn(enabled) = action { return !enabled }
        return false
    }

    private func loadingTitle(_ action: Stage5PanelPresentation.Action) -> String {
        switch action {
        case .startToday: return "正在检查今日设置…"
        case .clockIn, .clockOut, .resetToday: return "正在保存…"
        case .openSettings, .none: return "正在处理…"
        }
    }
}

struct ThemeImportStandardPanelPreview: View {
    let theme: ValidatedTheme
    let renderGroup: ThemeRenderGroup
    let state: WorkdayState
    @FocusState private var keyboardFocus: Stage5PanelKeyboardFocus?

    var body: some View {
        let palette = WarmIslandPalette.make(theme: theme, renderGroup: renderGroup)
        let input = ThemeImportPreviewScenario.renderInput(for: state)
        ZStack {
            palette.background.opacity(palette.backgroundOpacity)
            if let resource = theme.decorationResource(for: state) {
                decorationImage(resource)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        width: ThemePanelLayout.decorationWidth,
                        height: ThemePanelLayout.decorationHeight
                    )
                    .opacity(theme.manifest.metrics.decorationOpacity)
                    .offset(x: 118, y: 22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let input {
                StandardPanelSemanticContent(
                    input: input,
                    palette: palette,
                    commandInFlight: false,
                    interactionsEnabled: false,
                    onOpenSettings: {},
                    onHide: {},
                    onAction: { _ in },
                    keyboardFocus: $keyboardFocus
                )
            }
        }
        .frame(width: 320, height: 190)
        .clipShape(RoundedRectangle(
            cornerRadius: palette.metrics.panelCornerRadius,
            style: .continuous
        ))
        .overlay(RoundedRectangle(cornerRadius: palette.metrics.panelCornerRadius)
            .stroke(palette.border, lineWidth: palette.metrics.borderWidth))
        .foregroundStyle(palette.primary)
        .scaleEffect(0.75, anchor: .topLeading)
        .frame(width: 240, height: 143, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .transaction { transaction in transaction.disablesAnimations = true }
        .environment(\.colorScheme, renderGroup.appearance == .dark ? .dark : .light)
    }

    private func decorationImage(_ resource: String) -> Image {
        if let url = theme.resourceURL(for: resource), let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image(resource, bundle: ThemeResourceBundle.bundle)
    }
}

/// A pulse requests a fresh authoritative projection; it never accumulates money
/// or queues missed frames. PanelController owns visibility in the production path.
@MainActor
final class PanelRenderPulseCoordinator: ObservableObject {
    @Published private(set) var isVisible: Bool
    @Published private(set) var calibrationGeneration = 0
    private var resumePending = true
    private var refreshing = false
    private var lastNativePulseDate: Date?

    init(isVisible: Bool = true) { self.isVisible = isVisible }

    func setVisible(_ visible: Bool) {
        if visible != isVisible {
            lastNativePulseDate = nil
            resumePending = visible
        }
        isVisible = visible
    }

    func pulse(_ store: BusinessStore, nativeDate: Date? = nil) async {
        guard isVisible, !refreshing else { return }
        if let nativeDate {
            // Observable state publication can reevaluate the same timeline frame.
            // Coalesce that frame instead of creating a render/publication loop.
            if let previous = lastNativePulseDate,
               nativeDate.timeIntervalSince(previous) >= 0,
               nativeDate.timeIntervalSince(previous) < 1.0 / 120.0 { return }
            lastNativePulseDate = nativeDate
        }
        refreshing = true
        defer { refreshing = false }
        await store.refresh()
        if resumePending {
            resumePending = false
            calibrationGeneration &+= 1
        }
    }
}

@MainActor
struct IncomePanelView: View {
    struct AccessibilityInputs: Equatable, Sendable {
        let reduceMotion: Bool?
        let reduceTransparency: Bool?

        static let system = Self(reduceMotion: nil, reduceTransparency: nil)
    }

    @ObservedObject var businessStore: BusinessStore
    @ObservedObject private var themeStore: ThemeStore
    @ObservedObject private var keyboardCoordinator: Stage5PanelKeyboardCoordinator
    @ObservedObject private var renderPulse: PanelRenderPulseCoordinator
    let profile: PanelPresentationProfile
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    let accessibilityInputs: AccessibilityInputs
    let layoutObservation: PanelLayoutObservation?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.incomePanelTextScale) private var requestedTextScale
    @ScaledMetric(relativeTo: .body) private var nativeTextScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var keyboardFocus: Stage5PanelKeyboardFocus?
    @State private var countdownTimelineStart = Date()

    init(
        businessStore: BusinessStore,
        themeStore: ThemeStore? = nil,
        profile: PanelPresentationProfile,
        onOpenSettings: @escaping () -> Void,
        onHide: @escaping () -> Void,
        keyboardCoordinator: Stage5PanelKeyboardCoordinator? = nil,
        accessibilityInputs: AccessibilityInputs = .system,
        renderPulse: PanelRenderPulseCoordinator? = nil,
        layoutObservation: PanelLayoutObservation? = nil
    ) {
        self.businessStore = businessStore
        _themeStore = ObservedObject(wrappedValue: themeStore ?? ThemeStore())
        self.profile = profile
        self.onOpenSettings = onOpenSettings
        self.onHide = onHide
        self.accessibilityInputs = accessibilityInputs
        self.layoutObservation = layoutObservation
        _renderPulse = ObservedObject(wrappedValue: renderPulse ?? PanelRenderPulseCoordinator())
        _keyboardCoordinator = ObservedObject(
            wrappedValue: keyboardCoordinator ?? Stage5PanelKeyboardCoordinator()
        )
    }

    private var effectiveReduceMotion: Bool {
        accessibilityInputs.reduceMotion ?? reduceMotion
    }

    private var effectiveReduceTransparency: Bool {
        accessibilityInputs.reduceTransparency ?? reduceTransparency
    }

    var body: some View {
        let theme = themeStore.effectiveTheme(systemIsDark: colorScheme == .dark)
        let renderGroup = ThemeAppearanceResolver.resolve(
            theme: theme,
            preferred: themeStore.preferredAppearance,
            systemIsDark: colorScheme == .dark
        )
        let palette = WarmIslandPalette.make(theme: theme, renderGroup: renderGroup)
        let accessibility = ThemeAccessibilityPolicy.resolve(
            metrics: palette.metrics,
            reduceMotion: effectiveReduceMotion,
            reduceTransparency: effectiveReduceTransparency
        )
        let appearanceTransition = ThemeAppearanceTransitionPolicy.resolve(
            reduceMotion: effectiveReduceMotion,
            reduceTransparency: effectiveReduceTransparency
        )
        ZStack {
            palette.background.opacity(accessibility.usesOpaqueBackground ? 1 : palette.backgroundOpacity)
            if let decoration = decorationResource {
                decorationImage(decoration)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: ThemePanelLayout.decorationWidth, height: ThemePanelLayout.decorationHeight)
                    .opacity(accessibility.decorationOpacity)
                    .observePanelFrame("decoration")
                    .offset(x: 118, y: 22)
                    .allowsHitTesting(ThemePanelLayout.decorationAllowsHitTesting)
                    .accessibilityIdentifier("income-panel-decoration")
                    .accessibilityHidden(true)
            }
            if case let .clockOut(estimate) = businessStore.confirmation {
                clockOutConfirmationContent(estimate, palette)
            } else if let standardState = sharedStandardState {
                StandardPanelSemanticContent(
                    input: StandardPanelSemanticInput(viewState: standardState,
                        settingsRequireRepair: businessStore.settingsReadErrorViewState != nil),
                    palette: palette,
                    commandInFlight: businessStore.isCommandInFlight,
                    interactionsEnabled: true,
                    onOpenSettings: onOpenSettings,
                    onHide: onHide,
                    onAction: perform,
                    keyboardFocus: $keyboardFocus
                )
            } else {
                VStack(spacing: 2) {
                    topBar(palette).frame(height: 28)
                    content(palette).frame(height: 140)
                }.padding(.init(top: 8, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .frame(width: profile.contentSize.width, height: profile.contentSize.height)
        .coordinateSpace(name: "income-panel-layout")
        .environment(\.panelLayoutObservation, layoutObservation)
        .onPreferenceChange(PanelLayoutFramesKey.self) { frames in
            guard let layoutObservation else { return }
            Task { @MainActor in layoutObservation.frames = frames }
        }
        .clipShape(RoundedRectangle(cornerRadius: palette.metrics.panelCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: palette.metrics.panelCornerRadius, style: .continuous)
            .stroke(palette.border, lineWidth: palette.metrics.borderWidth))
        .shadow(
            color: palette.shadowColor.opacity(palette.shadowOpacity),
            radius: palette.shadowBlur,
            x: 0,
            y: palette.shadowY
        )
        .foregroundStyle(palette.primary)
        .overlay(alignment: .top) {
            if !isClockOutConfirmation {
                feedbackOverlay.padding(.top, 34).allowsHitTesting(false)
            }
        }
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                    paused: !renderPulse.isVisible || businessStore.viewState?.state != .earning)) { context in
                Color.clear.task(id: context.date) {
                    guard businessStore.viewState?.state == .earning else { return }
                    await renderPulse.pulse(businessStore, nativeDate: context.date)
                }
            }
            // Waiting/countdown and stop-boundary maintenance needs no animation.
            TimelineView(.periodic(from: countdownTimelineStart, by: 1)) { context in
                Color.clear.task(id: context.date) {
                    guard businessStore.viewState?.state != .earning else { return }
                    await renderPulse.pulse(businessStore, nativeDate: context.date)
                }
            }
        }
        .task(id: renderPulse.isVisible) {
            await renderPulse.pulse(businessStore)
        }
        .task(id: businessStore.feedback) {
            guard isTransientSuccess(businessStore.feedback) else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            businessStore.clearFeedback()
        }
        .onAppear {
            applyKeyboardFocusRequest(keyboardCoordinator.focusRequest, source: "onAppearRequest")
        }
        .onChange(of: keyboardCoordinator.focusRequest) { request in
            applyKeyboardFocusRequest(request, source: "onChangeRequest")
        }
#if DEBUG
        .onChange(of: keyboardFocus) { focus in
            keyboardCoordinator.recordFocusBinding("onChange",
                requested: keyboardCoordinator.semanticFocus, before: "not-observed", actual: focus)
        }
#endif
        .animation(appearanceTransition.swiftUIAnimation, value: renderGroup)
        .transaction { transaction in
            if appearanceTransition.durationMilliseconds == 0 {
                transaction.disablesAnimations = true
            }
        }
        .environment(\.incomePanelAmountMotion,
            renderPulse.isVisible && !effectiveReduceMotion && businessStore.viewState?.state == .earning)
        .environment(\.incomePanelCalibration, renderPulse.calibrationGeneration)
        .preferredColorScheme(themeStore.preferredAppearance.colorScheme)
    }

    private func applyKeyboardFocusRequest(_ request: Stage5PanelKeyboardCoordinator.FocusRequest,
                                           source: String) {
        // Observe the request through SwiftUI's view lifecycle instead of assigning
        // FocusState from a synchronous Published willSet delivery during refresh.
        // A superseded request must never overwrite a later keyboard command.
        guard request == keyboardCoordinator.focusRequest else { return }
#if DEBUG
        let previousFocus = String(describing: keyboardFocus)
#endif
        keyboardFocus = request.target
#if DEBUG
        keyboardCoordinator.recordFocusBinding(source, requested: request.target,
            before: previousFocus, actual: keyboardFocus)
#endif
    }

    private var sharedStandardState: BusinessViewState? {
        guard !businessStore.isRestoring,
              businessStore.confirmation == nil,
              !businessStore.hasBlockingScheduleError,
              let state = businessStore.viewState else {
            return nil
        }
        if let error = businessStore.settingsReadErrorViewState,
           error.isBlocking || !(state.state == .completed && state.isPreviousWorkday) {
            return nil
        }
        return state
    }

    private var decorationResource: String? {
        guard !businessStore.isRestoring,
              !businessStore.isCommandInFlight,
              businessStore.confirmation == nil,
              businessStore.settingsReadErrorViewState?.isBlocking != true,
              let state = businessStore.viewState,
              state.state != .recoveryRequired,
              !(state.state == .completed && state.isPreviousWorkday) else { return nil }
        return themeStore.effectiveTheme(systemIsDark: colorScheme == .dark).decorationResource(for: state.state)
    }

    private func decorationImage(_ resource: String) -> Image {
        if let url = themeStore.effectiveTheme(systemIsDark: colorScheme == .dark).resourceURL(for: resource),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image(resource, bundle: ThemeResourceBundle.bundle)
    }

    @ViewBuilder private func content(_ palette: WarmIslandPalette) -> some View {
        if businessStore.isRestoring {
            blockingMessage("arrow.clockwise", "正在恢复今日记录…", "本地数据读取完成后即可使用", palette)
        } else if businessStore.hasBlockingScheduleError {
            blockingMessage("exclamationmark.triangle.fill", "今日工作时间无法确定", "原设置和记录未修改，请调整时间后重试", palette)
        } else if businessStore.confirmation == .resetSettings {
            confirmationBody(.resetSettings, palette)
        } else if businessStore.settingsReadErrorViewState?.isBlocking == true {
            damagedSettingsBody(palette)
        } else if let confirmation = businessStore.confirmation {
            confirmationBody(confirmation, palette)
        } else if let state = businessStore.viewState {
            stateBody(state, palette)
        } else {
            blockingMessage("exclamationmark.triangle.fill", "无法恢复今日状态", "请打开设置检查本地数据", palette)
        }
    }

    private func topBar(_ palette: WarmIslandPalette) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
            if let state = businessStore.viewState {
                let presentation = Stage5PanelPresentation.make(from: state)
                Image(systemName: presentation.symbol).foregroundStyle(statusColor(state.state, palette))
                Text(presentation.status).incomePanelFont(size: 12, weight: .semibold).lineLimit(1)
            } else {
                Image(systemName: "yensign.circle.fill").foregroundStyle(palette.accent)
                Text("可视收入打卡机").incomePanelFont(size: 12, weight: .semibold)
            }
            Spacer(minLength: 0)
            }.frame(width: 232, height: 28).observePanelFrame("status")
            Spacer().frame(width: 8)
            iconButton("gearshape", "打开设置", focus: .settings, palette: palette, onOpenSettings)
                .observePanelFrame("settings")
            iconButton("eye.slash", "隐藏收入面板", focus: .hide, palette: palette, onHide)
                .observePanelFrame("hide")
        }
    }

    @ViewBuilder private func stateBody(_ state: BusinessViewState, _ palette: WarmIslandPalette) -> some View {
        if state.state == .recoveryRequired {
            recoveryBody(palette)
        } else {
            let p = Stage5PanelPresentation.make(from: state)
            VStack(spacing: 2) {
                if businessStore.settingsReadErrorViewState != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.statusWaiting)
                        Text("设置数据需要修复").lineLimit(1)
                            .foregroundStyle(palette.primary)
                        Spacer()
                        Button("打开设置", action: onOpenSettings)
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.primary)
                    }.incomePanelFont(size: 10, weight: .medium).frame(height: 12)
                }
                amountBlock(state.amount, p.precisionNote, palette)
                    .frame(height: businessStore.settingsReadErrorViewState == nil ? 60 : 46)
                supportBlock(p, palette).frame(height: 42)
                actionButton(p.actionTitle, p.action, p.destructive, palette).frame(height: 32)
            }
        }
    }

    private func amountBlock(_ amount: BusinessEarnedAmount, _ note: String?, _ palette: WarmIslandPalette) -> some View {
        let formatted = Stage5AmountFormatter.string(for: amount) ?? ""
        let scale = min(1.2, max(requestedTextScale, nativeTextScale))
        let size = Stage5AmountFormatter.fontSize(for: formatted, weight: palette.amountFontWeight,
                                                 design: palette.amountFontDesign, textScale: scale)
        let amountHeight = Stage5AmountFormatter.amountHeight(textScale: scale)
        return VStack(spacing: 0) {
            Text("今日已获得").incomePanelFont(size: 11).foregroundStyle(palette.secondary).frame(height: 13 * scale)
            PanelAmountView(amount: amount,
                font: Stage5AmountFormatter.measuredFont(size: size, weight: palette.amountFontWeight, design: palette.amountFontDesign),
                color: NSColor(palette.primary), preset: .resolve(themeID: palette.themeID), height: amountHeight)
                .frame(width: 280, height: amountHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(note ?? " ").incomePanelFont(size: 10).foregroundStyle(palette.secondary).frame(height: 12 * scale)
        }.accessibilityElement(children: .ignore).accessibilityLabel("今日已获得")
        .accessibilityAddTraits(.isStaticText)
            .accessibilityValue(Stage5AmountFormatter.accessibilityValue(for: amount))
    }

    private func supportBlock(_ p: Stage5PanelPresentation, _ palette: WarmIslandPalette) -> some View {
        VStack(spacing: 3) {
            if p.progress == nil, p.progressLabel.isEmpty {
                Text(p.supportText).lineLimit(1).monospacedDigit()
                    .incomePanelFont(size: 10, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(p.durationText).lineLimit(1).monospacedDigit()
                    .incomePanelFont(size: 10)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let progress = p.progress {
                HStack { Text("计划工作进度"); Spacer(); Text(p.progressLabel).monospacedDigit() }
                    .incomePanelFont(size: 10, weight: .medium)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track)
                        Capsule().fill(palette.progressFill).frame(width: proxy.size.width * progress)
                    }
                }.frame(height: palette.metrics.progressHeight)
            } else {
                HStack { Text("计划工作进度"); Spacer(); Text(p.progressLabel) }
                    .incomePanelFont(size: 10, weight: .medium)
                Capsule().fill(palette.track).frame(height: palette.metrics.progressHeight)
            }
            if !(p.progress == nil && p.progressLabel.isEmpty) {
                HStack(spacing: 8) {
                    Text(p.supportText).lineLimit(1); Spacer(minLength: 4)
                    Text(p.durationText).lineLimit(1).monospacedDigit()
                }.incomePanelFont(size: 10).foregroundStyle(palette.secondary)
            }
        }
    }

    private func recoveryBody(_ palette: WarmIslandPalette) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").incomePanelFont(size: 23).foregroundStyle(palette.error)
            Text("今日记录无法安全恢复").incomePanelFont(size: 14, weight: .semibold)
            Text(businessStore.settingsReadErrorViewState == nil ? "记录不完整或校验失败，暂时无法确定今日收入。" : "今日记录需要恢复；设置数据也无法读取。")
                .incomePanelFont(size: 11).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if businessStore.settingsReadErrorViewState != nil {
                    Button("打开设置", action: onOpenSettings)
                        .buttonStyle(WarmIslandSecondaryButtonStyle(palette, focused: false))
                }
                Button("重置今日记录") { send(.requestTodayReset) }
                    .buttonStyle(WarmIslandPrimaryButtonStyle(
                        role: .destructive,
                        palette: palette,
                        focused: keyboardFocus == .primary
                    ))
                    .focused($keyboardFocus, equals: .primary)
            }.frame(height: 32)
        }
    }

    private func damagedSettingsBody(_ palette: WarmIslandPalette) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "externaldrive.badge.exclamationmark").incomePanelFont(size: 23).foregroundStyle(palette.error)
            Text("设置数据无法读取").incomePanelFont(size: 14, weight: .semibold)
            Text("原设置文件未被改写，请在设置中重新填写并确认替换。")
                .incomePanelFont(size: 11).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button("打开设置", action: onOpenSettings)
                    .buttonStyle(WarmIslandSecondaryButtonStyle(palette, focused: false))
                Button("重置设置…") { send(.requestSettingsReset) }
                    .buttonStyle(WarmIslandPrimaryButtonStyle(
                        role: .destructive,
                        palette: palette,
                        focused: keyboardFocus == .primary
                    ))
                    .focused($keyboardFocus, equals: .primary)
            }.frame(height: 32)
        }
    }

    private var isClockOutConfirmation: Bool {
        if case .clockOut = businessStore.confirmation { return true }
        return false
    }

    private var clockOutSaveError: String? {
        guard case let .commandFailed(kind, _) = businessStore.feedback,
              kind == .confirmClockOut || kind == .requestClockOut else { return nil }
        return "下班记录保存失败，请重试"
    }

    private func clockOutConfirmationContent(_ estimate: ClockOutEstimate, _ palette: WarmIslandPalette) -> some View {
        ZStack(alignment: .topLeading) {
            topBar(palette).fixedPanelFrame("topBar", CGRect(x: 12, y: 8, width: 296, height: 28))
            Text("确定现在下班吗？").incomePanelFont(size: 14, weight: .semibold)
                .fixedPanelFrame("confirmationTitle", CGRect(x: 20, y: 46, width: 280, height: 22))
            Text("预计结算 \(Stage5AmountFormatter.string(minorUnits: estimate.roundedEarnedCents.rawValue, fractionDigits: 2))")
                .incomePanelFont(size: 20, weight: .medium).monospacedDigit().lineLimit(1)
                .fixedPanelFrame("confirmationAmount", CGRect(x: 20, y: 72, width: 280, height: 36))
            Text("预计计薪 \(Stage5DurationFormatter.string(estimate.earnedDuration))")
                .incomePanelFont(size: 11).monospacedDigit().foregroundStyle(palette.secondary)
                .fixedPanelFrame("confirmationDuration", CGRect(x: 20, y: 112, width: 280, height: 18))
            Text(clockOutSaveError ?? "确认时将按最新时间重新结算")
                .incomePanelFont(size: 10).foregroundStyle(clockOutSaveError == nil ? palette.secondary : palette.error)
                .fixedPanelFrame("confirmationNotice", CGRect(x: 20, y: 132, width: 280, height: 12))
            Button("取消") { send(.cancelConfirmation) }
                .buttonStyle(WarmIslandSecondaryButtonStyle(palette, focused: keyboardFocus == .cancel))
                .disabled(businessStore.isCommandInFlight)
                .keyboardShortcut(.cancelAction).focused($keyboardFocus, equals: .cancel)
                .fixedPanelFrame("cancel", CGRect(x: 12, y: 148, width: 92, height: 32))
            Button { send(.confirmClockOut) } label: {
                if businessStore.isCommandInFlight {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在保存…") }
                } else { Text("确认下班") }
            }
            .buttonStyle(WarmIslandPrimaryButtonStyle(role: .stop, palette: palette, focused: keyboardFocus == .confirm))
            .disabled(businessStore.isCommandInFlight)
            .accessibilityLabel(businessStore.isCommandInFlight ? "正在保存…" : "确认下班")
            .keyboardShortcut(.defaultAction).focused($keyboardFocus, equals: .confirm)
            .fixedPanelFrame("confirm", CGRect(x: 112, y: 148, width: 196, height: 32))
        }
        .frame(width: profile.contentSize.width, height: profile.contentSize.height, alignment: .topLeading)
    }

    private func confirmationLoadingTitle(_ confirmation: BusinessConfirmation) -> String {
        if confirmation == .startToday {
            if case .saving = businessStore.commandPhase { return "正在开始今天…" }
            return "正在检查今日设置…"
        }
        return "正在保存…"
    }

    private func confirmationBody(_ confirmation: BusinessConfirmation, _ palette: WarmIslandPalette) -> some View {
        let copy = confirmationCopy(confirmation)
        return VStack(spacing: 5) {
            Spacer(minLength: 2)
            Image(systemName: copy.symbol).incomePanelFont(size: 20).foregroundStyle(copy.destructive ? palette.error : palette.accent)
            Text(copy.title).incomePanelFont(size: 14, weight: .semibold)
            Text(copy.detail).incomePanelFont(size: 11).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineLimit(3)
            Spacer(minLength: 2)
            HStack(spacing: 8) {
                Button("取消") { send(.cancelConfirmation) }
                    .buttonStyle(WarmIslandSecondaryButtonStyle(
                        palette,
                        focused: keyboardFocus == .cancel
                    ))
                    .keyboardShortcut(.cancelAction)
                    .disabled(businessStore.isCommandInFlight)
                    .focused($keyboardFocus, equals: .cancel)
                Button { send(copy.command) } label: {
                    if businessStore.isCommandInFlight {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(confirmationLoadingTitle(confirmation)) }
                    } else { Text(copy.confirmTitle) }
                }
                    .buttonStyle(WarmIslandPrimaryButtonStyle(
                        role: copy.destructive ? .destructive : .stop,
                        palette: palette,
                        focused: keyboardFocus == .confirm
                    ))
                    .keyboardShortcut(.defaultAction)
                    .disabled(businessStore.isCommandInFlight)
                    .focused($keyboardFocus, equals: .confirm)
            }.frame(height: 32)
        }
    }

    private func confirmationCopy(_ c: BusinessConfirmation) -> (symbol: String, title: String, detail: String, confirmTitle: String, command: BusinessCommand, destructive: Bool) {
        switch c {
        case let .clockOut(estimate):
            return ("clock.badge.checkmark", "确定现在下班吗？",
                "预计结算 \(Stage5AmountFormatter.string(minorUnits: estimate.roundedEarnedCents.rawValue, fractionDigits: 2)) · 预计计薪 \(Stage5DurationFormatter.string(estimate.earnedDuration))\n确认时将按最新时间重新结算", "确认下班", .confirmClockOut, false)
        case .resetToday:
            return ("trash", "重置今日记录？", "这会删除今天的打卡记录，但保留工资与工作时间设置。此操作无法撤销。", "确认重置", .confirmTodayReset, true)
        case .startToday:
            return ("sunrise", "开始今天？", "开始今天将清除上一工作日结算。首版不保留历史记录。", "清除并开始今天", .confirmStartToday, true)
        case .resetSettings:
            return ("gearshape.2", "重置设置？", "这会将无法读取的设置重置为未配置，不会删除今日记录。", "确认重置", .confirmSettingsReset, true)
        }
    }

    private func blockingMessage(_ symbol: String, _ title: String, _ detail: String, _ palette: WarmIslandPalette) -> some View {
        VStack(spacing: 7) {
            Spacer(minLength: 4); Image(systemName: symbol).incomePanelFont(size: 23).foregroundStyle(palette.statusWaiting)
            Text(title).incomePanelFont(size: 14, weight: .semibold)
            Text(detail).incomePanelFont(size: 11).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineLimit(2)
            Spacer(minLength: 2)
            Button("打开设置", action: onOpenSettings)
                .buttonStyle(WarmIslandPrimaryButtonStyle(
                    role: .accent,
                    palette: palette,
                    focused: keyboardFocus == .primary
                ))
                .focused($keyboardFocus, equals: .primary)
                .frame(height: 32)
        }
    }

    @ViewBuilder private func actionButton(_ title: String?, _ action: Stage5PanelPresentation.Action, _ destructive: Bool, _ palette: WarmIslandPalette) -> some View {
        if let title {
            Button { perform(action) } label: {
                if businessStore.isCommandInFlight {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loadingTitle(action)) }
                } else {
                    Text(title)
                }
            }
                .buttonStyle(WarmIslandPrimaryButtonStyle(
                    role: actionRole(action, destructive),
                    palette: palette,
                    focused: keyboardFocus == .primary
                ))
                .disabled(isDisabled(action) || businessStore.isCommandInFlight)
                .focused($keyboardFocus, equals: .primary)
        } else if businessStore.viewState?.state == .completed {
            let amount = businessStore.viewState.flatMap { Stage5AmountFormatter.string(for: $0.amount) } ?? "¥0.00"
            Text("今日辛苦啦，喜提 \(amount)，今天的努力已经成功变现。")
                .incomePanelFont(size: 11, weight: .medium).multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityLabel("今日辛苦啦，喜提 \(amount)，今天的努力已经成功变现。")
        }
    }

    private func perform(_ action: Stage5PanelPresentation.Action) {
        switch action {
        case .openSettings: onOpenSettings()
        case .clockIn: send(.clockIn)
        case .clockOut: send(.requestClockOut)
        case .startToday: send(.requestStartToday)
        case .resetToday: send(.requestTodayReset)
        case .none: break
        }
    }

    private func send(_ command: BusinessCommand) { Task { _ = await businessStore.send(command, source: .panel) } }

    private func iconButton(
        _ symbol: String,
        _ label: String,
        focus: Stage5PanelKeyboardFocus,
        palette: WarmIslandPalette,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol).incomePanelFont(size: 13, weight: .medium) }
            .buttonStyle(WarmIslandIconButtonStyle(
                palette: palette,
                focused: keyboardFocus == focus
            ))
            .focused($keyboardFocus, equals: focus)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    private func statusColor(_ state: WorkdayState, _ p: WarmIslandPalette) -> Color {
        switch state {
        case .ready, .unconfigured: return p.statusReady
        case .clockedInWaiting: return p.statusWaiting
        case .earning: return p.statusEarning
        case .awaitingClockOut: return p.statusAwaiting
        case .completed: return p.statusCompleted
        case .recoveryRequired: return p.error
        }
    }

    private func actionRole(
        _ action: Stage5PanelPresentation.Action,
        _ destructive: Bool
    ) -> ThemePrimaryActionRole {
        if destructive { return .destructive }
        switch action {
        case .openSettings: return .accent
        case .clockIn: return .start
        case .clockOut, .startToday, .resetToday, .none: return .stop
        }
    }

    private func isDisabled(_ action: Stage5PanelPresentation.Action) -> Bool {
        if case let .clockIn(enabled) = action { return !enabled }
        return false
    }

    @ViewBuilder private var feedbackOverlay: some View {
        if let feedback = businessStore.feedback,
           let presentation = feedbackPresentation(feedback) {
            Label(presentation.text, systemImage: presentation.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .incomePanelFont(size: 10, weight: .semibold)
                .foregroundStyle(presentation.isError ? Color.red : Color.green)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel(presentation.text)
        }
    }

    private func feedbackPresentation(_ feedback: BusinessFeedback) -> (text: String, isError: Bool)? {
        switch feedback {
        // UI §16.4: clock-in/out success is expressed by the state transition.
        // A floating success label here covers the amount heading at 120% text.
        case .clockInSucceeded, .clockOutSucceeded: return nil
        case .todayResetSucceeded: return ("今日记录已重置", false)
        case .todayStarted: return ("已开始今天", false)
        case .settingsResetSucceeded: return ("设置已重置", false)
        case let .commandFailed(kind, _):
            switch kind {
            case .requestClockOut, .confirmClockOut: return ("下班记录保存失败，请重试", true)
            case .confirmStartToday: return ("无法开始今天，上一工作日记录已保留", true)
            case .confirmTodayReset: return ("重置失败，原记录未被删除", true)
            default: return ("操作失败，原数据未改变", true)
            }
        case .previousDayCleanupFailed: return ("无法开始今天，上一工作日记录已保留", true)
        case .restoreFailed: return ("本地记录恢复失败", true)
        case .settingsSaved, .settingsRecoveryRequired: return nil
        }
    }

    private func isTransientSuccess(_ feedback: BusinessFeedback?) -> Bool {
        switch feedback {
        case .clockInSucceeded, .clockOutSucceeded, .todayResetSucceeded, .todayStarted, .settingsResetSucceeded:
            return true
        default: return false
        }
    }

    private func loadingTitle(_ action: Stage5PanelPresentation.Action) -> String {
        switch action {
        case .startToday: return "正在检查今日设置…"
        case .clockIn, .clockOut, .resetToday: return "正在保存…"
        case .openSettings, .none: return "正在处理…"
        }
    }
}

private struct WarmIslandPrimaryButtonStyle: ButtonStyle {
    let role: ThemePrimaryActionRole
    let palette: WarmIslandPalette
    let focused: Bool

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, role: role, palette: palette, focused: focused)
    }

    fileprivate struct Body: View {
        let configuration: ButtonStyle.Configuration
        let role: ThemePrimaryActionRole
        let palette: WarmIslandPalette
        let focused: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        private var controlState: ThemeControlState {
            if !isEnabled { return .disabled }
            if configuration.isPressed { return .pressed }
            if hovered { return .hover }
            return focused ? .focused : .normal
        }

        private var visual: ThemeButtonVisualTokens {
            ThemeButtonStyleResolver.resolve(
                role: role,
                state: controlState,
                tokens: palette.tokens
            ) ?? ThemeButtonVisualTokens(
                background: palette.tokens.raised,
                foreground: palette.tokens.primaryText,
                border: palette.tokens.border,
                focusRing: palette.tokens.focusRing,
                showsFocusRing: focused,
                opacity: 1
            )
        }

        var body: some View {
            configuration.label
                .incomePanelFont(size: 13, weight: .semibold)
                .foregroundStyle(Color(themeHex: visual.foreground))
                .frame(maxWidth: .infinity, minHeight: ThemePanelLayout.primaryActionHeight)
                .background(Color(themeHex: visual.background))
                .overlay(RoundedRectangle(cornerRadius: palette.metrics.buttonCornerRadius)
                    .stroke(Color(themeHex: visual.border), lineWidth: palette.metrics.borderWidth))
                .clipShape(RoundedRectangle(
                    cornerRadius: palette.metrics.buttonCornerRadius,
                    style: .continuous
                ))
                .overlay(RoundedRectangle(cornerRadius: palette.metrics.buttonCornerRadius + 2)
                    .stroke(
                        visual.showsFocusRing ? Color(themeHex: visual.focusRing) : .clear,
                        lineWidth: 2
                    )
                    .padding(-2))
                .opacity(visual.opacity)
                .contentShape(Rectangle())
                .onHover { value in hovered = isEnabled ? value : false }
        }
    }
}

private struct WarmIslandSecondaryButtonStyle: ButtonStyle {
    let palette: WarmIslandPalette
    let focused: Bool
    init(_ palette: WarmIslandPalette, focused: Bool) {
        self.palette = palette
        self.focused = focused
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.incomePanelFont(size: 13, weight: .semibold).foregroundStyle(palette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.raised.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay(RoundedRectangle(cornerRadius: palette.metrics.buttonCornerRadius)
                .stroke(palette.border, lineWidth: palette.metrics.borderWidth))
            .clipShape(RoundedRectangle(cornerRadius: palette.metrics.buttonCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: palette.metrics.buttonCornerRadius + 2)
                .stroke(focused ? palette.focusRing : .clear, lineWidth: 2)
                .padding(-2))
    }
}

private struct WarmIslandIconButtonStyle: ButtonStyle {
    let palette: WarmIslandPalette
    let focused: Bool

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, palette: palette, focused: focused)
    }

    fileprivate struct Body: View {
        let configuration: ButtonStyle.Configuration
        let palette: WarmIslandPalette
        let focused: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(palette.primary)
                .frame(width: 28, height: 28)
                .background(
                    configuration.isPressed ? palette.accentPressed.opacity(0.22) :
                        (hovered ? palette.accentHover.opacity(0.18) : .clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? palette.focusRing : .clear, lineWidth: 2)
                    .padding(-2))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

extension PreferredThemeAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension ThemeAppearanceTransitionPolicy {
    var swiftUIAnimation: Animation? {
        guard usesCrossfade, durationMilliseconds > 0 else { return nil }
        return .linear(duration: Double(durationMilliseconds) / 1_000)
    }
}
