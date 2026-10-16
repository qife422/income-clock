import Foundation

private final class ThemeResourceLocator: NSObject {}

enum ThemeResourceBundle {
    static let bundle = Bundle(for: ThemeResourceLocator.self)
}

enum BuiltinThemeID {
    static let warmIsland = "app.incomeclock.warm-island"
    static let windowCompanion = "app.incomeclock.window-companion"
}

enum ThemeAmountFontDesign: String, Codable, Equatable, Sendable {
    case standard
    case rounded
}

struct ThemeColorTokens: Codable, Equatable, Sendable {
    let background: String
    let backgroundOpacity: Double
    let raised: String
    let primaryText: String
    let secondaryText: String
    let tertiaryText: String
    let accent: String
    let accentHover: String
    let accentPressed: String
    let start: String
    let stop: String
    let actionText: String
    let border: String
    let progressTrack: String
    let progressFill: String
    let statusReady: String
    let statusWaiting: String
    let statusEarning: String
    let statusAwaiting: String
    let statusCompleted: String
    let statusError: String
    let focusRing: String
    let shadowColor: String
    let shadowY: Double
    let shadowBlur: Double
    let shadowOpacity: Double
}

struct ThemeMetricTokens: Codable, Equatable, Sendable {
    let panelCornerRadius: Double
    let buttonCornerRadius: Double
    let progressHeight: Double
    let borderWidth: Double
    let decorationOpacity: Double
}

struct ThemeManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let themeId: String
    let name: String
    let author: String
    let themeVersion: String
    let isDefault: Bool
    let supportedAppearances: [PreferredThemeAppearance]
    let amountFontDesign: ThemeAmountFontDesign
    let amountFontWeight: String
    let metrics: ThemeMetricTokens
    let light: ThemeColorTokens
    let dark: ThemeColorTokens
    let decorations: [String: String]
    let previewResource: String
    let licenseOrSource: String
}

enum ThemeSource: Equatable, Sendable {
    case builtIn
    case installed(root: URL)
}

struct ValidatedTheme: Equatable, Sendable, Identifiable {
    let manifest: ThemeManifest
    let source: ThemeSource
    let sounds: [String: String]

    init(manifest: ThemeManifest, source: ThemeSource = .builtIn, sounds: [String: String] = [:]) {
        self.manifest = manifest
        self.source = source
        self.sounds = sounds
    }

    var id: String { manifest.themeId }
    var name: String { manifest.name }
    var supportsLight: Bool { manifest.supportedAppearances.contains(.light) }
    var supportsDark: Bool { manifest.supportedAppearances.contains(.dark) }
    var isDefault: Bool { manifest.isDefault }
    var isBuiltIn: Bool {
        if case .builtIn = source { return true }
        return false
    }

    func resourceURL(for relativePath: String) -> URL? {
        guard case let .installed(root) = source else { return nil }
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    func colors(dark: Bool) -> ThemeColorTokens {
        dark ? manifest.dark : manifest.light
    }

    func decorationResource(for state: WorkdayState) -> String? {
        let key: String
        switch state {
        case .ready: key = "ready"
        case .clockedInWaiting: key = "clockedInWaiting"
        case .earning: key = "earning"
        case .awaitingClockOut: key = "awaitingClockOut"
        case .completed: key = "completed"
        case .unconfigured, .recoveryRequired: return nil
        }
        return manifest.decorations[key]
    }

    static let warmIslandFallback = ValidatedTheme(manifest: ThemeManifest(
        schemaVersion: 1,
        themeId: BuiltinThemeID.warmIsland,
        name: "暖屿",
        author: "可视收入打卡机",
        themeVersion: "1.0.0",
        isDefault: true,
        supportedAppearances: [.light, .dark],
        amountFontDesign: .standard,
        amountFontWeight: "medium",
        metrics: .init(
            panelCornerRadius: 16,
            buttonCornerRadius: 8,
            progressHeight: 4,
            borderWidth: 1,
            decorationOpacity: 0
        ),
        light: .init(
            background: "#F6F1E7", backgroundOpacity: 0.96, raised: "#FFFDF8",
            primaryText: "#292823", secondaryText: "#66635B", tertiaryText: "#716E66",
            accent: "#748962", accentHover: "#687C58", accentPressed: "#5E714F",
            start: "#A85D43", stop: "#5F754C", actionText: "#FFFFFF",
            border: "#29282324", progressTrack: "#2928231F", progressFill: "#748962",
            statusReady: "#73736D", statusWaiting: "#B68135", statusEarning: "#5F8A58",
            statusAwaiting: "#B97822", statusCompleted: "#5F8A58", statusError: "#B84234",
            focusRing: "#3978D4", shadowColor: "#000000", shadowY: 6,
            shadowBlur: 20, shadowOpacity: 0.18
        ),
        dark: .init(
            background: "#262824", backgroundOpacity: 0.97, raised: "#33352F",
            primaryText: "#F5F1E8", secondaryText: "#C2BDB2", tertiaryText: "#A6A197",
            accent: "#A5B98C", accentHover: "#B3C69B", accentPressed: "#94A97D",
            start: "#D68567", stop: "#94AA7D", actionText: "#171914",
            border: "#FFFFFF29", progressTrack: "#FFFFFF24", progressFill: "#A5B98C",
            statusReady: "#B9B8B1", statusWaiting: "#E0AE5B", statusEarning: "#9DC894",
            statusAwaiting: "#E5AB53", statusCompleted: "#9DC894", statusError: "#F27B69",
            focusRing: "#74A8F5", shadowColor: "#000000", shadowY: 6,
            shadowBlur: 22, shadowOpacity: 0.28
        ),
        decorations: [:],
        previewResource: "warm-island-preview",
        licenseOrSource: "Application built-in original theme"
    ))
}

enum ThemeResolvedAppearance: String, Equatable, Sendable {
    case light
    case dark
}

struct ThemeRenderGroup: Equatable, Sendable {
    let themeID: String
    let appearance: ThemeResolvedAppearance
    let colors: ThemeColorTokens
}

enum ThemeAppearanceResolver {
    static func effectiveTheme(theme: ValidatedTheme, preferred: PreferredThemeAppearance,
                               systemIsDark: Bool) -> ValidatedTheme {
        let wantsDark = preferred == .dark || (preferred == .system && systemIsDark)
        return (wantsDark ? theme.supportsDark : theme.supportsLight) ? theme : .warmIslandFallback
    }

    static func resolve(
        theme: ValidatedTheme,
        preferred: PreferredThemeAppearance,
        systemIsDark: Bool
    ) -> ThemeRenderGroup {
        let appearance: ThemeResolvedAppearance
        switch preferred {
        case .system:
            appearance = systemIsDark ? .dark : .light
        case .light:
            appearance = .light
        case .dark:
            appearance = .dark
        }
        let effective = effectiveTheme(theme: theme, preferred: preferred, systemIsDark: systemIsDark)
        return ThemeRenderGroup(
            themeID: effective.id,
            appearance: appearance,
            colors: effective.colors(dark: appearance == .dark)
        )
    }
}

struct ThemeAppearanceTransitionPolicy: Equatable, Sendable {
    static let standardDurationMilliseconds = 120

    let durationMilliseconds: Int
    let usesCrossfade: Bool
    let usesOpaqueSurfaces: Bool

    static func resolve(reduceMotion: Bool, reduceTransparency: Bool) -> Self {
        let mustSwitchImmediately = reduceMotion || reduceTransparency
        return Self(
            durationMilliseconds: mustSwitchImmediately ? 0 : standardDurationMilliseconds,
            usesCrossfade: !mustSwitchImmediately,
            usesOpaqueSurfaces: reduceTransparency
        )
    }
}

enum ThemeValidationIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema
    case invalidThemeID
    case unreservedBuiltinID
    case incompleteAppearance
    case invalidColor(String)
    case invalidMetric(String)
    case invalidAmountFont
    case missingRequiredDecoration(String)
    case invalidDefaultTheme
    case contractMismatch(String)
    case insufficientContrast(String)

    var description: String {
        switch self {
        case .unsupportedSchema: return "内置皮肤 schema 不受支持"
        case .invalidThemeID: return "内置皮肤 ID 无效"
        case .unreservedBuiltinID: return "内置皮肤未使用保留 ID"
        case .incompleteAppearance: return "内置皮肤未完整支持浅色与深色"
        case let .invalidColor(token): return "颜色 Token 无效：\(token)"
        case let .invalidMetric(token): return "尺寸 Token 超出安全范围：\(token)"
        case .invalidAmountFont: return "金额字体 Token 无效"
        case let .missingRequiredDecoration(state): return "B 皮肤缺少必需状态资源：\(state)"
        case .invalidDefaultTheme: return "默认皮肤声明无效"
        case let .contractMismatch(token): return "内置皮肤与 Approved Contract 不一致：\(token)"
        case let .insufficientContrast(token): return "皮肤对比度不足：\(token)"
        }
    }
}

enum BuiltinThemeValidator {
    static func validate(_ manifest: ThemeManifest) throws -> ValidatedTheme {
        guard manifest.schemaVersion == 1 else { throw ThemeValidationIssue.unsupportedSchema }
        guard isValidThemeID(manifest.themeId) else { throw ThemeValidationIssue.invalidThemeID }
        guard [BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion].contains(manifest.themeId)
        else { throw ThemeValidationIssue.unreservedBuiltinID }
        guard manifest.supportedAppearances.count == 2,
              manifest.supportedAppearances.contains(.light),
              manifest.supportedAppearances.contains(.dark)
        else { throw ThemeValidationIssue.incompleteAppearance }
        guard manifest.isDefault == (manifest.themeId == BuiltinThemeID.warmIsland)
        else { throw ThemeValidationIssue.invalidDefaultTheme }

        try validateAppearance(
            manifest.light,
            name: "light",
            safeFallback: ValidatedTheme.warmIslandFallback.manifest.light
        )
        try validateAppearance(
            manifest.dark,
            name: "dark",
            safeFallback: ValidatedTheme.warmIslandFallback.manifest.dark
        )
        guard (14...18).contains(manifest.metrics.panelCornerRadius) else {
            throw ThemeValidationIssue.invalidMetric("panelCornerRadius")
        }
        guard (7...12).contains(manifest.metrics.buttonCornerRadius) else {
            throw ThemeValidationIssue.invalidMetric("buttonCornerRadius")
        }
        guard (3...6).contains(manifest.metrics.progressHeight) else {
            throw ThemeValidationIssue.invalidMetric("progressHeight")
        }
        guard (0...1.5).contains(manifest.metrics.borderWidth) else {
            throw ThemeValidationIssue.invalidMetric("borderWidth")
        }
        guard (0...0.9).contains(manifest.metrics.decorationOpacity) else {
            throw ThemeValidationIssue.invalidMetric("decorationOpacity")
        }
        guard ["medium", "semibold", "bold"].contains(manifest.amountFontWeight.lowercased())
        else { throw ThemeValidationIssue.invalidAmountFont }

        if manifest.themeId == BuiltinThemeID.windowCompanion {
            for state in ["ready", "clockedInWaiting", "earning", "awaitingClockOut", "completed"] {
                guard manifest.decorations[state]?.isEmpty == false else {
                    throw ThemeValidationIssue.missingRequiredDecoration(state)
                }
            }
        }
        try validateApprovedBuiltinIdentity(manifest)
        return ValidatedTheme(manifest: manifest)
    }

    static func validateUser(_ manifest: ThemeManifest, resourceRoot: URL, sounds: [String: String] = [:]) throws -> ValidatedTheme {
        guard manifest.schemaVersion == 1 else { throw ThemeValidationIssue.unsupportedSchema }
        guard isValidThemeID(manifest.themeId) else { throw ThemeValidationIssue.invalidThemeID }
        guard ![BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion].contains(manifest.themeId)
        else { throw ThemeValidationIssue.unreservedBuiltinID }
        guard manifest.isDefault == false else { throw ThemeValidationIssue.invalidDefaultTheme }
        guard !manifest.supportedAppearances.isEmpty,
              manifest.supportedAppearances.allSatisfy({ $0 == .light || $0 == .dark })
        else { throw ThemeValidationIssue.incompleteAppearance }
        try validateAppearance(
            manifest.light,
            name: "light",
            safeFallback: ValidatedTheme.warmIslandFallback.manifest.light
        )
        try validateAppearance(
            manifest.dark,
            name: "dark",
            safeFallback: ValidatedTheme.warmIslandFallback.manifest.dark
        )
        guard (14...18).contains(manifest.metrics.panelCornerRadius),
              (7...12).contains(manifest.metrics.buttonCornerRadius),
              (3...6).contains(manifest.metrics.progressHeight),
              (0...1.5).contains(manifest.metrics.borderWidth),
              (0...0.9).contains(manifest.metrics.decorationOpacity)
        else { throw ThemeValidationIssue.invalidMetric("userTheme.metrics") }
        guard ["medium", "semibold", "bold"].contains(manifest.amountFontWeight.lowercased())
        else { throw ThemeValidationIssue.invalidAmountFont }
        return ValidatedTheme(manifest: manifest, source: .installed(root: resourceRoot), sounds: sounds)
    }

    private static func isValidThemeID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.range(
            of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$",
            options: .regularExpression
        ) != nil
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil
    }

    private static func colorValues(_ value: ThemeColorTokens) -> [(String, String)] {
        [
            ("background", value.background), ("raised", value.raised),
            ("primaryText", value.primaryText), ("secondaryText", value.secondaryText),
            ("tertiaryText", value.tertiaryText), ("accent", value.accent),
            ("accentHover", value.accentHover), ("accentPressed", value.accentPressed),
            ("start", value.start), ("stop", value.stop), ("actionText", value.actionText),
            ("border", value.border), ("progressTrack", value.progressTrack),
            ("progressFill", value.progressFill), ("statusReady", value.statusReady),
            ("statusWaiting", value.statusWaiting), ("statusEarning", value.statusEarning),
            ("statusAwaiting", value.statusAwaiting), ("statusCompleted", value.statusCompleted),
            ("statusError", value.statusError), ("focusRing", value.focusRing),
            ("shadowColor", value.shadowColor)
        ]
    }

    private static func validateAppearance(
        _ value: ThemeColorTokens,
        name: String,
        safeFallback: ThemeColorTokens
    ) throws {
        for (token, color) in colorValues(value) {
            guard isValidHexColor(color) else {
                throw ThemeValidationIssue.invalidColor("\(name).\(token)")
            }
        }
        guard (0.88...1).contains(value.backgroundOpacity) else {
            throw ThemeValidationIssue.invalidMetric("\(name).backgroundOpacity")
        }
        guard (4...10).contains(value.shadowY) else {
            throw ThemeValidationIssue.invalidMetric("\(name).shadowY")
        }
        guard (12...28).contains(value.shadowBlur) else {
            throw ThemeValidationIssue.invalidMetric("\(name).shadowBlur")
        }
        guard (0.12...0.32).contains(value.shadowOpacity) else {
            throw ThemeValidationIssue.invalidMetric("\(name).shadowOpacity")
        }

        for (token, foreground) in [
            ("primaryText", value.primaryText),
            ("secondaryText", value.secondaryText),
            ("tertiaryText", value.tertiaryText)
        ] {
            guard ThemeContrast.ratio(foreground: foreground, background: value.background) >= 4.5 else {
                throw ThemeValidationIssue.insufficientContrast("\(name).\(token)")
            }
        }
        for (token, foreground) in [
            ("accentHover", value.accentHover),
            ("accentPressed", value.accentPressed),
            ("progressFill", value.progressFill),
            ("focusRing", value.focusRing)
        ] {
            guard ThemeContrast.ratio(foreground: foreground, background: value.background) >= 3 else {
                throw ThemeValidationIssue.insufficientContrast("\(name).\(token)")
            }
        }
        try validateStatusContrast(value, name: name, safeFallback: safeFallback)
        for role in ThemePrimaryActionRole.allCases {
            for state in ThemeControlState.allCases {
                guard let resolved = ThemeButtonStyleResolver.resolve(role: role, state: state, tokens: value),
                      ThemeContrast.ratio(
                        foreground: resolved.foreground,
                        background: resolved.background
                      ) >= 4.5 else {
                    throw ThemeValidationIssue.insufficientContrast("\(name).primaryAction.\(role).\(state)")
                }
            }
        }
    }

    static func validateStatusContrast(
        _ value: ThemeColorTokens,
        name: String,
        safeFallback: ThemeColorTokens
    ) throws {
        for role in ThemeStatusRole.allCases {
            guard let resolved = ThemeStatusStyleResolver.resolve(
                role: role,
                tokens: value,
                safeFallback: safeFallback
            ), ThemeContrast.ratio(
                foreground: resolved.emphasis,
                background: value.background
            ) >= 3, ThemeContrast.ratio(
                foreground: resolved.text,
                background: value.background
            ) >= 4.5 else {
                throw ThemeValidationIssue.insufficientContrast("\(name).status.\(role.rawValue)")
            }
        }
    }

    private static func validateApprovedBuiltinIdentity(_ manifest: ThemeManifest) throws {
        let expected: (name: String, font: ThemeAmountFontDesign, weight: String,
                       metrics: ThemeMetricTokens, light: ThemeColorTokens, dark: ThemeColorTokens)
        if manifest.themeId == BuiltinThemeID.warmIsland {
            let fallback = ValidatedTheme.warmIslandFallback.manifest
            expected = (fallback.name, fallback.amountFontDesign, fallback.amountFontWeight,
                        fallback.metrics, fallback.light, fallback.dark)
        } else {
            expected = (
                "窗边搭子", .rounded, "semibold",
                .init(panelCornerRadius: 18, buttonCornerRadius: 10, progressHeight: 5,
                      borderWidth: 1, decorationOpacity: 0.72),
                approvedWindowCompanionLight,
                approvedWindowCompanionDark
            )
        }
        guard manifest.name == expected.name else { throw ThemeValidationIssue.contractMismatch("name") }
        guard manifest.amountFontDesign == expected.font else {
            throw ThemeValidationIssue.contractMismatch("amountFontDesign")
        }
        guard manifest.amountFontWeight.lowercased() == expected.weight else {
            throw ThemeValidationIssue.contractMismatch("amountFontWeight")
        }
        guard manifest.metrics == expected.metrics else { throw ThemeValidationIssue.contractMismatch("metrics") }
        guard manifest.light == expected.light else { throw ThemeValidationIssue.contractMismatch("light") }
        guard manifest.dark == expected.dark else { throw ThemeValidationIssue.contractMismatch("dark") }
    }

    static let approvedWindowCompanionLight = ThemeColorTokens(
        background: "#F3E8D6", backgroundOpacity: 0.97, raised: "#FFF8EC",
        primaryText: "#302B25", secondaryText: "#6F655A", tertiaryText: "#71675C",
        accent: "#71875A", accentHover: "#667A51", accentPressed: "#5C6F48",
        start: "#A95F45", stop: "#60764D", actionText: "#FFFFFF",
        border: "#6B56352B", progressTrack: "#5C4A3521", progressFill: "#71875A",
        statusReady: "#73736D", statusWaiting: "#B68135", statusEarning: "#5F8A58",
        statusAwaiting: "#B97822", statusCompleted: "#5F8A58", statusError: "#B84234",
        focusRing: "#3978D4", shadowColor: "#4C3825", shadowY: 7,
        shadowBlur: 22, shadowOpacity: 0.18
    )

    static let approvedWindowCompanionDark = ThemeColorTokens(
        background: "#20262A", backgroundOpacity: 0.98, raised: "#2C3337",
        primaryText: "#F6EFE4", secondaryText: "#C8BEB1", tertiaryText: "#AAA094",
        accent: "#A6B985", accentHover: "#B5C695", accentPressed: "#95A974",
        start: "#DE9270", stop: "#A0B57F", actionText: "#171B17",
        border: "#FFFFFF26", progressTrack: "#FFFFFF24", progressFill: "#A6B985",
        statusReady: "#B9B8B1", statusWaiting: "#E0AE5B", statusEarning: "#9DC894",
        statusAwaiting: "#E5AB53", statusCompleted: "#9DC894", statusError: "#F27B69",
        focusRing: "#74A8F5", shadowColor: "#000000", shadowY: 7,
        shadowBlur: 24, shadowOpacity: 0.32
    )
}

enum ThemePrimaryActionRole: String, CaseIterable, Equatable, Sendable {
    case accent
    case start
    case stop
    case destructive
}

enum ThemeControlState: String, CaseIterable, Equatable, Sendable {
    case normal
    case hover
    case pressed
    case focused
    case disabled
}

enum ThemeStatusRole: String, CaseIterable, Equatable, Sendable {
    case ready
    case waiting
    case earning
    case awaiting
    case completed
    case error
}

struct ThemeStatusVisualTokens: Equatable, Sendable {
    let emphasis: String
    let text: String
    let usedSafetyFallback: Bool
}

enum ThemeStatusStyleResolver {
    static func resolve(
        role: ThemeStatusRole,
        tokens: ThemeColorTokens,
        safeFallback: ThemeColorTokens
    ) -> ThemeStatusVisualTokens? {
        guard let text = ThemeContrast.safeTextColor(
            preferred: tokens.primaryText,
            background: tokens.background,
            minimum: 4.5
        ) else { return nil }

        let requested = statusColor(role, in: tokens)
        if ThemeContrast.ratio(foreground: requested, background: tokens.background) >= 3 {
            return ThemeStatusVisualTokens(
                emphasis: requested.uppercased(),
                text: text,
                usedSafetyFallback: false
            )
        }

        // UI 0.5 §12.2: replace unsafe visual emphasis with the matching
        // appearance's A safety tokens. Primary text is the final A safety
        // token because it preserves meaning without inventing a new status hue.
        let candidates = [
            statusColor(role, in: safeFallback),
            safeFallback.primaryText
        ]
        guard let replacement = candidates.first(where: {
            ThemeContrast.ratio(foreground: $0, background: tokens.background) >= 3
        }) else { return nil }
        return ThemeStatusVisualTokens(
            emphasis: replacement.uppercased(),
            text: text,
            usedSafetyFallback: true
        )
    }

    private static func statusColor(_ role: ThemeStatusRole, in tokens: ThemeColorTokens) -> String {
        switch role {
        case .ready: return tokens.statusReady
        case .waiting: return tokens.statusWaiting
        case .earning: return tokens.statusEarning
        case .awaiting: return tokens.statusAwaiting
        case .completed: return tokens.statusCompleted
        case .error: return tokens.statusError
        }
    }
}

struct ThemeButtonVisualTokens: Equatable, Sendable {
    let background: String
    let foreground: String
    let border: String
    let focusRing: String
    let showsFocusRing: Bool
    let opacity: Double
}

enum ThemeContrast {
    static func ratio(foreground: String, background: String) -> Double {
        guard let foreground = rgba(foreground), let background = rgba(background) else { return 0 }
        let opaqueBackground = composite(background, over: RGBA(red: 1, green: 1, blue: 1, alpha: 1))
        let opaqueForeground = composite(foreground, over: opaqueBackground)
        let lighter = max(luminance(opaqueForeground), luminance(opaqueBackground))
        let darker = min(luminance(opaqueForeground), luminance(opaqueBackground))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func safeTextColor(preferred: String, background: String, minimum: Double = 4.5) -> String? {
        if ratio(foreground: preferred, background: background) >= minimum { return preferred.uppercased() }
        let black = "#000000"
        let white = "#FFFFFF"
        let blackRatio = ratio(foreground: black, background: background)
        let whiteRatio = ratio(foreground: white, background: background)
        let candidate = blackRatio >= whiteRatio ? black : white
        return max(blackRatio, whiteRatio) >= minimum ? candidate : nil
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private static func rgba(_ value: String) -> RGBA? {
        let text = String(value.dropFirst())
        guard value.first == "#", text.count == 6 || text.count == 8,
              let raw = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        return RGBA(
            red: Double((raw >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: Double((raw >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: Double((raw >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            alpha: hasAlpha ? Double(raw & 0xff) / 255 : 1
        )
    }

    private static func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
        guard alpha > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        return RGBA(
            red: (foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
            green: (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
            blue: (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
            alpha: alpha
        )
    }

    private static func luminance(_ color: RGBA) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

enum ThemeButtonStyleResolver {
    static func resolve(
        role: ThemePrimaryActionRole,
        state: ThemeControlState,
        tokens: ThemeColorTokens
    ) -> ThemeButtonVisualTokens? {
        let background: String
        let preferredText: String
        if state == .disabled {
            background = tokens.raised
            preferredText = tokens.secondaryText
        } else if role == .destructive {
            background = tokens.statusError
            preferredText = tokens.actionText
        } else {
            switch state {
            case .hover: background = tokens.accentHover
            case .pressed: background = tokens.accentPressed
            case .normal, .focused:
                switch role {
                case .accent: background = tokens.accent
                case .start: background = tokens.start
                case .stop: background = tokens.stop
                case .destructive: background = tokens.statusError
                }
            case .disabled: background = tokens.raised
            }
            preferredText = tokens.actionText
        }
        guard let foreground = ThemeContrast.safeTextColor(
            preferred: preferredText,
            background: background
        ) else { return nil }
        return ThemeButtonVisualTokens(
            background: background,
            foreground: foreground,
            border: tokens.border,
            focusRing: tokens.focusRing,
            showsFocusRing: state == .focused,
            opacity: 1
        )
    }
}

enum ThemePanelLayout {
    static let primaryActionWidth: Double = 296
    static let primaryActionHeight: Double = 32
    static let decorationWidth: Double = 60
    static let decorationHeight: Double = 50
    static let decorationContentInset: Double = 3
    static let decorationAllowsHitTesting = false
}

struct ThemeAccessibilityPolicy: Equatable, Sendable {
    let allowsDecorationMotion: Bool
    let usesOpaqueBackground: Bool
    let decorationOpacity: Double

    static func resolve(
        metrics: ThemeMetricTokens,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) -> Self {
        Self(
            allowsDecorationMotion: !reduceMotion,
            usesOpaqueBackground: reduceTransparency,
            decorationOpacity: reduceTransparency ? min(1, metrics.decorationOpacity + 0.12) : metrics.decorationOpacity
        )
    }
}

struct ThemeCatalogSnapshot: Equatable, Sendable {
    let themes: [ValidatedTheme]
    let diagnostics: [String]
}

protocol ThemeCatalogProviding: Sendable {
    func loadBuiltInThemes() async -> ThemeCatalogSnapshot
}

protocol ThemePreferencesRepository: Sendable {
    func loadThemePreferences() async -> RecordLoadResult<ThemePreferencesRecord>
    func saveThemePreferences(
        _ proposed: ThemePreferencesRecord,
        expectedRevision: RecordRevision?
    ) async throws -> ThemePreferencesRecord
    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) async throws -> ThemePreferencesRecord
}

extension RecordRepositoryActor: ThemePreferencesRepository {}
