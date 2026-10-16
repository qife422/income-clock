import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import ZIPFoundation

struct ZIPEntrySecurityMetadata: Equatable, Sendable {
    let path: String
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let isDirectory: Bool
    let isExecutable: Bool
}

/// Reads only ZIP central-directory metadata. It complements ZIPFoundation's public
/// entry API so encryption, split archives, methods and executable mode bits are
/// rejected before any attacker-controlled bytes are written.
enum ZIPCentralDirectoryInspector {
    static func inspect(data: Data) throws -> [ZIPEntrySecurityMetadata] {
        guard data.count >= 22, data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw diagnostic(.manifest, "zip.magic", nil, "不是有效的 ZIP 容器", "请选择有效的 .incomeclocktheme 文件")
        }
        guard let eocd = findSignature(0x06054B50, in: data) else {
            throw diagnostic(.manifest, "zip.eocd", nil, "ZIP 中央目录缺失或损坏", "重新导出皮肤包")
        }
        let disk = try u16(data, eocd + 4)
        let centralDisk = try u16(data, eocd + 6)
        let entriesOnDisk = try u16(data, eocd + 8)
        let totalEntries = try u16(data, eocd + 10)
        let centralSize = try u32(data, eocd + 12)
        let centralOffset = try u32(data, eocd + 16)
        let commentLength = try u16(data, eocd + 20)
        guard disk == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
            throw diagnostic(.path, "zip.multivolume", nil, "不支持多卷或分片 ZIP", "使用单一 ZIP 文件重新打包")
        }
        guard totalEntries != .max, centralSize != .max, centralOffset != .max else {
            throw diagnostic(.capacity, "zip.zip64", nil, "首版不接受 ZIP64 容器", "在安全容量上限内重新打包")
        }
        guard eocd + 22 + Int(commentLength) == data.count,
              Int(centralOffset) + Int(centralSize) == eocd else {
            throw diagnostic(.manifest, "zip.bounds", nil, "ZIP 目录边界无效", "重新导出皮肤包")
        }

        var cursor = Int(centralOffset)
        var result: [ZIPEntrySecurityMetadata] = []
        var localRanges: [Range<Int>] = []
        result.reserveCapacity(Int(totalEntries))
        for _ in 0..<totalEntries {
            guard try u32(data, cursor) == 0x02014B50 else {
                throw diagnostic(.manifest, "zip.central", nil, "ZIP 中央目录条目损坏", "重新导出皮肤包")
            }
            let versionMadeBy = try u16(data, cursor + 4)
            let flags = try u16(data, cursor + 8)
            let method = try u16(data, cursor + 10)
            let compressed = try u32(data, cursor + 20)
            let uncompressed = try u32(data, cursor + 24)
            let nameLength = Int(try u16(data, cursor + 28))
            let extraLength = Int(try u16(data, cursor + 30))
            let entryCommentLength = Int(try u16(data, cursor + 32))
            let diskStart = try u16(data, cursor + 34)
            let externalAttributes = try u32(data, cursor + 38)
            let localOffset = Int(try u32(data, cursor + 42))
            let end = cursor + 46 + nameLength + extraLength + entryCommentLength
            guard end <= data.count else {
                throw diagnostic(.manifest, "zip.entryBounds", nil, "ZIP 条目边界无效", "重新导出皮肤包")
            }
            guard flags & 0x0001 == 0 else {
                throw diagnostic(.compatibility, "zip.encrypted", nil, "不接受加密 ZIP", "导出未加密的声明式皮肤包")
            }
            guard method == 0 || method == 8 else {
                throw diagnostic(.compatibility, "zip.method", nil, "压缩方法不受支持", "使用 Store 或 Deflate 压缩")
            }
            guard diskStart == 0 else {
                throw diagnostic(.path, "zip.splitEntry", nil, "条目来自其他 ZIP 分卷", "使用单一 ZIP 文件重新打包")
            }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard !nameData.contains(0), let rawPath = String(data: nameData, encoding: .utf8) else {
                throw diagnostic(.path, "path.utf8", nil, "条目路径不是有效 UTF-8", "使用 UTF-8 文件名重新打包")
            }
            let normalized = try ThemePathPolicy.normalize(rawPath)
            guard try u32(data, localOffset) == 0x04034B50 else {
                throw diagnostic(.manifest, "zip.localHeader", normalized, "本地 ZIP header 缺失", "重新导出皮肤包")
            }
            let localFlags = try u16(data, localOffset + 6)
            let localMethod = try u16(data, localOffset + 8)
            let localCompressed = try u32(data, localOffset + 18)
            let localUncompressed = try u32(data, localOffset + 22)
            let localNameLength = Int(try u16(data, localOffset + 26))
            let localExtraLength = Int(try u16(data, localOffset + 28))
            let localNameStart = localOffset + 30
            let localDataStart = localNameStart + localNameLength + localExtraLength
            let localDataEnd = localDataStart + Int(compressed)
            guard localNameStart >= 0, localDataEnd <= Int(centralOffset),
                  localNameStart + localNameLength <= data.count,
                  data.subdata(in: localNameStart..<localNameStart + localNameLength) == nameData,
                  localFlags == flags, localMethod == method,
                  flags & 0x0008 != 0 || (localCompressed == compressed && localUncompressed == uncompressed) else {
                throw diagnostic(.manifest, "zip.localMismatch", normalized, "本地 header 与中央目录不一致", "重新生成 ZIP")
            }
            let localRange = localOffset..<localDataEnd
            guard !localRanges.contains(where: { $0.overlaps(localRange) }) else {
                throw diagnostic(.path, "zip.overlap", normalized, "ZIP 条目数据范围重叠", "重新生成 ZIP")
            }
            localRanges.append(localRange)
            let hostOS = versionMadeBy >> 8
            let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
            let fileType = mode & 0xF000
            let isDirectory = rawPath.hasSuffix("/") || fileType == 0x4000
            guard !isDirectory || (compressed == 0 && uncompressed == 0) else {
                throw diagnostic(
                    .path, "entry.directoryPayload", normalized,
                    "目录条目不能携带隐藏数据", "移除目录条目中的数据"
                )
            }
            if hostOS == 3 || hostOS == 19 {
                guard fileType == 0 || fileType == 0x8000 || fileType == 0x4000 else {
                    throw diagnostic(.path, "entry.type", normalized, "链接或特殊文件类型被禁止", "仅包含普通文件和目录")
                }
            }
            let executable = !isDirectory && (mode & 0o111) != 0
            if executable {
                throw diagnostic(.path, "entry.executable", normalized, "可执行权限被禁止", "移除执行权限后重新打包")
            }
            // APPNOTE 4.5.7 encodes linked-to paths in UNIX extra fields.
            // A hard link still has regular-file mode, so mode checks alone
            // cannot reject it. Either header may carry the link claim.
            let centralExtraStart = cursor + 46 + nameLength
            try validateUnixLinkExtras(data,
                in: centralExtraStart..<(centralExtraStart + extraLength), path: normalized)
            try validateUnixLinkExtras(data,
                in: (localNameStart + localNameLength)..<localDataStart, path: normalized)
            result.append(.init(
                path: normalized,
                compressedSize: UInt64(compressed),
                uncompressedSize: UInt64(uncompressed),
                isDirectory: isDirectory,
                isExecutable: executable
            ))
            cursor = end
        }
        guard cursor == Int(centralOffset) + Int(centralSize) else {
            throw diagnostic(.manifest, "zip.centralSize", nil, "ZIP 中央目录大小不一致", "重新导出皮肤包")
        }
        return result
    }

    private static func validateUnixLinkExtras(_ data: Data, in region: Range<Int>, path: String) throws {
        guard region.lowerBound >= 0, region.upperBound <= data.count else {
            throw diagnostic(.manifest, "zip.extraBounds", path,
                "ZIP extra 字段范围无效", "重新导出皮肤包")
        }
        var cursor = region.lowerBound
        while cursor < region.upperBound {
            // Subtraction bounds each read before addition; declared field sizes
            // never permit reading another entry, payload, or directory record.
            guard region.upperBound - cursor >= 4 else {
                throw diagnostic(.manifest, "zip.extraBounds", path,
                    "ZIP extra 字段头被截断", "重新导出皮肤包")
            }
            let tag = try u16(data, cursor)
            let size = Int(try u16(data, cursor + 2))
            let payload = cursor + 4
            guard size <= region.upperBound - payload else {
                throw diagnostic(.manifest, "zip.extraBounds", path,
                    "ZIP extra 字段内容被截断", "重新导出皮肤包")
            }
            if tag == 0x000d {
                guard size >= 12 else {
                    throw diagnostic(.manifest, "zip.unixExtra", path,
                        "UNIX extra 缺少完整时间与用户信息", "重新导出皮肤包")
                }
                // The fixed 12 bytes alone are ordinary UNIX metadata. Any
                // variable suffix describes a link/device, not regular file data.
                guard size == 12 else {
                    throw diagnostic(.path, "entry.type", path,
                        "UNIX 链接或设备 extra 字段被禁止", "仅包含普通文件和目录")
                }
            }
            cursor = payload + size
        }
    }

    private static func findSignature(_ signature: UInt32, in data: Data) -> Int? {
        let minimum = max(0, data.count - 65_557)
        guard data.count >= 4 else { return nil }
        var offset = data.count - 4
        while offset >= minimum {
            if (try? u32(data, offset)) == signature { return offset }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw diagnostic(.manifest, "zip.read", nil, "ZIP 结构被截断", "重新导出皮肤包")
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw diagnostic(.manifest, "zip.read", nil, "ZIP 结构被截断", "重新导出皮肤包")
        }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

enum ThemePathPolicy {
    static func normalize(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty, !rawPath.contains("\0") else {
            throw diagnostic(.path, "path.empty", rawPath, "条目路径为空或包含 NUL", "移除该条目")
        }
        let slashes = rawPath.replacingOccurrences(of: "\\", with: "/")
        let nfc = slashes.precomposedStringWithCanonicalMapping
        guard !nfc.hasPrefix("/"), !nfc.hasPrefix("~"),
              nfc.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              !nfc.hasPrefix("//") else {
            throw diagnostic(.path, "path.absolute", rawPath, "绝对路径、Drive 或 UNC 路径被禁止", "只使用包内相对路径")
        }
        let isDirectory = nfc.hasSuffix("/")
        let pathBody = isDirectory ? String(nfc.dropLast()) : nfc
        let components = pathBody.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }),
              !components.contains("."), !components.contains("..") else {
            throw diagnostic(.path, "path.traversal", rawPath, "路径包含空段、. 或 ..", "只使用规范化包内相对路径")
        }
        let normalized = components.map(String.init).joined(separator: "/") + (isDirectory ? "/" : "")
        guard !normalized.isEmpty else {
            throw diagnostic(.path, "path.empty", rawPath, "条目路径为空", "移除该条目")
        }
        return normalized
    }

    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum ThemePackageSchemaValidator {
    private static let topLevelKeys: Set<String> = [
        "schemaVersion", "themeId", "name", "author", "themeVersion", "minimumAppVersion",
        "description", "preview", "appearance", "tokens", "metrics", "resources", "hashes",
        "animationPresets", "sounds", "licenseOrSource", "requiredCapabilities",
        "optionalCapabilities", "panelProfile", "layoutProfile", "visualMask", "extensions"
    ]
    private static let appearanceKeys: Set<String> = ["supportedModes"]
    private static let tokenGroupKeys: Set<String> = ["light", "dark"]
    private static let capabilityKeys: Set<String> = ["name", "version"]
    private static let colorKeys: Set<String> = [
        "background", "backgroundOpacity", "raised", "primaryText", "secondaryText",
        "tertiaryText", "accent", "accentHover", "accentPressed", "start", "stop",
        "actionText", "border", "progressTrack", "progressFill", "statusReady",
        "statusWaiting", "statusEarning", "statusAwaiting", "statusCompleted", "statusError",
        "focusRing", "shadowColor", "shadowY", "shadowBlur", "shadowOpacity"
    ]
    private static let metricKeys: Set<String> = [
        "panelCornerRadius", "buttonCornerRadius", "progressHeight", "borderWidth",
        "decorationOpacity"
    ]

    static func decode(_ data: Data) throws -> ThemePackageManifest {
        guard data.count <= ThemePackageLimits.maximumManifestBytes else {
            throw diagnostic(.capacity, "manifest.size", "manifest.json", "Manifest 超过 256 KiB", "精简 Manifest")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw diagnostic(.manifest, "manifest.json", "manifest.json", "JSON 无法解析", "修正 UTF-8 JSON") }
        guard let root = object as? [String: Any] else {
            throw diagnostic(.manifest, "manifest.root", "manifest.json", "顶层必须是 JSON 对象", "修正 Manifest 结构")
        }
        try rejectUnknown(root, allowed: topLevelKeys, context: "manifest")
        if let appearance = root["appearance"] as? [String: Any] {
            try rejectUnknown(appearance, allowed: appearanceKeys, context: "appearance")
        }
        if let tokens = root["tokens"] as? [String: Any] {
            try rejectUnknown(tokens, allowed: tokenGroupKeys, context: "tokens")
            for group in ["light", "dark"] {
                if let colors = tokens[group] as? [String: Any] {
                    try rejectUnknown(colors, allowed: colorKeys, context: "tokens.\(group)")
                }
            }
        }
        if let metrics = root["metrics"] as? [String: Any] {
            try rejectUnknown(metrics, allowed: metricKeys, context: "metrics")
        }
        for key in ["requiredCapabilities", "optionalCapabilities"] {
            if let capabilities = root[key] as? [[String: Any]] {
                for capability in capabilities {
                    try rejectUnknown(capability, allowed: capabilityKeys, context: key)
                }
            }
        }
        for key in ["panelProfile", "layoutProfile"] {
            if let profile = root[key] as? [String: Any] {
                try rejectUnknown(profile, allowed: ["id", "fallback"], context: key)
            }
        }
        let manifest: ThemePackageManifest
        do { manifest = try JSONDecoder().decode(ThemePackageManifest.self, from: data) }
        catch { throw diagnostic(.manifest, "manifest.types", "manifest.json", "必需字段缺失或类型错误", "按 schema 修正字段") }
        guard manifest.schemaVersion == 1 else {
            throw diagnostic(.compatibility, "schema.version", "schemaVersion", "未知主 schema 版本", "使用 schemaVersion 1")
        }
        guard SemanticVersion(manifest.themeVersion) != nil,
              SemanticVersion(manifest.minimumAppVersion) != nil else {
            throw diagnostic(.manifest, "manifest.version", nil, "版本必须使用 major.minor.patch", "修正版本字段")
        }
        guard manifest.themeId.range(
            of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$", options: .regularExpression
        ) != nil else {
            throw diagnostic(.manifest, "manifest.themeId", "themeId", "Theme ID 格式无效", "使用小写反向域名式 ID")
        }
        guard !manifest.name.isEmpty, !manifest.author.isEmpty, !manifest.description.isEmpty,
              !manifest.licenseOrSource.isEmpty else {
            throw diagnostic(.manifest, "manifest.requiredText", nil, "名称、作者、描述或来源为空", "补全安装前需展示的信息")
        }
        guard !containsRemoteReference(object) else {
            throw diagnostic(.manifest, "manifest.remoteURL", nil, "远程 URL 或网络资源被禁止", "只引用包内本地资源")
        }
        let allowedAnimations: Set<String> = ["none", "odometer", "verticalRoll", "softFade"]
        guard Set(manifest.animationPresets).isSubset(of: allowedAnimations) else {
            throw diagnostic(.compatibility, "animation.preset", "animationPresets", "包含未实现的动画预设", "仅使用应用允许的预设")
        }
        return manifest
    }

    /// Inspect the decoded JSON value rather than its serialized bytes: JSON
    /// writers may escape `/` as `\/`, which must not bypass URL rejection.
    private static func containsRemoteReference(_ value: Any) -> Bool {
        switch value {
        case let text as String:
            return text.range(
                of: #"(?:[a-z][a-z0-9+.-]*://|(?:data|javascript):)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        case let object as [String: Any]:
            return object.contains { key, nested in
                containsRemoteReference(key) || containsRemoteReference(nested)
            }
        case let array as [Any]:
            return array.contains(where: containsRemoteReference)
        default:
            return false
        }
    }

    private static func rejectUnknown(
        _ object: [String: Any], allowed: Set<String>, context: String
    ) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw diagnostic(.manifest, "manifest.unknownField", "\(context).\(unknown)", "未知行为字段被禁止", "移除未知字段")
        }
    }
}

enum ThemeTokenSafetyValidator {
    struct Result: Equatable, Sendable {
        let tokens: ThemePackageTokenGroups
        let metrics: ThemeMetricTokens
        let adjustments: [ThemeSafetyAdjustment]
    }

    static func normalize(
        _ package: ThemePackageManifest
    ) throws -> Result {
        let light = try normalize(
            package.tokens.light,
            fallback: ValidatedTheme.warmIslandFallback.manifest.light,
            group: "light"
        )
        let dark = try normalize(
            package.tokens.dark,
            fallback: ValidatedTheme.warmIslandFallback.manifest.dark,
            group: "dark"
        )
        var adjustments = light.1 + dark.1
        let metrics = normalizeMetrics(package.metrics, adjustments: &adjustments)
        return .init(
            tokens: .init(light: light.0, dark: dark.0),
            metrics: metrics,
            adjustments: adjustments.sorted { $0.token < $1.token }
        )
    }

    private static func normalizeMetrics(
        _ value: ThemeMetricTokens,
        adjustments: inout [ThemeSafetyAdjustment]
    ) -> ThemeMetricTokens {
        func clamped(_ key: String, _ raw: Double, _ range: ClosedRange<Double>) -> Double {
            let effective = min(range.upperBound, max(range.lowerBound, raw))
            if effective != raw {
                adjustments.append(.init(
                    token: "metrics.\(key)", declaredValue: String(raw),
                    effectiveValue: String(effective), reason: "超出标准面板安全范围，已钳制"
                ))
            }
            return effective
        }
        return .init(
            panelCornerRadius: clamped("panelCornerRadius", value.panelCornerRadius, 14...18),
            buttonCornerRadius: clamped("buttonCornerRadius", value.buttonCornerRadius, 7...12),
            progressHeight: clamped("progressHeight", value.progressHeight, 3...6),
            borderWidth: clamped("borderWidth", value.borderWidth, 0...1.5),
            decorationOpacity: clamped("decorationOpacity", value.decorationOpacity, 0...0.9)
        )
    }

    private static func normalize(
        _ value: ThemeColorTokens,
        fallback: ThemeColorTokens,
        group: String
    ) throws -> (ThemeColorTokens, [ThemeSafetyAdjustment]) {
        let all = colors(value)
        guard all.values.allSatisfy({
            $0.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil
        }) else {
            throw diagnostic(.accessibility, "token.color", group, "颜色 Token 格式无效", "使用 #RRGGBB 或 #RRGGBBAA")
        }
        var overrides: [String: String] = [:]
        var adjustments: [ThemeSafetyAdjustment] = []
        func replace(_ key: String, with safe: String, reason: String) {
            guard all[key] != safe else { return }
            overrides[key] = safe
            adjustments.append(.init(
                token: "\(group).\(key)", declaredValue: all[key] ?? "",
                effectiveValue: safe, reason: reason
            ))
        }
        for (key, preferred) in [
            ("primaryText", fallback.primaryText), ("secondaryText", fallback.secondaryText),
            ("tertiaryText", fallback.tertiaryText)
        ] where ThemeContrast.ratio(foreground: all[key]!, background: value.background) < 4.5 {
            guard let safe = ThemeContrast.safeTextColor(
                preferred: preferred, background: value.background, minimum: 4.5
            ) else {
                throw diagnostic(
                    .accessibility, "token.textContrast", "\(group).\(key)",
                    "正文 Token 无法安全替换到 4.5:1", "更换背景或文字颜色"
                )
            }
            replace(key, with: safe, reason: "正文对比度低于 4.5:1，已使用确定性安全文字 Token")
        }
        for (key, preferred) in [
            ("statusReady", fallback.statusReady), ("statusWaiting", fallback.statusWaiting),
            ("statusEarning", fallback.statusEarning), ("statusAwaiting", fallback.statusAwaiting),
            ("statusCompleted", fallback.statusCompleted), ("statusError", fallback.statusError),
            ("progressFill", fallback.progressFill), ("focusRing", fallback.focusRing)
        ] where ThemeContrast.ratio(foreground: all[key]!, background: value.background) < 3 {
            guard let safe = ThemeContrast.safeTextColor(
                preferred: preferred, background: value.background, minimum: 3
            ) else {
                throw diagnostic(
                    .accessibility, "token.visualContrast", "\(group).\(key)",
                    "非文本 Token 无法安全替换到 3:1", "更换背景或强调色"
                )
            }
            replace(key, with: safe, reason: "非文本视觉元素对比度低于 3:1，已使用确定性安全 Token")
        }
        let numeric = normalizedAppearanceMetrics(value, group: group, adjustments: &adjustments)
        var candidate = rebuild(numeric, overrides: overrides)
        let buttonIsUnsafe = ThemePrimaryActionRole.allCases.contains { role in
            ThemeControlState.allCases.contains { state in
                guard let style = ThemeButtonStyleResolver.resolve(role: role, state: state, tokens: candidate) else {
                    return true
                }
                return ThemeContrast.ratio(foreground: style.foreground, background: style.background) < 4.5
            }
        }
        if buttonIsUnsafe {
            for (key, safe) in [
                ("accent", fallback.accent), ("accentHover", fallback.accentHover),
                ("accentPressed", fallback.accentPressed), ("start", fallback.start),
                ("stop", fallback.stop), ("actionText", fallback.actionText)
            ] { replace(key, with: safe, reason: "主按钮状态文字对比度低于 4.5:1") }
            candidate = rebuild(numeric, overrides: overrides)
        }
        let finalButtonIsUnsafe = ThemePrimaryActionRole.allCases.contains { role in
            ThemeControlState.allCases.contains { state in
                guard let style = ThemeButtonStyleResolver.resolve(role: role, state: state, tokens: candidate) else {
                    return true
                }
                return ThemeContrast.ratio(foreground: style.foreground, background: style.background) < 4.5
            }
        }
        guard !finalButtonIsUnsafe else {
            throw diagnostic(
                .accessibility, "token.actionContrast", group,
                "主按钮安全替换后仍低于 4.5:1", "更换按钮或文字颜色"
            )
        }
        return (candidate, adjustments.sorted { $0.token < $1.token })
    }

    private static func normalizedAppearanceMetrics(
        _ value: ThemeColorTokens,
        group: String,
        adjustments: inout [ThemeSafetyAdjustment]
    ) -> ThemeColorTokens {
        func clamped(_ key: String, _ raw: Double, _ range: ClosedRange<Double>) -> Double {
            let effective = min(range.upperBound, max(range.lowerBound, raw))
            if effective != raw {
                adjustments.append(.init(
                    token: "\(group).\(key)", declaredValue: String(raw),
                    effectiveValue: String(effective), reason: "超出安全范围，已钳制"
                ))
            }
            return effective
        }
        return .init(
            background: value.background,
            backgroundOpacity: clamped("backgroundOpacity", value.backgroundOpacity, 0.88...1),
            raised: value.raised, primaryText: value.primaryText,
            secondaryText: value.secondaryText, tertiaryText: value.tertiaryText,
            accent: value.accent, accentHover: value.accentHover,
            accentPressed: value.accentPressed, start: value.start, stop: value.stop,
            actionText: value.actionText, border: value.border,
            progressTrack: value.progressTrack, progressFill: value.progressFill,
            statusReady: value.statusReady, statusWaiting: value.statusWaiting,
            statusEarning: value.statusEarning, statusAwaiting: value.statusAwaiting,
            statusCompleted: value.statusCompleted, statusError: value.statusError,
            focusRing: value.focusRing, shadowColor: value.shadowColor,
            shadowY: clamped("shadowY", value.shadowY, 4...10),
            shadowBlur: clamped("shadowBlur", value.shadowBlur, 12...28),
            shadowOpacity: clamped("shadowOpacity", value.shadowOpacity, 0.12...0.32)
        )
    }

    private static func colors(_ value: ThemeColorTokens) -> [String: String] {
        [
            "background": value.background, "raised": value.raised,
            "primaryText": value.primaryText, "secondaryText": value.secondaryText,
            "tertiaryText": value.tertiaryText, "accent": value.accent,
            "accentHover": value.accentHover, "accentPressed": value.accentPressed,
            "start": value.start, "stop": value.stop, "actionText": value.actionText,
            "border": value.border, "progressTrack": value.progressTrack,
            "progressFill": value.progressFill, "statusReady": value.statusReady,
            "statusWaiting": value.statusWaiting, "statusEarning": value.statusEarning,
            "statusAwaiting": value.statusAwaiting, "statusCompleted": value.statusCompleted,
            "statusError": value.statusError, "focusRing": value.focusRing,
            "shadowColor": value.shadowColor
        ]
    }

    private static func rebuild(
        _ value: ThemeColorTokens, overrides: [String: String]
    ) -> ThemeColorTokens {
        let original = colors(value)
        func color(_ key: String) -> String { overrides[key] ?? original[key]! }
        return .init(
            background: color("background"), backgroundOpacity: value.backgroundOpacity,
            raised: color("raised"), primaryText: color("primaryText"),
            secondaryText: color("secondaryText"), tertiaryText: color("tertiaryText"),
            accent: color("accent"), accentHover: color("accentHover"),
            accentPressed: color("accentPressed"), start: color("start"), stop: color("stop"),
            actionText: color("actionText"), border: color("border"),
            progressTrack: color("progressTrack"), progressFill: color("progressFill"),
            statusReady: color("statusReady"), statusWaiting: color("statusWaiting"),
            statusEarning: color("statusEarning"), statusAwaiting: color("statusAwaiting"),
            statusCompleted: color("statusCompleted"), statusError: color("statusError"),
            focusRing: color("focusRing"), shadowColor: color("shadowColor"),
            shadowY: value.shadowY, shadowBlur: value.shadowBlur, shadowOpacity: value.shadowOpacity
        )
    }
}

func diagnostic(
    _ category: ThemeValidationCategory,
    _ code: String,
    _ item: String?,
    _ reason: String,
    _ suggestion: String
) -> ThemeValidationDiagnostic {
    .init(category: category, code: code, item: item, reason: reason, suggestion: suggestion)
}
