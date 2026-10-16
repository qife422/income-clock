import Foundation

enum ThemeImportStage: String, CaseIterable, Equatable, Sendable {
    case copying = "正在复制皮肤包"
    case manifest = "正在检查 Manifest"
    case resources = "正在检查资源"
    case compatibility = "正在检查兼容性"
    case preview = "正在生成预览"
    case committing = "正在安装皮肤"
}

struct ThemeImportProgress: Equatable, Sendable {
    let fileName: String
    let stage: ThemeImportStage
    let fractionCompleted: Double
    let canCancel: Bool
}

enum ThemeValidationCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case manifest = "Manifest"
    case compatibility = "兼容性"
    case path = "路径"
    case media = "媒体"
    case capacity = "容量"
    case accessibility = "无障碍"
    case missingResource = "资源缺失"
}

struct ThemeValidationDiagnostic: Error, Equatable, Sendable, Identifiable {
    let category: ThemeValidationCategory
    let code: String
    let item: String?
    let reason: String
    let suggestion: String

    var id: String { "\(category.rawValue):\(code):\(item ?? "-")" }
}

enum ThemeImportError: Error, Equatable, Sendable {
    case validation([ThemeValidationDiagnostic])
    case cancelled
    case sourceAccessDenied
    case stagingFailed
    case installFailed
    case deleteFailed
    case preferencesFailed
    case candidateExpired

    var diagnostics: [ThemeValidationDiagnostic] {
        guard case let .validation(items) = self else { return [] }
        return items
    }
}

struct ThemeSafetyAdjustment: Codable, Equatable, Sendable, Identifiable {
    let token: String
    let declaredValue: String
    let effectiveValue: String
    let reason: String

    var id: String { token }
}

struct ThemePackageAppearance: Codable, Equatable, Sendable {
    let supportedModes: [PreferredThemeAppearance]
}

struct ThemePackageTokenGroups: Codable, Equatable, Sendable {
    let light: ThemeColorTokens
    let dark: ThemeColorTokens
}

struct ThemeCapabilityDeclaration: Codable, Equatable, Sendable {
    let name: String
    let version: Int
}

indirect enum ThemeExtensionValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: ThemeExtensionValue])
    case array([ThemeExtensionValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: ThemeExtensionValue].self) { self = .object(value) }
        else if let value = try? container.decode([ThemeExtensionValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid extension value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Strict, declarative on-disk schema for user supplied `.incomeclocktheme` packages.
/// Unknown top-level and nested behavior fields are rejected before decoding.
struct ThemePackageManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let themeId: String
    let name: String
    let author: String
    let themeVersion: String
    let minimumAppVersion: String
    let description: String
    let preview: String
    let appearance: ThemePackageAppearance
    let tokens: ThemePackageTokenGroups
    let metrics: ThemeMetricTokens
    let resources: [String: String]
    let hashes: [String: String]
    let animationPresets: [String]
    let sounds: [String: String]?
    let licenseOrSource: String
    let requiredCapabilities: [ThemeCapabilityDeclaration]?
    let optionalCapabilities: [ThemeCapabilityDeclaration]?
    let panelProfile: ThemeProfileReference?
    let layoutProfile: ThemeProfileReference?
    let visualMask: String?
    let extensions: [String: ThemeExtensionValue]?

    var referencedPaths: Set<String> {
        var paths = Set(resources.values)
        paths.insert(preview)
        if let visualMask { paths.insert(visualMask) }
        sounds?.values.forEach { paths.insert($0) }
        return paths
    }
}

struct DisabledInstalledTheme: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let reason: String
}

struct ThemeRepositorySnapshot: Equatable, Sendable {
    let themes: [ValidatedTheme]
    let disabledThemes: [DisabledInstalledTheme]

    static let empty = ThemeRepositorySnapshot(themes: [], disabledThemes: [])
}

enum ThemeInstallDisposition: Equatable, Sendable {
    case firstInstall
    case reinstall
    case upgrade(from: String)
}

struct ThemeImportCandidate: Equatable, Sendable, Identifiable {
    let id: UUID
    let manifest: ThemePackageManifest
    let validatedTheme: ValidatedTheme
    let disposition: ThemeInstallDisposition
    let safetyAdjustments: [ThemeSafetyAdjustment]
    let ignoredOptionalCapabilities: [ThemeCapabilityDeclaration]

    var lightPreview: ThemeRenderGroup {
        ThemeAppearanceResolver.resolve(theme: validatedTheme, preferred: .light, systemIsDark: false)
    }

    var darkPreview: ThemeRenderGroup {
        ThemeAppearanceResolver.resolve(theme: validatedTheme, preferred: .dark, systemIsDark: true)
    }
}

struct InstalledThemeRecord: Codable, Equatable, Sendable {
    let themeId: String
    let themeVersion: String
    let author: String
    let manifestSHA256: String
    let installedAtMs: Int64
}

enum ThemePackageLimits {
    static let maximumArchiveBytes: UInt64 = 50 * 1_024 * 1_024
    static let maximumEntries = 256
    static let maximumDecodedBytes: UInt64 = 100 * 1_024 * 1_024
    static let maximumFileBytes: UInt64 = 20 * 1_024 * 1_024
    static let maximumManifestBytes: UInt64 = 256 * 1_024
    static let maximumImageDimension = 4_096
    static let maximumImagePixels = 16_000_000
    static let maximumSoundBytes: UInt64 = 10 * 1_024 * 1_024
    static let maximumSoundDuration: Double = 30
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ source: String) {
        let core = source.split(separator: "+", maxSplits: 1)[0]
            .split(separator: "-", maxSplits: 1)[0]
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let major = Int(pieces[0]), let minor = Int(pieces[1]), let patch = Int(pieces[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// Legacy strings remain wire-compatible. Reserved Profile fields can explicitly
// declare their standard fallback without granting packages layout execution.
struct ThemeProfileReference: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    let id: String
    let fallback: String?
    init(stringLiteral value: String) { id = value; fallback = nil }
    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = value; fallback = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            fallback = try container.decodeIfPresent(String.self, forKey: .fallback)
        }
    }
    func encode(to encoder: Encoder) throws {
        if let fallback {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(fallback, forKey: .fallback)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(id)
        }
    }
    private enum CodingKeys: String, CodingKey { case id, fallback }
}
