import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ZIPFoundation

protocol ThemeRepositoryProviding: Sendable {
    func loadInstalledThemes() async -> ThemeRepositorySnapshot
    func validatePackage(
        at sourceURL: URL,
        progress: @escaping @Sendable (ThemeImportProgress) -> Void
    ) async throws -> ThemeImportCandidate
    func install(_ candidate: ThemeImportCandidate) async throws -> ValidatedTheme
    func discard(_ candidate: ThemeImportCandidate) async
    func deleteTheme(id: String) async throws
}

struct UnavailableThemeRepository: ThemeRepositoryProviding {
    func loadInstalledThemes() async -> ThemeRepositorySnapshot { .empty }
    func validatePackage(
        at sourceURL: URL,
        progress: @escaping @Sendable (ThemeImportProgress) -> Void
    ) async throws -> ThemeImportCandidate { throw ThemeImportError.stagingFailed }
    func install(_ candidate: ThemeImportCandidate) async throws -> ValidatedTheme {
        throw ThemeImportError.installFailed
    }
    func discard(_ candidate: ThemeImportCandidate) async {}
    func deleteTheme(id: String) async throws { throw ThemeImportError.deleteFailed }
}

protocol ThemeAtomicCommitting: Sendable {
    func installDirectory(at stagedURL: URL, replacing targetURL: URL) throws
    func deleteDirectory(at targetURL: URL) throws
}

struct POSIXThemeAtomicCommitter: ThemeAtomicCommitting {
    func installDirectory(at stagedURL: URL, replacing targetURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetURL.path) {
            do {
                _ = try fileManager.replaceItemAt(
                    targetURL,
                    withItemAt: stagedURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } catch {
                throw ThemeImportError.installFailed
            }
        } else if rename(stagedURL.path, targetURL.path) != 0 {
            throw ThemeImportError.installFailed
        }
    }

    func deleteDirectory(at targetURL: URL) throws {
        do { try FileManager.default.removeItem(at: targetURL) }
        catch { throw ThemeImportError.deleteFailed }
    }
}

private struct InstalledThemeMetadata: Codable {
    let normalizedManifest: ThemeManifest
    let packageManifest: ThemePackageManifest
    let record: InstalledThemeRecord
}

private struct StagedThemeCandidate {
    let root: URL
    let payload: URL
    let metadata: InstalledThemeMetadata
}

actor ThemeRepositoryActor: ThemeRepositoryProviding {
    private let rootURL: URL
    private let themesURL: URL
    private let stagingURL: URL
    private let currentAppVersion: SemanticVersion
    private let committer: any ThemeAtomicCommitting
    private let fileManager = FileManager.default
    private var candidates: [UUID: StagedThemeCandidate] = [:]

    init(
        applicationSupportRoot: URL,
        currentAppVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0",
        committer: any ThemeAtomicCommitting = POSIXThemeAtomicCommitter()
    ) {
        rootURL = applicationSupportRoot
        themesURL = applicationSupportRoot.appendingPathComponent("Themes", isDirectory: true)
        stagingURL = applicationSupportRoot.appendingPathComponent("Staging", isDirectory: true)
        self.currentAppVersion = SemanticVersion(currentAppVersion) ?? SemanticVersion("0.1.0")!
        self.committer = committer
        try? fileManager.createDirectory(
            at: themesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.createDirectory(
            at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if let stale = try? fileManager.contentsOfDirectory(
            at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for url in stale where url.lastPathComponent.hasPrefix("import-") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func loadInstalledThemes() async -> ThemeRepositorySnapshot {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: themesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }
        var themes: [ValidatedTheme] = []
        var disabledThemes: [DisabledInstalledTheme] = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let metadata = try decodeInstalledMetadata(in: directory)
                guard metadata.record.themeId == metadata.normalizedManifest.themeId,
                      metadata.record.author == metadata.normalizedManifest.author,
                      metadata.record.themeVersion == metadata.normalizedManifest.themeVersion,
                      metadata.record.manifestSHA256 == sha256(
                        try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
                      ) else { throw ThemeImportError.stagingFailed }
                // Re-read the original strict manifest on every startup. Installed
                // metadata is an identity receipt, not permanent compatibility approval.
                let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
                var manifest = try ThemePackageSchemaValidator.decode(data)
                try validateCompatibility(manifest)
                guard manifest.themeId == metadata.record.themeId,
                      manifest.author == metadata.record.author,
                      manifest.themeVersion == metadata.record.themeVersion,
                      Set(try manifest.hashes.keys.map(ThemePathPolicy.normalize)) ==
                        Set(try manifest.referencedPaths.map(ThemePathPolicy.normalize)) else {
                    throw ThemeImportError.stagingFailed
                }
                let expectedFiles = Set(try manifest.referencedPaths.map(ThemePathPolicy.normalize)).union(["manifest.json"])
                try verifyStaging(directory, expected: expectedFiles)
                try validateReferences(manifest, entries: expectedFiles.map {
                    ZIPEntrySecurityMetadata(path: $0, compressedSize: 0, uncompressedSize: 0,
                        isDirectory: false, isExecutable: false)
                })
                try verifyInstalledHashes(manifest, root: directory)
                try validateMedia(manifest, root: directory)
                let safety = try ThemeTokenSafetyValidator.normalize(manifest)
                manifest = replacingSafetyValues(in: manifest, tokens: safety.tokens, metrics: safety.metrics)
                let theme = try BuiltinThemeValidator.validateUser(
                    makeRuntimeManifest(manifest), resourceRoot: directory, sounds: manifest.sounds ?? [:]
                )
                themes.append(theme)
            } catch {
                disabledThemes.append(.init(
                    id: directory.lastPathComponent,
                    displayName: directory.lastPathComponent,
                    reason: (error as? ThemeValidationDiagnostic).map {
                        "\($0.item ?? "manifest.json"): \($0.reason)"
                    } ?? "完整性、兼容性或资源验证失败"
                ))
            }
        }
        return .init(
            themes: themes,
            disabledThemes: disabledThemes.sorted { $0.id < $1.id }
        )
    }

    func validatePackage(
        at sourceURL: URL,
        progress: @escaping @Sendable (ThemeImportProgress) -> Void
    ) async throws -> ThemeImportCandidate {
        let fileName = sourceURL.lastPathComponent
        guard sourceURL.pathExtension.lowercased() == "incomeclocktheme" else {
            throw ThemeImportError.validation([
                diagnostic(.manifest, "file.extension", fileName, "文件扩展名不受支持", "选择 .incomeclocktheme 文件")
            ])
        }
        let candidateID = UUID()
        let candidateRoot = stagingURL.appendingPathComponent("import-\(candidateID.uuidString)", isDirectory: true)
        let archiveURL = candidateRoot.appendingPathComponent("package.incomeclocktheme")
        let payloadURL = candidateRoot.appendingPathComponent("payload", isDirectory: true)
        var preserveStaging = false
        defer {
            if !preserveStaging { try? fileManager.removeItem(at: candidateRoot) }
        }

        do {
            try Task.checkCancellation()
            progress(.init(fileName: fileName, stage: .copying, fractionCompleted: 0.02, canCancel: true))
            let sourceValues = try sourceURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
                throw diagnostic(.manifest, "file.regular", fileName, "请选择普通文件", "不要选择目录或链接")
            }
            let archiveBytes = UInt64(sourceValues.fileSize ?? 0)
            guard archiveBytes > 0, archiveBytes <= ThemePackageLimits.maximumArchiveBytes else {
                throw diagnostic(.capacity, "archive.size", fileName, "压缩包超过 50 MiB 或为空", "减小皮肤包")
            }
            try fileManager.createDirectory(
                at: candidateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let securityAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if securityAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                throw ThemeImportError.sourceAccessDenied
            }
            try fileManager.copyItem(at: sourceURL, to: archiveURL)
            let copiedValues = try archiveURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            let copiedBytes = UInt64(copiedValues.fileSize ?? 0)
            guard copiedValues.isRegularFile == true, copiedBytes > 0,
                  copiedBytes <= ThemePackageLimits.maximumArchiveBytes else {
                throw diagnostic(
                    .capacity, "archive.copiedSize", fileName,
                    "复制后的压缩包超过 50 MiB 或已发生变化", "重新选择稳定且在上限内的皮肤包"
                )
            }
            try Task.checkCancellation()
            progress(.init(fileName: fileName, stage: .manifest, fractionCompleted: 0.12, canCancel: true))

            let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            let securityEntries = try ZIPCentralDirectoryInspector.inspect(data: archiveData)
            guard securityEntries.count <= ThemePackageLimits.maximumEntries else {
                throw diagnostic(.capacity, "entry.count", nil, "条目数超过 256", "精简资源")
            }
            try validateEntryInventory(securityEntries)
            let archive: Archive
            do {
                archive = try Archive(url: archiveURL, accessMode: .read)
            } catch {
                throw diagnostic(.manifest, "zip.open", nil, "ZIP 无法读取", "重新导出皮肤包")
            }
            let archiveEntries = Array(archive)
            guard archiveEntries.count == securityEntries.count else {
                throw diagnostic(.manifest, "zip.enumeration", nil, "ZIP 条目枚举不完整", "重新导出皮肤包")
            }
            let pairedEntries = try pair(archiveEntries, with: securityEntries)
            guard let manifestEntry = pairedEntries.first(where: { $0.1.path == "manifest.json" && !$0.1.isDirectory }) else {
                throw diagnostic(.missingResource, "manifest.missing", "manifest.json", "缺少必需 Manifest", "在包根目录加入 manifest.json")
            }
            let manifestData = try readEntry(
                manifestEntry.0, from: archive, limit: ThemePackageLimits.maximumManifestBytes
            )
            var packageManifest = try ThemePackageSchemaValidator.decode(manifestData)
            try validateCompatibility(packageManifest)
            let ignoredCapabilities = try ignoredOptionalCapabilities(packageManifest)
            try validateReferences(packageManifest, entries: securityEntries)
            let normalized = try ThemeTokenSafetyValidator.normalize(packageManifest)
            packageManifest = replacingSafetyValues(
                in: packageManifest, tokens: normalized.tokens, metrics: normalized.metrics
            )

            progress(.init(fileName: fileName, stage: .resources, fractionCompleted: 0.28, canCancel: true))
            try fileManager.createDirectory(
                at: payloadURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            var actualTotal: UInt64 = 0
            var hashes: [String: String] = [:]
            for (index, pair) in pairedEntries.enumerated() {
                try Task.checkCancellation()
                let entry = pair.0
                let metadata = pair.1
                guard !metadata.isDirectory else {
                    try createDirectory(for: metadata.path, under: payloadURL)
                    continue
                }
                let limit = metadata.path == "manifest.json"
                    ? ThemePackageLimits.maximumManifestBytes
                    : ThemePackageLimits.maximumFileBytes
                let result = try extract(
                    entry, metadata: metadata, archive: archive, payloadRoot: payloadURL,
                    fileLimit: limit, runningTotal: &actualTotal
                )
                hashes[metadata.path] = result
                let completed = 0.28 + (Double(index + 1) / Double(max(1, pairedEntries.count))) * 0.38
                progress(.init(fileName: fileName, stage: .resources, fractionCompleted: completed, canCancel: true))
            }
            guard actualTotal <= ThemePackageLimits.maximumDecodedBytes else {
                throw diagnostic(.capacity, "decoded.total", nil, "实际解码总量超过 100 MiB", "减小资源")
            }
            try verifyStaging(payloadURL, expected: Set(securityEntries.map(\.path)))
            try verifyDeclaredHashes(packageManifest, actual: hashes)
            try validateMedia(packageManifest, root: payloadURL)

            progress(.init(fileName: fileName, stage: .compatibility, fractionCompleted: 0.78, canCancel: true))
            let runtimeManifest = makeRuntimeManifest(packageManifest)
            let validatedTheme = try BuiltinThemeValidator.validateUser(
                runtimeManifest, resourceRoot: payloadURL, sounds: packageManifest.sounds ?? [:]
            )
            let disposition = try installDisposition(for: packageManifest)
            let installedRecord = InstalledThemeRecord(
                themeId: packageManifest.themeId,
                themeVersion: packageManifest.themeVersion,
                author: packageManifest.author,
                manifestSHA256: sha256(manifestData),
                installedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            )
            let metadata = InstalledThemeMetadata(
                normalizedManifest: runtimeManifest,
                packageManifest: packageManifest,
                record: installedRecord
            )
            try writeMetadata(metadata, to: payloadURL)
            try Task.checkCancellation()
            progress(.init(fileName: fileName, stage: .preview, fractionCompleted: 1, canCancel: true))
            let candidate = ThemeImportCandidate(
                id: candidateID,
                manifest: packageManifest,
                validatedTheme: validatedTheme,
                disposition: disposition,
                safetyAdjustments: normalized.adjustments,
                ignoredOptionalCapabilities: ignoredCapabilities
            )
            candidates[candidateID] = .init(root: candidateRoot, payload: payloadURL, metadata: metadata)
            preserveStaging = true
            return candidate
        } catch is CancellationError {
            throw ThemeImportError.cancelled
        } catch let error as ThemeValidationDiagnostic {
            throw ThemeImportError.validation([error])
        } catch let error as ThemeValidationIssue {
            throw ThemeImportError.validation([
                diagnostic(
                    .accessibility, "token.postNormalization", nil,
                    "规范化后的主题仍未通过运行时安全验证：\(error)",
                    "调整背景、文字、状态或控件颜色后重新导入"
                )
            ])
        } catch let error as ThemeImportError {
            throw error
        } catch {
            throw ThemeImportError.stagingFailed
        }
    }

    func install(_ candidate: ThemeImportCandidate) async throws -> ValidatedTheme {
        guard let staged = candidates.removeValue(forKey: candidate.id),
              staged.metadata.packageManifest == candidate.manifest else {
            throw ThemeImportError.candidateExpired
        }
        let target = themesURL.appendingPathComponent(candidate.manifest.themeId, isDirectory: true)
        do {
            try Task.checkCancellation()
            try committer.installDirectory(at: staged.payload, replacing: target)
            try? fileManager.removeItem(at: staged.root)
            return try BuiltinThemeValidator.validateUser(
                staged.metadata.normalizedManifest, resourceRoot: target, sounds: candidate.manifest.sounds ?? [:]
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: staged.root)
            throw ThemeImportError.cancelled
        } catch {
            try? fileManager.removeItem(at: staged.root)
            throw ThemeImportError.installFailed
        }
    }

    func discard(_ candidate: ThemeImportCandidate) async {
        guard let staged = candidates.removeValue(forKey: candidate.id) else { return }
        try? fileManager.removeItem(at: staged.root)
    }

    func deleteTheme(id: String) async throws {
        guard id != BuiltinThemeID.warmIsland, id != BuiltinThemeID.windowCompanion,
              id.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw ThemeImportError.deleteFailed
        }
        let target = themesURL.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try committer.deleteDirectory(at: target)
    }

    private func validateEntryInventory(_ entries: [ZIPEntrySecurityMetadata]) throws {
        var collisionKeys = Set<String>()
        var pathKinds: [String: Bool] = [:]
        var declaredTotal: UInt64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let key = ThemePathPolicy.collisionKey(entry.path)
            guard collisionKeys.insert(key).inserted else {
                throw diagnostic(.path, "path.duplicate", entry.path, "规范化后出现重复条目", "删除重复路径")
            }
            let body = entry.isDirectory ? String(entry.path.dropLast()) : entry.path
            let bodyKey = ThemePathPolicy.collisionKey(body)
            guard pathKinds[bodyKey] == nil else {
                throw diagnostic(
                    .path, "path.fileDirectoryConflict", entry.path,
                    "同一路径同时声明为文件和目录", "保留唯一的文件或目录条目"
                )
            }
            pathKinds[bodyKey] = entry.isDirectory
            guard entry.uncompressedSize <= ThemePackageLimits.maximumFileBytes else {
                throw diagnostic(.capacity, "entry.size", entry.path, "声明解压大小超过单文件 20 MiB", "减小该文件")
            }
            let next = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
            guard !next.overflow, next.partialValue <= ThemePackageLimits.maximumDecodedBytes else {
                throw diagnostic(.capacity, "decoded.declared", nil, "声明解压总量超过 100 MiB", "精简资源")
            }
            declaredTotal = next.partialValue
        }
        for (body, _) in pathKinds {
            let components = body.split(separator: "/")
            guard components.count > 1 else { continue }
            for end in 1..<components.count {
                let ancestor = components[..<end].joined(separator: "/")
                if pathKinds[ancestor] == false {
                    throw diagnostic(
                        .path, "path.fileAncestor", body,
                        "文件路径被同时用作子条目的父目录", "移除冲突的文件或子条目"
                    )
                }
            }
        }
        // Capacity accounting is deterministic: structural and declared byte
        // ceilings win before the per-entry compression-ratio heuristic.
        for entry in entries {
            if entry.compressedSize > 0, entry.uncompressedSize / max(1, entry.compressedSize) > 1_000 {
                throw diagnostic(.capacity, "archive.ratio", entry.path, "压缩比异常，疑似压缩炸弹", "使用正常压缩比重新导出")
            }
        }
    }

    private func pair(
        _ entries: [Entry], with metadata: [ZIPEntrySecurityMetadata]
    ) throws -> [(Entry, ZIPEntrySecurityMetadata)] {
        var byKey: [String: ZIPEntrySecurityMetadata] = [:]
        for item in metadata { byKey[ThemePathPolicy.collisionKey(item.path)] = item }
        return try entries.map { entry in
            guard entry.type != .symlink else {
                throw diagnostic(.path, "entry.symlink", entry.path, "符号链接被禁止", "仅包含普通文件和目录")
            }
            let path = try ThemePathPolicy.normalize(entry.path)
            guard let item = byKey[ThemePathPolicy.collisionKey(path)],
                  item.uncompressedSize == entry.uncompressedSize,
                  item.compressedSize == entry.compressedSize,
                  item.isDirectory == (entry.type == .directory) else {
                throw diagnostic(.manifest, "zip.metadataMismatch", path, "本地头与中央目录不一致", "重新导出皮肤包")
            }
            if let permissions = entry.fileAttributes[.posixPermissions] as? NSNumber,
               entry.type == .file, permissions.uint16Value & 0o111 != 0 {
                throw diagnostic(.path, "entry.executable", path, "可执行权限被禁止", "移除执行权限")
            }
            return (entry, item)
        }
    }

    private func readEntry(_ entry: Entry, from archive: Archive, limit: UInt64) throws -> Data {
        var output = Data()
        _ = try archive.extract(entry, bufferSize: 32 * 1_024, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard UInt64(output.count) + UInt64(chunk.count) <= limit else {
                throw diagnostic(.capacity, "entry.actualSize", entry.path, "实际解码大小超过上限", "减小该文件")
            }
            output.append(chunk)
        }
        return output
    }

    private func extract(
        _ entry: Entry,
        metadata: ZIPEntrySecurityMetadata,
        archive: Archive,
        payloadRoot: URL,
        fileLimit: UInt64,
        runningTotal: inout UInt64
    ) throws -> String {
        let destination = payloadRoot.appendingPathComponent(metadata.path, isDirectory: false).standardizedFileURL
        try assertContained(destination, in: payloadRoot)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(
            atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw diagnostic(.path, "entry.exclusiveCreate", metadata.path, "目标文件重复或无法独占创建", "删除重复条目")
        }
        let handle = try FileHandle(forWritingTo: destination)
        var hasher = SHA256()
        var fileBytes: UInt64 = 0
        do {
            _ = try archive.extract(entry, bufferSize: 32 * 1_024, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                let fileNext = fileBytes.addingReportingOverflow(UInt64(chunk.count))
                let totalNext = runningTotal.addingReportingOverflow(UInt64(chunk.count))
                guard !fileNext.overflow, fileNext.partialValue <= fileLimit,
                      !totalNext.overflow, totalNext.partialValue <= ThemePackageLimits.maximumDecodedBytes else {
                    throw diagnostic(.capacity, "entry.actualSize", metadata.path, "实际解码字节超过安全上限", "减小资源")
                }
                fileBytes = fileNext.partialValue
                runningTotal = totalNext.partialValue
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard fileBytes == metadata.uncompressedSize else {
            throw diagnostic(.capacity, "entry.headerMismatch", metadata.path, "实际解码大小与声明不一致", "重新生成 ZIP")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func createDirectory(for path: String, under root: URL) throws {
        let destination = root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
        try assertContained(destination, in: root)
        try fileManager.createDirectory(
            at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func assertContained(_ candidate: URL, in root: URL) throws {
        let base = root.standardizedFileURL.path + "/"
        guard candidate.standardizedFileURL.path.hasPrefix(base) else {
            throw diagnostic(.path, "path.escape", candidate.lastPathComponent, "路径逃逸 staging", "只使用包内相对路径")
        }
    }

    private func validateReferences(
        _ manifest: ThemePackageManifest, entries: [ZIPEntrySecurityMetadata]
    ) throws {
        var references = Set<String>()
        for raw in manifest.referencedPaths {
            references.insert(try ThemePathPolicy.normalize(raw))
        }
        let files = Set(entries.filter { !$0.isDirectory }.map(\.path))
        guard references.isSubset(of: files) else {
            let missing = references.subtracting(files).sorted().first
            throw diagnostic(.missingResource, "resource.missing", missing, "Manifest 引用资源缺失", "补齐资源或修正引用")
        }
        let allowed = references.union(["manifest.json"])
        if let extra = files.subtracting(allowed).sorted().first {
            throw diagnostic(.manifest, "resource.unreferenced", extra, "包内存在未引用文件", "移除未引用内容")
        }
        let forbiddenExtensions: Set<String> = [
            "swift", "m", "mm", "c", "cc", "cpp", "h", "js", "html", "htm", "sh", "command",
            "dylib", "so", "bundle", "plugin", "app", "framework", "jar", "class", "wasm", "py",
            "rb", "php", "ttf", "otf", "woff", "woff2", "zip", "tar", "gz", "7z"
        ]
        for path in files where path != "manifest.json" {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard !forbiddenExtensions.contains(ext) else {
                throw diagnostic(.media, "resource.forbidden", path, "代码、字体、插件或嵌套归档被禁止", "仅包含白名单图片和声音")
            }
        }
        let hashKeys = try Set(manifest.hashes.keys.map(ThemePathPolicy.normalize))
        guard hashKeys == references else {
            throw diagnostic(.manifest, "hash.coverage", "hashes", "每个引用资源必须且只能有一个 SHA-256", "补齐或移除 hash 声明")
        }
    }

    private func validateCompatibility(_ manifest: ThemePackageManifest) throws {
        let appVersion = "\(currentAppVersion.major).\(currentAppVersion.minor).\(currentAppVersion.patch)"
        let versionContext = "当前应用 \(appVersion)；皮肤最低应用版本 \(manifest.minimumAppVersion)"
        let supported = "当前支持 standard-theme@1、standard-panel@1、standard-layout@1"
        guard let minimum = SemanticVersion(manifest.minimumAppVersion), minimum <= currentAppVersion else {
            throw diagnostic(
                .compatibility, "app.version", "minimumAppVersion",
                "需要应用 \(manifest.minimumAppVersion) 或更高版本；\(versionContext)",
                "更新应用后重试；\(supported)"
            )
        }
        guard ![BuiltinThemeID.warmIsland, BuiltinThemeID.windowCompanion].contains(manifest.themeId) else {
            throw diagnostic(.compatibility, "theme.reservedID", "themeId", "用户皮肤不能覆盖内置皮肤", "使用自有 Theme ID")
        }
        let modes = Set(manifest.appearance.supportedModes)
        guard !modes.isEmpty, modes.isSubset(of: [.light, .dark]) else {
            throw diagnostic(.compatibility, "appearance.modes", "appearance.supportedModes", "外观模式声明无效", "声明 light、dark 或两者")
        }
        for capability in manifest.requiredCapabilities ?? [] {
            guard capability.name == "standard-theme", capability.version == 1 else {
                throw diagnostic(
                    .compatibility, "capability.required", "\(capability.name)@\(capability.version)",
                    "请求的 required capability 不受支持；\(versionContext)",
                    "\(supported)；改用 standard-theme@1，不能静默安装必需能力不兼容的皮肤"
                )
            }
        }
        let optional = Set((manifest.optionalCapabilities ?? []).map(\.name))
        func allowsFallback(_ profile: ThemeProfileReference?, standard: String, capability: String) -> Bool {
            guard let profile else { return true }
            if profile.id == standard { return true }
            return optional.contains(capability) && profile.fallback == standard
        }
        guard allowsFallback(manifest.panelProfile, standard: "standard-panel@1", capability: "shaped-panel") else {
            throw diagnostic(.compatibility, "profile.panel", "panelProfile=\(manifest.panelProfile?.id ?? "未声明")",
                "请求的 Panel Profile 没有受支持的标准回退；\(versionContext)",
                "\(supported)；声明 optional shaped-panel 与 standard-panel@1 回退")
        }
        guard allowsFallback(manifest.layoutProfile, standard: "standard-layout@1", capability: "layout-profile") else {
            throw diagnostic(.compatibility, "profile.layout", "layoutProfile=\(manifest.layoutProfile?.id ?? "未声明")",
                "请求的 Layout Profile 没有受支持的标准回退；\(versionContext)",
                "\(supported)；声明 optional layout-profile 与 standard-layout@1 回退")
        }
        if manifest.visualMask != nil {
            let profile = manifest.panelProfile
            let declaredStandard = profile?.id == "standard-panel@1" || profile?.fallback == "standard-panel@1"
            guard optional.contains("shaped-panel"), declaredStandard else {
                throw diagnostic(.compatibility, "profile.mask", "visualMask", "首版遮罩需要明确的标准回退", "声明 optional shaped-panel 与标准面板回退")
            }
            // Mask bytes still pass path/hash/media validation, but are never copied
            // into the runtime decorations or interpreted as a clipping/hit region.
        }
    }

    private func ignoredOptionalCapabilities(
        _ manifest: ThemePackageManifest
    ) throws -> [ThemeCapabilityDeclaration] {
        let ignored = (manifest.optionalCapabilities ?? []).filter {
            !($0.name == "standard-theme" && $0.version == 1)
        }
        // Optional capability is ignored only after the complete standard fallback has
        // passed the same schema, resource and accessibility validation.
        return ignored
    }

    private func replacingSafetyValues(
        in manifest: ThemePackageManifest,
        tokens: ThemePackageTokenGroups,
        metrics: ThemeMetricTokens
    ) -> ThemePackageManifest {
        .init(
            schemaVersion: manifest.schemaVersion, themeId: manifest.themeId, name: manifest.name,
            author: manifest.author, themeVersion: manifest.themeVersion,
            minimumAppVersion: manifest.minimumAppVersion, description: manifest.description,
            preview: manifest.preview, appearance: manifest.appearance, tokens: tokens,
            metrics: metrics, resources: manifest.resources, hashes: manifest.hashes,
            animationPresets: manifest.animationPresets, sounds: manifest.sounds,
            licenseOrSource: manifest.licenseOrSource,
            requiredCapabilities: manifest.requiredCapabilities,
            optionalCapabilities: manifest.optionalCapabilities,
            panelProfile: manifest.panelProfile, layoutProfile: manifest.layoutProfile,
            visualMask: manifest.visualMask, extensions: manifest.extensions
        )
    }

    private func makeRuntimeManifest(_ manifest: ThemePackageManifest) -> ThemeManifest {
        var decorations: [String: String] = [:]
        for (semantic, path) in manifest.resources {
            switch semantic {
            case "state.ready": decorations["ready"] = path
            case "state.waiting": decorations["clockedInWaiting"] = path
            case "state.earning": decorations["earning"] = path
            case "state.awaitingClockOut": decorations["awaitingClockOut"] = path
            case "state.completed": decorations["completed"] = path
            default: break
            }
        }
        return .init(
            schemaVersion: 1, themeId: manifest.themeId, name: manifest.name,
            author: manifest.author, themeVersion: manifest.themeVersion, isDefault: false,
            supportedAppearances: manifest.appearance.supportedModes,
            amountFontDesign: .standard, amountFontWeight: "semibold",
            metrics: manifest.metrics, light: manifest.tokens.light, dark: manifest.tokens.dark,
            decorations: decorations, previewResource: manifest.preview,
            licenseOrSource: manifest.licenseOrSource
        )
    }

    private func verifyDeclaredHashes(
        _ manifest: ThemePackageManifest, actual: [String: String]
    ) throws {
        for (rawPath, expected) in manifest.hashes {
            let path = try ThemePathPolicy.normalize(rawPath)
            guard expected.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil,
                  actual[path]?.lowercased() == expected.lowercased() else {
                throw diagnostic(.media, "hash.mismatch", path, "资源 SHA-256 不匹配", "重新导出且不要修改资源")
            }
        }
    }

    private func validateMedia(_ manifest: ThemePackageManifest, root: URL) throws {
        let soundPaths = Set(manifest.sounds?.values.map { $0 } ?? [])
        for path in manifest.referencedPaths {
            let normalized = try ThemePathPolicy.normalize(path)
            let url = root.appendingPathComponent(normalized)
            if soundPaths.contains(path) {
                try validateSound(url, path: normalized)
            } else {
                try validateImage(url, path: normalized)
            }
        }
    }

    private func validateImage(_ url: URL, path: String) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw diagnostic(.media, "image.decode", path, "图片无法完整读取", "使用有效 PNG、JPEG 或 HEIC")
        }
        let allowedTypes = ["public.png", "public.jpeg", "public.heic"]
        guard let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type),
              width.intValue > 0, height.intValue > 0,
              width.intValue <= ThemePackageLimits.maximumImageDimension,
              height.intValue <= ThemePackageLimits.maximumImageDimension,
              width.intValue * height.intValue <= ThemePackageLimits.maximumImagePixels,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.bitsPerComponent > 0, image.bitsPerComponent <= 16,
              [CGColorSpaceModel.rgb, .monochrome].contains(image.colorSpace?.model ?? .unknown) else {
            throw diagnostic(.media, "image.bounds", path, "图片格式、尺寸、像素或完整解码不合规", "使用上限内的 PNG、JPEG 或 HEIC")
        }
    }

    private func validateSound(_ url: URL, path: String) throws {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "wav", "aiff", "aif"].contains(ext),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) <= ThemePackageLimits.maximumSoundBytes,
              let audio = try? AVAudioFile(forReading: url), audio.fileFormat.sampleRate > 0 else {
            throw diagnostic(.media, "sound.decode", path, "声音格式或容量不合规", "使用 10 MiB 内的 M4A、WAV 或 AIFF")
        }
        let duration = Double(audio.length) / audio.fileFormat.sampleRate
        guard duration <= ThemePackageLimits.maximumSoundDuration else {
            throw diagnostic(.media, "sound.duration", path, "声音超过 30 秒", "缩短提示音")
        }
        // Opening the container and reading its length does not decode its
        // packets. Read every declared frame now, in bounded reusable chunks,
        // so damaged compressed payload cannot escape into an install preview.
        let expectedFrames = audio.length
        guard expectedFrames >= 0, audio.fileFormat.sampleRate.isFinite else {
            throw diagnostic(.media, "sound.decode", path, "声音无法完整解码", "重新导出有效声音文件")
        }
        if expectedFrames == 0 { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096) else {
            throw diagnostic(.media, "sound.decode", path, "声音无法完整解码", "重新导出有效声音文件")
        }
        var remaining = expectedFrames
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity)))
            buffer.frameLength = 0
            do {
                try audio.read(into: buffer, frameCount: requested)
            } catch {
                throw diagnostic(.media, "sound.decode", path, "声音无法完整解码", "重新导出有效声音文件")
            }
            let decoded = AVAudioFramePosition(buffer.frameLength)
            guard decoded > 0, decoded <= AVAudioFramePosition(requested) else {
                throw diagnostic(.media, "sound.decode", path, "声音无法完整解码", "重新导出有效声音文件")
            }
            remaining -= decoded
        }
        // Do not issue an extra read after length: AVAudioFile can report false
        // at normal EOF with no NSError, despite all declared frames decoding.
    }

    private func verifyStaging(_ root: URL, expected: Set<String>) throws {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw ThemeImportError.stagingFailed }
        var found = Set<String>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw diagnostic(.path, "staging.type", url.lastPathComponent, "staging 出现链接或特殊文件", "重新导入")
            }
            if values.isRegularFile == true {
                if let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
                   permissions.uint16Value & 0o133 != 0 {
                    throw diagnostic(.path, "staging.permissions", url.lastPathComponent, "staging 文件权限不安全", "重新导入")
                }
                let resolvedPath = url.resolvingSymlinksInPath().path
                let relative = String(resolvedPath.dropFirst(resolvedRoot.path.count + 1))
                found.insert(try ThemePathPolicy.normalize(relative))
            }
        }
        let expectedFiles = expected.filter { !$0.hasSuffix("/") }
        guard found == expectedFiles else {
            let difference = expectedFiles.symmetricDifference(found).sorted().joined(separator: ",")
            throw diagnostic(
                .missingResource,
                "staging.inventory",
                difference.isEmpty ? nil : difference,
                "staging 文件清单与 ZIP 不一致",
                "重新导出皮肤包"
            )
        }
    }

    private func installDisposition(for manifest: ThemePackageManifest) throws -> ThemeInstallDisposition {
        let target = themesURL.appendingPathComponent(manifest.themeId, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { return .firstInstall }
        let installed = try decodeInstalledMetadata(in: target)
        guard installed.record.author == manifest.author else {
            throw diagnostic(.compatibility, "identity.author", "author", "同 ID 的已安装皮肤作者不同", "先明确删除旧皮肤")
        }
        guard let current = SemanticVersion(installed.record.themeVersion),
              let proposed = SemanticVersion(manifest.themeVersion) else {
            throw diagnostic(.manifest, "identity.version", "themeVersion", "版本格式无效", "使用 major.minor.patch")
        }
        if proposed < current {
            throw diagnostic(.compatibility, "identity.downgrade", "themeVersion", "默认拒绝降级", "先删除现有皮肤再导入")
        }
        if proposed == current { return .reinstall }
        return .upgrade(from: installed.record.themeVersion)
    }

    private func writeMetadata(_ metadata: InstalledThemeMetadata, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(metadata)
        try data.write(to: root.appendingPathComponent(".incomeclock-installed.json"), options: .atomic)
    }

    private func decodeInstalledMetadata(in root: URL) throws -> InstalledThemeMetadata {
        let data = try Data(contentsOf: root.appendingPathComponent(".incomeclock-installed.json"))
        return try JSONDecoder().decode(InstalledThemeMetadata.self, from: data)
    }

    private func verifyInstalledHashes(_ manifest: ThemePackageManifest, root: URL) throws {
        for (rawPath, expected) in manifest.hashes {
            let path = try ThemePathPolicy.normalize(rawPath)
            let url = root.appendingPathComponent(path).standardizedFileURL
            try assertContained(url, in: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  sha256(try Data(contentsOf: url, options: .mappedIfSafe)) == expected.lowercased() else {
                throw ThemeImportError.stagingFailed
            }
        }
    }
}

@MainActor
final class ThemeValidationTask {
    private var task: Task<ThemeImportCandidate, Error>?

    var isRunning: Bool { task != nil }

    func start(
        repository: any ThemeRepositoryProviding,
        sourceURL: URL,
        progress: @escaping @MainActor (ThemeImportProgress) -> Void
    ) async throws -> ThemeImportCandidate {
        guard task == nil else { throw ThemeImportError.stagingFailed }
        let operation = Task.detached(priority: .userInitiated) {
            try await repository.validatePackage(at: sourceURL) { update in
                Task { @MainActor in progress(update) }
            }
        }
        task = operation
        defer { task = nil }
        return try await operation.value
    }

    func cancel() {
        task?.cancel()
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
