import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Darwin
import SwiftUI
import XCTest
import ZIPFoundation
@testable import IncomeClock
// Gates pause real repository operations at the async boundary; package
// validation, disk installation and preference persistence remain production code.
private actor HeldThemeInstallRepository: ThemeRepositoryProviding {
    let base: ThemeRepositoryActor
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: ThemeRepositoryActor) { self.base = base }
    func holdNextInstall() { hold = true }
    func waitUntilHeld() async throws {
        for _ in 0..<100 {
            if continuation != nil { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw ThemeImportError.installFailed
    }
    func release() { continuation?.resume(); continuation = nil }
    func loadInstalledThemes() async -> ThemeRepositorySnapshot { await base.loadInstalledThemes() }
    func validatePackage(at url: URL, progress: @escaping @Sendable (ThemeImportProgress) -> Void) async throws -> ThemeImportCandidate {
        try await base.validatePackage(at: url, progress: progress)
    }
    func install(_ candidate: ThemeImportCandidate) async throws -> ValidatedTheme {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        return try await base.install(candidate)
    }
    func discard(_ candidate: ThemeImportCandidate) async { await base.discard(candidate) }
    func deleteTheme(id: String) async throws { try await base.deleteTheme(id: id) }
}

private actor HeldThemeFallbackPreferences: ThemePreferencesRepository {
    private let base = EphemeralThemePreferencesRepository()
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdNextSave() { hold = true }
    func waitUntilHeld() async throws {
        for _ in 0..<100 {
            if continuation != nil { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw ThemeImportError.installFailed
    }
    func release() { continuation?.resume(); continuation = nil }
    func loadThemePreferences() async -> RecordLoadResult<ThemePreferencesRecord> { await base.loadThemePreferences() }
    func saveThemePreferences(_ proposed: ThemePreferencesRecord, expectedRevision: RecordRevision?) async throws -> ThemePreferencesRecord {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        return try await base.saveThemePreferences(proposed, expectedRevision: expectedRevision)
    }
    func recoverThemePreferences(_ proposed: ThemePreferencesRecord) async throws -> ThemePreferencesRecord {
        try await base.recoverThemePreferences(proposed)
    }
}

final class Stage8ThemeImportTests: XCTestCase {
    private struct CorpusEntry {
        let path: String
        let data: Data
        let type: Entry.EntryType
        let permissions: UInt16?
        let compression: CompressionMethod

        init(
            _ path: String,
            _ data: Data = Data(),
            type: Entry.EntryType = .file,
            permissions: UInt16? = 0o644,
            compression: CompressionMethod = .deflate
        ) {
            self.path = path
            self.data = data
            self.type = type
            self.permissions = permissions
            self.compression = compression
        }
    }

    private final class FailOnSecondCommitter: ThemeAtomicCommitting, @unchecked Sendable {
        private let lock = NSLock()
        private var installs = 0

        func installDirectory(at stagedURL: URL, replacing targetURL: URL) throws {
            let shouldFail = lock.withLock { () -> Bool in
                installs += 1
                return installs == 2
            }
            if shouldFail { throw ThemeImportError.installFailed }
            try POSIXThemeAtomicCommitter().installDirectory(at: stagedURL, replacing: targetURL)
        }

        func deleteDirectory(at targetURL: URL) throws {
            try POSIXThemeAtomicCommitter().deleteDirectory(at: targetURL)
        }
    }

    private struct DeleteFailCommitter: ThemeAtomicCommitting {
        func installDirectory(at stagedURL: URL, replacing targetURL: URL) throws {
            try POSIXThemeAtomicCommitter().installDirectory(at: stagedURL, replacing: targetURL)
        }

        func deleteDirectory(at targetURL: URL) throws {
            throw ThemeImportError.deleteFailed
        }
    }

    private final class RejectionMutationRecorder: RecordFileStore, ThemeAtomicCommitting, @unchecked Sendable {
        private let lock = NSLock()
        private let records = AtomicRecordFileStore()
        private let themes = POSIXThemeAtomicCommitter()
        private var recordCount = 0
        private var themeCount = 0
        var recordMutations: Int { lock.withLock { recordCount } }
        var themeMutations: Int { lock.withLock { themeCount } }
        func readData(at url: URL) throws -> Data? { try records.readData(at: url) }
        func commitAtomically(_ data: Data, to url: URL) throws {
            lock.withLock { recordCount += 1 }
            try records.commitAtomically(data, to: url)
        }
        func removeItem(at url: URL) throws {
            lock.withLock { recordCount += 1 }
            try records.removeItem(at: url)
        }
        func copyItem(at source: URL, to destination: URL) throws {
            lock.withLock { recordCount += 1 }
            try records.copyItem(at: source, to: destination)
        }
        func installDirectory(at source: URL, replacing destination: URL) throws {
            lock.withLock { themeCount += 1 }
            try themes.installDirectory(at: source, replacing: destination)
        }
        func deleteDirectory(at url: URL) throws {
            lock.withLock { themeCount += 1 }
            try themes.deleteDirectory(at: url)
        }
    }

    private static let validPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR42mP8z8AARAwMjIwgAQAQAgEAff9QNgAAAABJRU5ErkJggg=="
    )!

    @MainActor
    func testImportMissingRequiredWrongTypeUnknownSchemaAndUnknownBehaviorShowExactRejection() async throws {
        for name in ["missing-themeId", "schema-wrong-type", "schema-unknown-major", "unknown-behavior"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
            let code: String
            let item: String
            let category: ThemeValidationCategory
            let reason: String
            switch name {
            case "missing-themeId":
                XCTAssertNotNil(object.removeValue(forKey: "themeId"))
                code = "manifest.types"; item = "manifest.json"; category = .manifest
                reason = "必需字段缺失或类型错误"
            case "schema-wrong-type":
                object["schemaVersion"] = "1"
                code = "manifest.types"; item = "manifest.json"; category = .manifest
                reason = "必需字段缺失或类型错误"
            case "schema-unknown-major":
                object["schemaVersion"] = 2
                code = "schema.version"; item = "schemaVersion"; category = .compatibility
                reason = "未知主 schema 版本"
            default:
                object["unknownBehavior"] = ["run": true]
                code = "manifest.unknownField"; item = "manifest.unknownBehavior"; category = .manifest
                reason = "未知行为字段被禁止"
            }
            let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try await assertStage9SchemaLinkRejection(name: "schema-direct-" + name,
                code: code, item: item, category: category, reasonContains: reason,
                entries: [CorpusEntry("manifest.json", manifest), CorpusEntry("preview.png", Self.validPNG)])
        }
    }

    @MainActor
    func testUnixExtraFieldHardLinkIsRejectedBeforeThemeMutation() async throws {
        // PKWARE APPNOTE 4.5.7: UNIX extra 0x000d stores the original link target
        // after its 12-byte time/uid/gid prefix. Hard links have regular-file mode;
        // pretending that a symlink/special-file mode is a hard link would be false.
        // This is a pending negative regression: current inspector skips extras.
        let manifest = try validManifestData(resources: ["state.ready": "linked.png"],
            resourceData: ["preview.png": Self.validPNG, "linked.png": Self.validPNG])
        try await assertStage9SchemaLinkRejection(name: "unix-extra-hardlink", code: "entry.type",
            item: "linked.png", category: .path, reasonContains: "链接",
            entries: [CorpusEntry("manifest.json", manifest, compression: .none),
                CorpusEntry("preview.png", Self.validPNG, compression: .none),
                CorpusEntry("linked.png", Self.validPNG, compression: .none)]) { url in
            var bytes = try Data(contentsOf: url)
            try self.insertStage9UnixHardLinkExtra(into: &bytes, member: "linked.png", target: "preview.png")
            try bytes.write(to: url, options: .atomic)
            let decoded = try Archive(url: url, accessMode: .read)
            let link = try XCTUnwrap(decoded["linked.png"])
            XCTAssertEqual(link.type, .file, "A hard-link claim is not a symlink mode")
            var payload = Data()
            _ = try decoded.extract(link) { payload.append($0) }
            XCTAssertEqual(payload, Self.validPNG, "No corrupt-payload/CRC surrogate rejection")
        }
    }

    private func makeStage9SchemaFixtureRoot(name: String) throws -> URL {
        let allowed: Set<String> = ["schema-direct-missing-themeId", "schema-direct-schema-wrong-type",
            "schema-direct-schema-unknown-major", "schema-direct-unknown-behavior",
            "unix-extra-hardlink", "unix-extra-framing"]
        guard allowed.contains(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let declared = "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData"
        let run = URL(fileURLWithPath: declared, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        // Foundation on this host canonicalizes /private/tmp as /tmp. Permit
        // only those two exact system aliases, never an arbitrary resolved root.
        guard [declared, String(declared.dropFirst("/private".count))].contains(run.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var rootInfo = stat()
        guard lstat(run.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let family = run.appendingPathComponent("Resume008SchemaFixtures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: family.path) {
            guard mkdir(family.path, 0o700) == 0 else { throw POSIXError(.EEXIST) }
        }
        guard family.resolvingSymlinksInPath().path == family.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var familyInfo = stat()
        guard lstat(family.path, &familyInfo) == 0,
              familyInfo.st_mode & S_IFMT == S_IFDIR, familyInfo.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let children = try FileManager.default.contentsOfDirectory(at: family, includingPropertiesForKeys: nil)
        guard children.count < allowed.count,
              children.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var pending = [family], count = 0, allocated: Int64 = 0
        while let item = pending.popLast() {
            count += 1
            var info = stat()
            guard count <= 512, lstat(item.path, &info) == 0,
                  info.st_uid == geteuid(), info.st_blocks >= 0 else { throw POSIXError(.EIO) }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG,
                  kind != S_IFREG || info.st_nlink == 1 else { throw CocoaError(.fileWriteNoPermission) }
            allocated += Int64(info.st_blocks) * 512
            if kind == S_IFDIR {
                pending += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            }
        }
        // Each archive <128KiB, one copied archive, decoded input <64KiB,
        // plus tiny business/preferences/metadata and allocation rounding.
        guard allocated + 384 * 1_024 <= 2 * 1_024 * 1_024 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let child = family.appendingPathComponent(name, isDirectory: true)
        guard mkdir(child.path, 0o700) == 0 else { throw POSIXError(.EEXIST) }
        return child
    }

    private func insertStage9UnixHardLinkExtra(into bytes: inout Data, member: String, target: String) throws {
        let central = signatureOffsets(0x02014B50, in: bytes)
        XCTAssertEqual(central.count, 3)
        let record = try XCTUnwrap(central.last)
        let n = Int(readUInt16(bytes, record + 28))
        XCTAssertEqual(String(data: bytes.subdata(in: record + 46..<record + 46 + n), encoding: .utf8), member)
        let local = Int(readUInt32(bytes, record + 42))
        XCTAssertEqual(local, central.map { Int(readUInt32(bytes, $0 + 42)) }.max(), "Only last local record mutated")
        let localNameLength = Int(readUInt16(bytes, local + 26))
        let localExtraLength = Int(readUInt16(bytes, local + 28))
        let centralExtraLength = Int(readUInt16(bytes, record + 30))
        let linkedTo = Data(target.utf8)
        XCTAssertEqual(linkedTo.count, 11)
        var extra = Data(repeating: 0, count: 16)
        writeUInt16(0x000d, to: &extra, at: 0)
        writeUInt16(UInt16(12 + linkedTo.count), to: &extra, at: 2)
        extra.append(linkedTo)
        let delta = extra.count
        let eocd = try XCTUnwrap(signatureOffsets(0x06054B50, in: bytes).last)
        let oldCentralOffset = readUInt32(bytes, eocd + 16)
        let oldCentralSize = readUInt32(bytes, eocd + 12)
        let localInsertion = local + 30 + localNameLength + localExtraLength
        bytes.insert(contentsOf: extra, at: localInsertion)
        writeUInt16(UInt16(localExtraLength + delta), to: &bytes, at: local + 28)
        let shiftedRecord = record + delta
        let centralInsertion = shiftedRecord + 46 + n + centralExtraLength
        bytes.insert(contentsOf: extra, at: centralInsertion)
        writeUInt16(UInt16(centralExtraLength + delta), to: &bytes, at: shiftedRecord + 30)
        writeUInt16(0x0314, to: &bytes, at: shiftedRecord + 4)
        writeUInt32(UInt32(0o100644) << 16, to: &bytes, at: shiftedRecord + 38)
        let shiftedEnd = eocd + 2 * delta
        writeUInt32(oldCentralOffset + UInt32(delta), to: &bytes, at: shiftedEnd + 16)
        writeUInt32(oldCentralSize + UInt32(delta), to: &bytes, at: shiftedEnd + 12)
        XCTAssertEqual(readUInt32(bytes, shiftedEnd), 0x06054B50)
        XCTAssertEqual(bytes.subdata(in: localInsertion..<localInsertion + delta), extra)
        XCTAssertEqual(bytes.subdata(in: centralInsertion..<centralInsertion + delta), extra)
        XCTAssertEqual(readUInt16(bytes, shiftedRecord + 4) >> 8, 3)
        XCTAssertEqual((readUInt32(bytes, shiftedRecord + 38) >> 16) & 0xf000, 0x8000)
    }

    @MainActor
    private func assertStage9SchemaLinkRejection(
        name: String, code: String, item: String, category: ThemeValidationCategory,
        reasonContains: String, entries: [CorpusEntry], mutateArchive: ((URL) throws -> Void)? = nil
    ) async throws {
        guard entries.count <= 3, entries.reduce(0, { $0 + $1.data.count }) < 65_536 else {
            throw ThemeImportError.installFailed
        }
        let root = try makeStage9SchemaFixtureRoot(name: name)
        let paths = RecordRepositoryPaths(root: root)
        let writes = RejectionMutationRecorder()
        let records = RecordRepositoryActor(paths: paths, fileStore: writes)
        _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(
            wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
        let notifications = FakeNotificationService(authorization: .authorized)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let business = try BusinessStore(repository: records, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        await business.restore()
        let started = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(started, .committed)
        let repository = ThemeRepositoryActor(applicationSupportRoot: root,
            currentAppVersion: "1.2.3", committer: writes)
        let store = ThemeStore(repository: records, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        let themeBefore = store.viewState
        let businessBefore = business.viewState
        let todayBefore = business.todayRecordForValidation
        let settingsBefore = business.settingsRecordForValidation
        let notificationDiagnosticsBefore = business.notificationDiagnostics
        let callsBefore = await notifications.operationLog()
        let settingsBytes = try Data(contentsOf: paths.settings)
        let todayBytes = try Data(contentsOf: paths.today)
        let preferencesBytes = try Data(contentsOf: paths.themePreferences)
        let recordMutationCount = writes.recordMutations
        let themesDirectory = root.appendingPathComponent("Themes", isDirectory: true)
        let themeDirectoryDate = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: themesDirectory.path)[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: themesDirectory.path), [])

        XCTAssertLessThan(entries.reduce(0) { $0 + $1.data.count }, 65_536)
        let archive = try makeArchive(named: name, entries: entries, in: root)
        try mutateArchive?(archive)
        XCTAssertLessThan(try Data(contentsOf: archive).count, 131_072)
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: store) })
        defer { host.close() }
        await store.beginImport(from: archive)
        guard let importError = store.importError else {
            store.cancelImport()
            return XCTFail("Package unexpectedly accepted: \(name)")
        }
        guard case let .validation(diagnostics) = importError else {
            store.cancelImport()
            return XCTFail("Expected exact schema/link rejection: \(name)")
        }
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.category, category)
        XCTAssertEqual(diagnostic.code, code)
        XCTAssertEqual(diagnostic.item, item)
        XCTAssertTrue(diagnostic.reason.contains(reasonContains))
        XCTAssertFalse(diagnostic.suggestion.isEmpty)
        // Read production error UI through public in-process accessibility.
        // Copy is offered by that same UI; the test does not mutate the user's clipboard.
        for _ in 0..<100 {
            if !host.window.sheets.isEmpty { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let errorSheet = try XCTUnwrap(host.window.sheets.first)
        _ = try await host.element(identifier: "theme-import-error", root: errorSheet)
        _ = try await host.element(containing: "无法导入此皮肤", root: errorSheet)
        for text in [item, diagnostic.reason, diagnostic.suggestion] {
            let element = try await host.element(containing: text, root: errorSheet)
            XCTAssertTrue(host.text(element).contains(text))
        }
        XCTAssertTrue(host.containsControl(role: "AXButton", label: "复制诊断信息"))
        XCTAssertTrue(host.containsControl(role: "AXButton", label: "关闭"))
        for forbidden in ["安装皮肤", "重新安装", "更新皮肤", "仍然安装"] {
            XCTAssertFalse(host.containsControl(role: "AXButton", label: forbidden), forbidden)
        }
        XCTAssertNil(host.find(identifier: "theme-import-preview", root: errorSheet),
            "Rejection presents diagnostics, not an installation preview")
        XCTAssertNil(store.importCandidate)
        XCTAssertNil(store.importProgress)
        // A direct install command also cannot bypass the absent candidate.
        await store.installImportCandidate()
        XCTAssertEqual(store.importError, .validation(diagnostics))
        XCTAssertNil(store.lastInstalledThemeID)
        XCTAssertEqual(store.viewState, themeBefore)
        XCTAssertEqual(writes.themeMutations, 0)
        XCTAssertEqual(writes.recordMutations, recordMutationCount)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: themesDirectory.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: themesDirectory.path)[.modificationDate] as? Date, themeDirectoryDate)
        try assertStagingClean(root)
        XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
        XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)
        XCTAssertEqual(try Data(contentsOf: paths.themePreferences), preferencesBytes)
        XCTAssertEqual(business.viewState, businessBefore)
        XCTAssertEqual(business.todayRecordForValidation, todayBefore)
        XCTAssertEqual(business.settingsRecordForValidation, settingsBefore)
        XCTAssertEqual(business.notificationDiagnostics, notificationDiagnosticsBefore)
        let callsAfter = await notifications.operationLog()
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testPinnedZIPFoundationAndStrictSchemaAreAvailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("empty.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        XCTAssertEqual(Array(archive).count, 0)

        let manifest = try validManifestData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        object["unknownBehavior"] = ["run": true]
        let bad = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ThemePackageSchemaValidator.decode(bad)) { error in
            XCTAssertEqual((error as? ThemeValidationDiagnostic)?.code, "manifest.unknownField")
        }
    }

    func testPathLinkDuplicateAndExecutableCorpusIsRejectedWithoutStagingLeak() async throws {
        let cases: [(String, [CorpusEntry], Set<String>)] = [
            ("traversal", [CorpusEntry("../escape.png", Self.validPNG)], ["path.traversal"]),
            ("absolute", [CorpusEntry("/tmp/escape.png", Self.validPNG)], ["path.absolute"]),
            ("drive", [CorpusEntry("C:\\escape.png", Self.validPNG)], ["path.absolute"]),
            ("symlink", [CorpusEntry("link", Data("../outside".utf8), type: .symlink)], ["entry.type", "entry.symlink"]),
            ("case-duplicate", [CorpusEntry("A.png", Self.validPNG), CorpusEntry("a.png", Self.validPNG)], ["path.duplicate"]),
            ("executable", [CorpusEntry("payload.png", Self.validPNG, permissions: 0o755)], ["entry.executable"]),
            ("file-ancestor", [CorpusEntry("parent", Data()), CorpusEntry("parent/child.png", Self.validPNG)], ["path.fileAncestor"]),
            ("directory-payload", [CorpusEntry("hidden/", Data("hidden".utf8), type: .file)], ["entry.directoryPayload"])
        ]

        for (name, entries, codes) in cases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try makeArchive(named: name, entries: entries, in: root)
            preserveCorpus(archive, name: name)
            let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
            let diagnostics = await validationDiagnostics(repository, archive)
            XCTAssertFalse(codes.isDisjoint(with: Set(diagnostics.map(\.code))), name)
            try assertStagingClean(root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.png").path))
        }
    }

    func testTrailingArchivePayloadIsRejectedAndCleaned() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try validPackage(in: root, name: "trailing-payload")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("#!/bin/sh\n".utf8))
        try handle.close()
        preserveCorpus(url, name: "trailing-payload")

        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let codes = await validationDiagnostics(repository, url).map(\.code)
        XCTAssertTrue(codes.contains("zip.bounds"))
        try assertStagingClean(root)
    }

    func testCapacityBombCountAndActualDecodedHeaderDeceitCorpusIsRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let oversized = root.appendingPathComponent("archive-over-50mib.incomeclocktheme")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: ThemePackageLimits.maximumArchiveBytes + 1)
        try handle.close()
        preserveCorpus(oversized, name: "archive-over-50mib")
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let oversizedCode = await validationDiagnostics(repository, oversized).first?.code
        XCTAssertEqual(oversizedCode, "archive.size")

        let countEntries = (0...ThemePackageLimits.maximumEntries).map {
            CorpusEntry("entry-\($0).txt", Data())
        }
        let countArchive = try makeArchive(named: "entry-count-257", entries: countEntries, in: root)
        preserveCorpus(countArchive, name: "entry-count-257")
        let countCode = await validationDiagnostics(repository, countArchive).first?.code
        XCTAssertEqual(countCode, "entry.count")

        let bombArchive = try makeArchive(
            named: "compression-bomb",
            entries: [CorpusEntry("zeros.bin", Data(repeating: 0, count: 4 * 1_024 * 1_024))],
            in: root
        )
        preserveCorpus(bombArchive, name: "compression-bomb")
        let bombCode = await validationDiagnostics(repository, bombArchive).first?.code
        XCTAssertEqual(bombCode, "archive.ratio")

        var largeDeclared = try Data(contentsOf: try makeArchive(
            named: "declared-file-size-source",
            entries: [CorpusEntry("large.bin", Data([1]))], in: root
        ))
        try rewriteUncompressedSizes(
            in: &largeDeclared,
            sizes: [UInt32(ThemePackageLimits.maximumFileBytes + 1)]
        )
        let largeURL = try writeCorpus(largeDeclared, name: "declared-file-over-limit", root: root)
        let largeCode = await validationDiagnostics(repository, largeURL).first?.code
        XCTAssertEqual(largeCode, "entry.size")

        let sixEntries = (0..<6).map { CorpusEntry("total-\($0).bin", Data([UInt8($0)])) }
        var totalDeclared = try Data(contentsOf: try makeArchive(
            named: "declared-total-source", entries: sixEntries, in: root
        ))
        try rewriteUncompressedSizes(
            in: &totalDeclared,
            sizes: Array(repeating: UInt32(20 * 1_024 * 1_024), count: 6)
        )
        let totalURL = try writeCorpus(totalDeclared, name: "declared-total-over-limit", root: root)
        let totalCode = await validationDiagnostics(repository, totalURL).first?.code
        XCTAssertEqual(totalCode, "decoded.declared")

        var deceit = try Data(contentsOf: try validPackage(in: root, name: "actual-byte-source"))
        try rewriteUncompressedSize(in: &deceit, entryNamed: "preview.png", size: 1)
        let deceitURL = try writeCorpus(deceit, name: "actual-decoded-header-deceit", root: root)
        let deceitCodes = Set(await validationDiagnostics(repository, deceitURL).map(\.code))
        XCTAssertFalse(Set(["entry.headerMismatch", "entry.actualSize", "zip.localMismatch"]).isDisjoint(with: deceitCodes))
        try assertStagingClean(root)
    }

    func testManifestMediaHashMissingAndForbiddenContentCorpusIsRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")

        let invalidJSON = try makeArchive(
            named: "invalid-json", entries: [CorpusEntry("manifest.json", Data("{".utf8))], in: root
        )
        let badMedia = try package(name: "invalid-media", preview: Data("not-an-image".utf8), in: root)
        let hashMismatch = try package(
            name: "hash-mismatch", preview: Self.validPNG,
            declaredHash: String(repeating: "0", count: 64), in: root
        )
        let missing = try package(name: "missing-resource", preview: nil, in: root)

        var remoteObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: validManifestData()
        ) as? [String: Any])
        remoteObject["description"] = "loads https://example.invalid/theme.png"
        let remote = try makeArchive(
            named: "remote-url",
            entries: [
                CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: remoteObject)),
                CorpusEntry("preview.png", Self.validPNG)
            ], in: root
        )

        let script = Data("#!/bin/sh".utf8)
        let forbiddenManifest = try validManifestData(
            resources: ["panel.decoration.leading": "run.sh"],
            resourceData: ["preview.png": Self.validPNG, "run.sh": script]
        )
        let forbidden = try makeArchive(
            named: "forbidden-script",
            entries: [
                CorpusEntry("manifest.json", forbiddenManifest),
                CorpusEntry("preview.png", Self.validPNG), CorpusEntry("run.sh", script)
            ], in: root
        )

        let expected = [
            ("invalid-json", invalidJSON, "manifest.json"),
            ("invalid-media", badMedia, "image.decode"),
            ("hash-mismatch", hashMismatch, "hash.mismatch"),
            ("missing-resource", missing, "resource.missing"),
            ("remote-url", remote, "manifest.remoteURL"),
            ("forbidden-script", forbidden, "resource.forbidden")
        ]
        for (name, url, code) in expected {
            preserveCorpus(url, name: name)
            let diagnosticCodes = await validationDiagnostics(repository, url).map(\.code)
            XCTAssertTrue(diagnosticCodes.contains(code), name)
            try assertStagingClean(root)
        }
    }

    func testManifestCompatibilityCapabilityProfileAndReservedIdentityAreRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        var variants: [(String, [String: Any], String)] = []

        var futureApp = base
        futureApp["minimumAppVersion"] = "9.0.0"
        variants.append(("future-app", futureApp, "app.version"))
        var reserved = base
        reserved["themeId"] = BuiltinThemeID.warmIsland
        variants.append(("reserved-id", reserved, "theme.reservedID"))
        var capability = base
        capability["requiredCapabilities"] = [["name": "dynamic-layout", "version": 1]]
        variants.append(("required-capability", capability, "capability.required"))
        var profile = base
        profile["panelProfile"] = "shaped-panel@1"
        variants.append(("unsupported-profile", profile, "profile.panel"))
        var animation = base
        animation["animationPresets"] = ["execute-bytecode"]
        variants.append(("unsupported-animation", animation, "animation.preset"))

        for (name, object, expectedCode) in variants {
            let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let url = try makeArchive(
                named: name,
                entries: [CorpusEntry("manifest.json", manifest), CorpusEntry("preview.png", Self.validPNG)],
                in: root
            )
            preserveCorpus(url, name: name)
            let codes = await validationDiagnostics(repository, url).map(\.code)
            XCTAssertTrue(codes.contains(expectedCode), name)
            try assertStagingClean(root)
        }
    }

    @MainActor
    func testUnknownRequiredCapabilityReportsVersionsWithoutInstallOrBusinessWrites() async throws {
        try await assertCompatibilityRejection(
            name: "unknown-required-capability", code: "capability.required",
            item: "dynamic-layout@7", minimum: "0.5.0"
        ) { manifest in
            manifest["requiredCapabilities"] = [["name": "dynamic-layout", "version": 7]]
        }
    }

    @MainActor
    func testUnsupportedRequiredCapabilityVersionReportsVersionsWithoutInstallOrBusinessWrites() async throws {
        try await assertCompatibilityRejection(
            name: "unknown-required-version", code: "capability.required",
            item: "standard-theme@99", minimum: "0.5.0"
        ) { manifest in
            manifest["requiredCapabilities"] = [["name": "standard-theme", "version": 99]]
        }
    }

    @MainActor
    func testMinimumAppVersionRejectionReportsVersionsWithoutInstallOrBusinessWrites() async throws {
        try await assertCompatibilityRejection(
            name: "minimum-app-version", code: "app.version",
            item: "minimumAppVersion", minimum: "9.4.2"
        ) { _ in }
    }

    @MainActor
    func testRequiredProfileRejectionReportsIDAndVersionsWithoutInstallOrBusinessWrites() async throws {
        try await assertCompatibilityRejection(
            name: "unknown-required-profile", code: "profile.panel",
            item: "panelProfile=future-panel@7", minimum: "0.5.0"
        ) { manifest in
            manifest["panelProfile"] = ["id": "future-panel@7"]
        }
    }

    @MainActor
    private func assertCompatibilityRejection(
        name: String, code: String, item: String, minimum: String,
        mutate: (inout [String: Any]) -> Void
    ) async throws {
        let root = try temporaryRoot()
        let paths = RecordRepositoryPaths(root: root)
        let writes = RejectionMutationRecorder()
        let records = RecordRepositoryActor(paths: paths, fileStore: writes)
        _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(
            wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
        let notifications = FakeNotificationService(authorization: .authorized)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let business = try BusinessStore(repository: records, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        await business.restore()
        let started = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(started, .committed)
        let repository = ThemeRepositoryActor(applicationSupportRoot: root,
            currentAppVersion: "1.2.3", committer: writes)
        let store = ThemeStore(repository: records, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        let themeBefore = store.viewState
        let businessBefore = business.viewState
        let todayBefore = business.todayRecordForValidation
        let settingsBefore = business.settingsRecordForValidation
        let notificationDiagnosticsBefore = business.notificationDiagnostics
        let callsBefore = await notifications.operationLog()
        let settingsBytes = try Data(contentsOf: paths.settings)
        let todayBytes = try Data(contentsOf: paths.today)
        let preferencesBytes = try Data(contentsOf: paths.themePreferences)
        let recordMutationCount = writes.recordMutations
        let themesDirectory = root.appendingPathComponent("Themes", isDirectory: true)
        let themeDirectoryDate = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: themesDirectory.path)[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: themesDirectory.path), [])

        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        manifest["minimumAppVersion"] = minimum
        mutate(&manifest)
        let archive = try makeArchive(named: name, entries: [
            CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])),
            CorpusEntry("preview.png", Self.validPNG)
        ], in: root)
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: store) })
        defer { host.close() }
        await store.beginImport(from: archive)
        let importError = try XCTUnwrap(store.importError)
        guard case let .validation(diagnostics) = importError else {
            return XCTFail("Expected a compatibility rejection: \(name)")
        }
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.category, .compatibility)
        XCTAssertEqual(diagnostic.code, code)
        XCTAssertEqual(diagnostic.item, item)
        XCTAssertTrue(diagnostic.reason.contains("当前应用 1.2.3"))
        XCTAssertTrue(diagnostic.reason.contains("皮肤最低应用版本 \(minimum)"))
        for supported in ["standard-theme@1", "standard-panel@1", "standard-layout@1"] {
            XCTAssertTrue(diagnostic.suggestion.contains(supported), supported)
        }
        // Read production error UI through public in-process accessibility.
        // Copy is offered by that same UI; the test does not mutate the user's clipboard.
        for _ in 0..<100 {
            if !host.window.sheets.isEmpty { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let errorSheet = try XCTUnwrap(host.window.sheets.first)
        _ = try await host.element(identifier: "theme-import-error", root: errorSheet)
        _ = try await host.element(containing: "无法导入此皮肤", root: errorSheet)
        for text in [item, diagnostic.reason, diagnostic.suggestion] {
            let element = try await host.element(containing: text, root: errorSheet)
            XCTAssertTrue(host.text(element).contains(text))
        }
        XCTAssertTrue(host.containsControl(role: "AXButton", label: "复制诊断信息"))
        XCTAssertTrue(host.containsControl(role: "AXButton", label: "关闭"))
        for forbidden in ["安装皮肤", "重新安装", "更新皮肤", "仍然安装"] {
            XCTAssertFalse(host.containsControl(role: "AXButton", label: forbidden), forbidden)
        }
        XCTAssertNil(host.find(identifier: "theme-import-preview", root: errorSheet),
            "Rejection presents diagnostics, not an installation preview")
        XCTAssertNil(store.importCandidate)
        XCTAssertNil(store.importProgress)
        // A direct install command also cannot bypass the absent candidate.
        await store.installImportCandidate()
        XCTAssertEqual(store.importError, .validation(diagnostics))
        XCTAssertNil(store.lastInstalledThemeID)
        XCTAssertEqual(store.viewState, themeBefore)
        XCTAssertEqual(writes.themeMutations, 0)
        XCTAssertEqual(writes.recordMutations, recordMutationCount)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: themesDirectory.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: themesDirectory.path)[.modificationDate] as? Date, themeDirectoryDate)
        try assertStagingClean(root)
        XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
        XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)
        XCTAssertEqual(try Data(contentsOf: paths.themePreferences), preferencesBytes)
        XCTAssertEqual(business.viewState, businessBefore)
        XCTAssertEqual(business.todayRecordForValidation, todayBefore)
        XCTAssertEqual(business.settingsRecordForValidation, settingsBefore)
        XCTAssertEqual(business.notificationDiagnostics, notificationDiagnosticsBefore)
        let callsAfter = await notifications.operationLog()
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testUnixLinkExtrasCheckBothHeadersAndMalformedBounds() throws {
        let root = try makeStage9SchemaFixtureRoot(name: "unix-extra-framing")
        let archive = try makeArchive(named: "unix-extra-framing", entries: [
            CorpusEntry("manifest.json", try validManifestData(), compression: .none),
            CorpusEntry("preview.png", Self.validPNG, compression: .none),
            CorpusEntry("linked.png", Self.validPNG, compression: .none)
        ], in: root)
        var original = try Data(contentsOf: archive)
        try insertStage9UnixHardLinkExtra(into: &original, member: "linked.png", target: "preview.png")
        XCTAssertLessThan(original.count, 131_072)
        let central = try XCTUnwrap(signatureOffsets(0x02014B50, in: original).last)
        let local = Int(readUInt32(original, central + 42))
        let centralStart = central + 46 + Int(readUInt16(original, central + 28))
        let localStart = local + 30 + Int(readUInt16(original, local + 26))
        let extraBytes = 27
        // The original builder appends its field after any ZIPFoundation extras.
        let centralExtra = centralStart + Int(readUInt16(original, central + 30)) - extraBytes
        let localExtra = localStart + Int(readUInt16(original, local + 28)) - extraBytes
        XCTAssertEqual(readUInt16(original, centralExtra), 0x000d)
        XCTAssertEqual(readUInt16(original, localExtra), 0x000d)
        for variant in ["local-only", "central-only", "local-overrun", "central-overrun", "extra-header-tail", "unix-short-prefix"] {
            var bytes = original
            let code: String
            let category: ThemeValidationCategory
            switch variant {
            case "local-only":
                writeUInt16(0xcafe, to: &bytes, at: centralExtra)
                code = "entry.type"; category = .path
            case "central-only":
                writeUInt16(0xcafe, to: &bytes, at: localExtra)
                code = "entry.type"; category = .path
            case "local-overrun":
                writeUInt16(0xcafe, to: &bytes, at: centralExtra)
                writeUInt16(.max, to: &bytes, at: localExtra + 2)
                code = "zip.extraBounds"; category = .manifest
            case "central-overrun":
                writeUInt16(0xcafe, to: &bytes, at: localExtra)
                writeUInt16(.max, to: &bytes, at: centralExtra + 2)
                code = "zip.extraBounds"; category = .manifest
            case "extra-header-tail":
                writeUInt16(0xcafe, to: &bytes, at: localExtra)
                writeUInt16(0xcafe, to: &bytes, at: centralExtra)
                writeUInt16(21, to: &bytes, at: centralExtra + 2)
                code = "zip.extraBounds"; category = .manifest
            default:
                writeUInt16(0xcafe, to: &bytes, at: localExtra)
                writeUInt16(11, to: &bytes, at: centralExtra + 2)
                code = "zip.unixExtra"; category = .manifest
            }
            XCTAssertThrowsError(try ZIPCentralDirectoryInspector.inspect(data: bytes), variant) { error in
                let diagnostic = error as? ThemeValidationDiagnostic
                XCTAssertEqual(diagnostic?.category, category, variant)
                XCTAssertEqual(diagnostic?.code, code, variant)
                XCTAssertEqual(diagnostic?.item, "linked.png", variant)
            }
        }
        // Positive framing control: 12-byte UNIX metadata, then a separate valid
        // unknown field occupying the old pathname bytes; no link claim remains.
        var ordinary = original
        for field in [localExtra, centralExtra] {
            writeUInt16(12, to: &ordinary, at: field + 2)
            writeUInt16(0xcafe, to: &ordinary, at: field + 16)
            writeUInt16(7, to: &ordinary, at: field + 18)
        }
        let accepted = try ZIPCentralDirectoryInspector.inspect(data: ordinary)
        XCTAssertEqual(accepted.map(\.path), ["manifest.json", "preview.png", "linked.png"])
    }

    func testEncryptedMultivolumeUnsupportedCompressionAndSpecialFileCorpusIsRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeArchive(
            named: "zip-structure-source",
            entries: [CorpusEntry("payload.bin", Data([1, 2, 3]), compression: .none)],
            in: root
        )
        let original = try Data(contentsOf: source)
        let central = try XCTUnwrap(signatureOffsets(0x02014B50, in: original).first)
        let local = Int(readUInt32(original, central + 42))
        let eocd = try XCTUnwrap(signatureOffsets(0x06054B50, in: original).last)

        var encrypted = original
        writeUInt16(readUInt16(encrypted, central + 8) | 0x0001, to: &encrypted, at: central + 8)
        writeUInt16(readUInt16(encrypted, local + 6) | 0x0001, to: &encrypted, at: local + 6)

        var multivolume = original
        writeUInt16(1, to: &multivolume, at: eocd + 4)

        var unsupportedMethod = original
        writeUInt16(99, to: &unsupportedMethod, at: central + 10)
        writeUInt16(99, to: &unsupportedMethod, at: local + 8)

        var fifo = original
        writeUInt16(3 << 8 | 20, to: &fifo, at: central + 4)
        writeUInt32(UInt32(0x1000 | 0o644) << 16, to: &fifo, at: central + 38)

        let cases = [
            ("encrypted", encrypted, "zip.encrypted"),
            ("multivolume", multivolume, "zip.multivolume"),
            ("unsupported-method", unsupportedMethod, "zip.method"),
            ("fifo-special-type", fifo, "entry.type")
        ]
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        for (name, bytes, expectedCode) in cases {
            let url = try writeCorpus(bytes, name: name, root: root)
            let codes = await validationDiagnostics(repository, url).map(\.code)
            XCTAssertTrue(codes.contains(expectedCode), name)
            try assertStagingClean(root)
        }
    }

    func testSafeTokenReplacementMetricClampPreviewAndLifecycleAreDeterministic() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        var metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        metrics["panelCornerRadius"] = 99
        metrics["decorationOpacity"] = -1
        object["metrics"] = metrics
        var tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        var light = try XCTUnwrap(tokens["light"] as? [String: Any])
        light["primaryText"] = light["background"]
        light["backgroundOpacity"] = 0.2
        tokens["light"] = light
        object["tokens"] = tokens
        let adjustedManifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let adjustedURL = try makeArchive(
            named: "safe-adjustments",
            entries: [CorpusEntry("manifest.json", adjustedManifest), CorpusEntry("preview.png", Self.validPNG)],
            in: root
        )
        preserveCorpus(adjustedURL, name: "safe-adjustments")
        let adjusted = try await repository.validatePackage(at: adjustedURL) { _ in }
        XCTAssertEqual(adjusted.lightPreview.appearance, .light)
        XCTAssertEqual(adjusted.darkPreview.appearance, .dark)
        XCTAssertTrue(adjusted.safetyAdjustments.contains { $0.token == "light.primaryText" })
        XCTAssertTrue(adjusted.safetyAdjustments.contains { $0.token == "light.backgroundOpacity" })
        XCTAssertTrue(adjusted.safetyAdjustments.contains { $0.token == "metrics.panelCornerRadius" })
        XCTAssertEqual(adjusted.validatedTheme.manifest.metrics.panelCornerRadius, 18)
        XCTAssertGreaterThanOrEqual(
            ThemeContrast.ratio(
                foreground: adjusted.lightPreview.colors.primaryText,
                background: adjusted.lightPreview.colors.background
            ), 4.5
        )
        await repository.discard(adjusted)
        try assertStagingClean(root)

        let v1URL = try validPackage(in: root, name: "install-v1", version: "1.0.0")
        let v1 = try await repository.validatePackage(at: v1URL) { _ in }
        XCTAssertEqual(v1.disposition, .firstInstall)
        XCTAssertEqual(v1.ignoredOptionalCapabilities.map(\.name), ["future-decoration"])
        let installedV1 = try await repository.install(v1)
        XCTAssertEqual(installedV1.manifest.themeVersion, "1.0.0")

        let reinstall = try await repository.validatePackage(at: v1URL) { _ in }
        XCTAssertEqual(reinstall.disposition, .reinstall)
        let reinstalled = try await repository.install(reinstall)
        XCTAssertEqual(reinstalled.manifest.themeVersion, "1.0.0")

        let v2URL = try validPackage(in: root, name: "install-v2", version: "1.1.0")
        let upgrade = try await repository.validatePackage(at: v2URL) { _ in }
        XCTAssertEqual(upgrade.disposition, .upgrade(from: "1.0.0"))
        _ = try await repository.install(upgrade)

        let downgradeURL = try validPackage(in: root, name: "downgrade", version: "1.0.0")
        let downgradeCodes = await validationDiagnostics(repository, downgradeURL).map(\.code)
        XCTAssertTrue(downgradeCodes.contains("identity.downgrade"))
        let conflictURL = try validPackage(
            in: root, name: "author-conflict", version: "2.0.0", author: "Different Author"
        )
        let conflictCodes = await validationDiagnostics(repository, conflictURL).map(\.code)
        XCTAssertTrue(conflictCodes.contains("identity.author"))

        let restarted = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let snapshot = await restarted.loadInstalledThemes()
        XCTAssertEqual(snapshot.themes.map(\.manifest.themeVersion), ["1.1.0"])
        XCTAssertEqual(snapshot.disabledThemes, [])
        try await restarted.deleteTheme(id: "com.example.safe-theme")
        let postDeleteSnapshot = await restarted.loadInstalledThemes()
        XCTAssertEqual(postDeleteSnapshot.themes, [])
    }

    @MainActor
    func testRealImportPreviewRendersLightDarkAndAllRequiredStates() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let url = try validPackage(in: root, name: "preview-evidence")
        let store = ThemeStore(
            repository: EphemeralThemePreferencesRepository(),
            themeRepository: repository
        )
        await store.restore()
        await store.beginImport(from: url)
        let candidate = try XCTUnwrap(store.importCandidate)
        XCTAssertEqual(candidate.lightPreview.appearance, .light)
        XCTAssertEqual(candidate.darkPreview.appearance, .dark)
        XCTAssertEqual(candidate.lightPreview.colors, candidate.validatedTheme.manifest.light)
        XCTAssertEqual(candidate.darkPreview.colors, candidate.validatedTheme.manifest.dark)
        XCTAssertEqual(ThemeImportPreviewScenario.supportedStates, [
            .ready, .earning, .awaitingClockOut, .completed, .recoveryRequired
        ])

        var semanticPresentations: [WorkdayState: Stage5PanelPresentation] = [:]
        var pngHashes = Set<String>()
        for state in ThemeImportPreviewScenario.supportedStates {
            let input = try XCTUnwrap(ThemeImportPreviewScenario.renderInput(for: state))
            semanticPresentations[state] = input.presentation
            switch state {
            case .ready:
                XCTAssertEqual(Stage5AmountFormatter.string(for: input.amount), "¥0.00")
                XCTAssertEqual(input.presentation.symbol, "circle")
                XCTAssertEqual(input.presentation.status, "今日未打卡")
                XCTAssertNil(input.presentation.precisionNote)
                XCTAssertEqual(input.presentation.progress, 0.25)
                XCTAssertEqual(input.presentation.supportText, "计划进行中")
                XCTAssertEqual(input.presentation.durationText, "已计薪 00:00:00")
                XCTAssertEqual(input.presentation.actionTitle, "打卡上班")
                XCTAssertEqual(input.presentation.action, .clockIn(enabled: true))
            case .earning:
                XCTAssertEqual(Stage5AmountFormatter.string(for: input.amount), "¥120.000")
                XCTAssertEqual(input.presentation.symbol, "circle.fill")
                XCTAssertEqual(input.presentation.status, "计薪中")
                XCTAssertEqual(input.presentation.precisionNote, "实时收入估算")
                XCTAssertEqual(input.presentation.progress, 0.625)
                XCTAssertEqual(input.presentation.supportText, "距离下班 03:45:00")
                XCTAssertEqual(input.presentation.durationText, "已计薪 05:15:00")
                XCTAssertEqual(input.presentation.actionTitle, "打卡下班")
                XCTAssertEqual(input.presentation.action, .clockOut)
            case .awaitingClockOut:
                XCTAssertEqual(Stage5AmountFormatter.string(for: input.amount), "¥300.00")
                XCTAssertEqual(input.presentation.symbol, "exclamationmark.circle.fill")
                XCTAssertEqual(input.presentation.status, "计薪已停止")
                XCTAssertEqual(input.presentation.precisionNote, "已停止计薪")
                XCTAssertEqual(input.presentation.progress, 1)
                XCTAssertEqual(input.presentation.supportText, "请打卡下班")
                XCTAssertEqual(input.presentation.durationText, "已计薪 08:00:00")
                XCTAssertEqual(input.presentation.actionTitle, "打卡下班")
                XCTAssertEqual(input.presentation.action, .clockOut)
            case .completed:
                XCTAssertEqual(Stage5AmountFormatter.string(for: input.amount), "¥300.00")
                XCTAssertEqual(input.presentation.symbol, "checkmark.circle.fill")
                XCTAssertEqual(input.presentation.status, "今日已完成")
                XCTAssertNil(input.presentation.precisionNote)
                XCTAssertNil(input.presentation.progress)
                XCTAssertEqual(input.presentation.supportText, "计薪时长 08:00:00")
                XCTAssertEqual(input.presentation.durationText, "上班 09:00:00 · 下班 17:00:00")
                XCTAssertNil(input.presentation.actionTitle)
                XCTAssertEqual(input.presentation.action, .none)
            case .recoveryRequired:
                XCTAssertNil(Stage5AmountFormatter.string(for: input.amount))
                XCTAssertEqual(input.presentation.symbol, "exclamationmark.triangle.fill")
                XCTAssertEqual(input.presentation.status, "记录需要恢复")
                XCTAssertNil(input.presentation.progress)
                XCTAssertEqual(input.presentation.supportText, "记录不完整或校验失败")
                XCTAssertEqual(input.presentation.durationText, "暂时无法确定今日收入")
                XCTAssertEqual(input.presentation.actionTitle, "重置今日记录")
                XCTAssertEqual(input.presentation.action, .resetToday)
                XCTAssertTrue(input.presentation.destructive)
            case .unconfigured, .clockedInWaiting:
                XCTFail("Unexpected installation-preview state: \(state.rawValue)")
            }

            let host = NSHostingView(rootView: ThemeImportPreviewView(
                candidate: candidate,
                themeStore: store,
                initialState: state
            ))
            host.frame = CGRect(x: 0, y: 0, width: 680, height: 500)
            host.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertTrue([680, 1_360].contains(bitmap.pixelsWide), state.rawValue)
            XCTAssertEqual(bitmap.pixelsHigh * 68, bitmap.pixelsWide * 50, state.rawValue)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(pngHashes.insert(digest).inserted, "Duplicate Preview PNG for \(state.rawValue)")
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "stage8-import-preview-\(state.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertNotEqual(semanticPresentations[.ready], semanticPresentations[.earning])
        XCTAssertNotEqual(semanticPresentations[.earning], semanticPresentations[.awaitingClockOut])
        XCTAssertNotEqual(semanticPresentations[.ready], semanticPresentations[.awaitingClockOut])
        XCTAssertEqual(pngHashes.count, 5)
        XCTAssertEqual(store.importCandidate?.id, candidate.id, "Preview rendering must not install or dismiss")
        await store.dismissImportCandidate()
        try assertStagingClean(root)
    }

    func testPostNormalizationContrastFailureIsTypedAccessibilityRejection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        var tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        var light = try XCTUnwrap(tokens["light"] as? [String: Any])
        light["background"] = "#000000"
        light["primaryText"] = "#FFFFFF"
        light["secondaryText"] = "#FFFFFF"
        light["tertiaryText"] = "#FFFFFF"
        light["accent"] = "#000000"
        light["accentHover"] = "#000000"
        light["accentPressed"] = "#000000"
        light["start"] = "#000000"
        light["stop"] = "#000000"
        light["actionText"] = "#FFFFFF"
        tokens["light"] = light
        object["tokens"] = tokens
        let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = try makeArchive(
            named: "post-normalization-contrast",
            entries: [CorpusEntry("manifest.json", manifest), CorpusEntry("preview.png", Self.validPNG)],
            in: root
        )
        preserveCorpus(url, name: "post-normalization-contrast")

        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let diagnostics = await validationDiagnostics(repository, url)
        XCTAssertEqual(diagnostics.map(\.category), [.accessibility])
        XCTAssertEqual(diagnostics.map(\.code), ["token.postNormalization"])
        try assertStagingClean(root)
    }

    @MainActor
    func testThemeStoreSwitchRestoreDefaultAndFailedDeleteKeepConsistentState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(
            applicationSupportRoot: root,
            currentAppVersion: "1.0.0",
            committer: DeleteFailCommitter()
        )
        let packageURL = try validPackage(in: root, name: "store-lifecycle")
        _ = try await repository.install(try await repository.validatePackage(at: packageURL) { _ in })

        let paths = RecordRepositoryPaths(root: root)
        let preferences = RecordRepositoryActor(paths: paths)
        let store = ThemeStore(
            repository: preferences,
            catalog: BundledThemeCatalog(),
            themeRepository: repository,
            nowMilliseconds: { 1_800_000_000_000 }
        )
        await store.restore()
        XCTAssertTrue(store.viewState.themes.contains { $0.id == "com.example.safe-theme" })
        await store.selectTheme(id: "com.example.safe-theme")
        XCTAssertEqual(store.selectedTheme.id, "com.example.safe-theme")

        await store.restoreDefaultTheme()
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        guard case let .loaded(restoredPreference, _) = await preferences.loadThemePreferences() else {
            return XCTFail("Restore default must persist its selection before returning")
        }
        let restoredDiskRecord = try JSONDecoder().decode(ThemePreferencesRecord.self,
            from: Data(contentsOf: paths.themePreferences))
        XCTAssertEqual(restoredPreference.selectedThemeId, BuiltinThemeID.warmIsland)
        XCTAssertEqual(restoredDiskRecord, restoredPreference)
        XCTAssertEqual(restoredDiskRecord.selectedThemeId, store.selectedTheme.id,
            "Restore-default disk and effective selection agree before any later action")
        await store.selectTheme(id: "com.example.safe-theme")
        await store.deleteTheme(id: "com.example.safe-theme")

        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertEqual(store.importError, .deleteFailed)
        XCTAssertTrue(store.viewState.themes.contains { $0.id == "com.example.safe-theme" })
        let persisted = await preferences.loadThemePreferences()
        guard case let .loaded(record, _) = persisted else {
            return XCTFail("default selection must be committed before deletion")
        }
        XCTAssertEqual(record.selectedThemeId, BuiltinThemeID.warmIsland)
        let retainedSnapshot = await repository.loadInstalledThemes()
        XCTAssertEqual(retainedSnapshot.themes.map(\.id), ["com.example.safe-theme"])
    }

    func testCancellationAndAtomicReplacementFailurePreserveBusinessAndOldTheme() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let records = root.appendingPathComponent("Records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let settings = records.appendingPathComponent("Settings.json")
        let today = records.appendingPathComponent("Today.json")
        let settingsBytes = Data("settings-sentinel".utf8)
        let todayBytes = Data("today-sentinel".utf8)
        try settingsBytes.write(to: settings)
        try todayBytes.write(to: today)

        let repository = ThemeRepositoryActor(
            applicationSupportRoot: root,
            currentAppVersion: "1.0.0",
            committer: FailOnSecondCommitter()
        )
        let v1URL = try validPackage(in: root, name: "atomic-v1", version: "1.0.0")
        _ = try await repository.install(try await repository.validatePackage(at: v1URL) { _ in })

        let v2URL = try validPackage(in: root, name: "atomic-v2", version: "1.1.0")
        let v2 = try await repository.validatePackage(at: v2URL) { _ in }
        do {
            _ = try await repository.install(v2)
            XCTFail("second atomic commit must fail")
        } catch {
            XCTAssertEqual(error as? ThemeImportError, .installFailed)
        }
        let postFailureSnapshot = await repository.loadInstalledThemes()
        XCTAssertEqual(postFailureSnapshot.themes.map(\.manifest.themeVersion), ["1.0.0"])
        try assertStagingClean(root)

        let operation = Task {
            try await repository.validatePackage(at: v2URL) { _ in }
        }
        operation.cancel()
        do {
            let candidate = try await operation.value
            await repository.discard(candidate)
            XCTFail("cancelled validation unexpectedly completed")
        } catch {
            XCTAssertEqual(error as? ThemeImportError, .cancelled)
        }
        try assertStagingClean(root)
        XCTAssertEqual(try Data(contentsOf: settings), settingsBytes)
        XCTAssertEqual(try Data(contentsOf: today), todayBytes)
    }

    func testCorruptedInstalledThemeIsDisabledRetainedAndExplicitlyDeletable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let packageURL = try validPackage(in: root, name: "corrupt-after-install")
        _ = try await repository.install(try await repository.validatePackage(at: packageURL) { _ in })
        let preview = root.appendingPathComponent("Themes/com.example.safe-theme/preview.png")
        try Data("corrupt".utf8).write(to: preview)

        let snapshot = await repository.loadInstalledThemes()
        XCTAssertEqual(snapshot.themes, [])
        XCTAssertEqual(snapshot.disabledThemes.map(\.id), ["com.example.safe-theme"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        try await repository.deleteTheme(id: "com.example.safe-theme")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.deletingLastPathComponent().path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockStage8Tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        XCTAssertFalse(root.path.contains("Application Support"))
        return root
    }

    @MainActor
    func testOptionalMaskFallbackPreservesNativeHitRegionsAndBusinessRecords() async throws {
        let root = try temporaryRoot()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let transparentMask = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        var stores: [BusinessStore] = []
        var paths: [RecordRepositoryPaths] = []
        var notifications: [FakeNotificationService] = []
        var hosts: [NSHostingView<IncomePanelView>] = []
        var windows: [IncomePanel] = []
        var layouts: [PanelLayoutObservation] = []
        var settingsClicks = [0, 0]
        var hideClicks = [0, 0]
        let profile = PanelPresentationProfileRegistry().standard
        defer { windows.forEach { $0.orderOut(nil); $0.close() } }
        for index in 0..<2 {
            let path = RecordRepositoryPaths(root: root.appendingPathComponent(index == 0 ? "without-mask" : "with-mask"))
            let records = RecordRepositoryActor(paths: path)
            _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(
                wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
            let notification = FakeNotificationService(authorization: .authorized)
            let store = try BusinessStore(repository: records, nowProvider: clock,
                timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notification)
            await store.restore()
            let started = await store.send(.clockIn, source: .panel)
            XCTAssertEqual(started, .committed)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
            object["optionalCapabilities"] = [["name": "shaped-panel", "version": 7]]
            object["panelProfile"] = ["id": "future-panel@7", "fallback": "standard-panel@1"]
            var entries = [CorpusEntry("preview.png", Self.validPNG)]
            if index == 1 {
                object["visualMask"] = "mask.png"
                var hashes = try XCTUnwrap(object["hashes"] as? [String: String])
                hashes["mask.png"] = SHA256.hash(data: transparentMask).map { String(format: "%02x", $0) }.joined()
                object["hashes"] = hashes
                entries.append(CorpusEntry("mask.png", transparentMask))
            }
            entries.append(CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
            let package = try makeArchive(named: "hit-region-\(index)", entries: entries, in: root)
            let themeRepository = ThemeRepositoryActor(applicationSupportRoot: path.root, currentAppVersion: "1.0.0")
            let themes = ThemeStore(repository: records, themeRepository: themeRepository)
            await themes.restore()
            await themes.beginImport(from: package)
            let candidate = try XCTUnwrap(themes.importCandidate)
            XCTAssertEqual(candidate.ignoredOptionalCapabilities.map(\.name), ["shaped-panel"])
            await themes.installImportCandidate()
            await themes.useImportedTheme()
            XCTAssertNil(themes.importError)
            XCTAssertEqual(themes.selectedTheme.id, "com.example.safe-theme")
            XCTAssertTrue(themes.selectedTheme.manifest.decorations.isEmpty)
            let installedMask = path.root.appendingPathComponent("Themes/com.example.safe-theme/mask.png")
            if index == 1 { XCTAssertEqual(try Data(contentsOf: installedMask), transparentMask) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: installedMask.path)) }
            let layout = PanelLayoutObservation()
            let host = NSHostingView(rootView: IncomePanelView(businessStore: store, themeStore: themes,
                profile: profile, onOpenSettings: { settingsClicks[index] += 1 },
                onHide: { hideClicks[index] += 1 }, renderPulse: PanelRenderPulseCoordinator(isVisible: false),
                layoutObservation: layout))
            let window = IncomePanel(contentRect: CGRect(x: 40, y: 40, width: 320, height: 190),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            paths.append(path); stores.append(store); notifications.append(notification)
            hosts.append(host); windows.append(window); layouts.append(layout)
        }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Optional-mask native interaction did not reach its expected state")
            throw NSError(domain: "OptionalMaskHitRegion", code: 1)
        }
        func localPoint(_ topLeftPoint: CGPoint, host: NSView) -> CGPoint {
            CGPoint(x: topLeftPoint.x, y: host.isFlipped ? topLeftPoint.y : host.bounds.height - topLeftPoint.y)
        }
        func click(_ point: CGPoint, index: Int) async throws {
            let window = windows[index], host = hosts[index]
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let location = host.convert(localPoint(point, host: host), to: nil)
            // Queue both phases before dispatch, so native tracking can consume
            // mouseUp without waiting on this test's synchronous sendEvent call.
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: kind == .leftMouseDown ? 1 : 0))
                NSApp.postEvent(event, atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.05)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                until: deadline, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
                if Date() >= deadline { break }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        func nativeAmount(_ view: NSView) -> PanelAmountNativeView? {
            if let amount = view as? PanelAmountNativeView { return amount }
            return view.subviews.lazy.compactMap { nativeAmount($0) }.first
        }
        clock.set(ApplicationTestSupport.timestamp(hour: 12))
        for store in stores { await store.refresh() }
        try await wait { layouts.allSatisfy { $0.frames["primaryAction"] != nil } }
        try await wait { hosts.allSatisfy { nativeAmount($0)?.targetText == "¥200.000" } }
        for host in hosts {
            let amount = try XCTUnwrap(nativeAmount(host))
            XCTAssertFalse(amount.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(amount.targetText, "¥200.000")
        }
        XCTAssertEqual(layouts[0].frames, layouts[1].frames)
        for (name, expected) in [
            "settings": CGRect(x: 252, y: 8, width: 28, height: 28),
            "hide": CGRect(x: 280, y: 8, width: 28, height: 28),
            "primaryAction": CGRect(x: 12, y: 148, width: 296, height: 32)
        ] { XCTAssertEqual(layouts[0].frames[name], expected, name) }
        let settingsBytes = try paths.map { try Data(contentsOf: $0.settings) }
        let todayBytes = try paths.map { try Data(contentsOf: $0.today) }
        let initialToday = stores.map(\.todayRecordForValidation)
        let initialState = stores.map(\.viewState)
        let initialCalls = await notifications[0].operationLog()
        XCTAssertTrue(initialCalls.contains(.add("workday-end-2026-08-13")))
        XCTAssertEqual(stores[0].viewState?.amount, .live(try .init(validating: 200_000)))
        func compare(_ step: String) async throws {
            XCTAssertEqual(stores[0].viewState, stores[1].viewState, step)
            XCTAssertEqual(stores[0].confirmation, stores[1].confirmation, step)
            XCTAssertEqual(stores[0].settingsRecordForValidation, stores[1].settingsRecordForValidation, step)
            XCTAssertEqual(stores[0].todayRecordForValidation, stores[1].todayRecordForValidation, step)
            for index in 0..<2 {
                XCTAssertEqual(stores[index].viewState, initialState[index], step)
                XCTAssertEqual(stores[index].todayRecordForValidation, initialToday[index], step)
                XCTAssertEqual(try Data(contentsOf: paths[index].settings), settingsBytes[index], step)
                XCTAssertEqual(try Data(contentsOf: paths[index].today), todayBytes[index], step)
                let calls = await notifications[index].operationLog()
                XCTAssertEqual(calls, initialCalls, step)
            }
            XCTAssertEqual(settingsClicks[0], settingsClicks[1], step)
            XCTAssertEqual(hideClicks[0], hideClicks[1], step)
        }
        // Positive target centers and one-pixel interior primary edges, followed
        // by surrounding non-targets: sampled native hit routing, not AXPress.
        let samples: [(CGPoint, String)] = [
            (CGPoint(x: 266, y: 22), "settings"), (CGPoint(x: 294, y: 22), "hide"),
            (CGPoint(x: 160, y: 164), "primary"), (CGPoint(x: 13, y: 164), "primary"),
            (CGPoint(x: 307, y: 164), "primary"), (CGPoint(x: 160, y: 149), "primary"),
            (CGPoint(x: 160, y: 179), "primary"), (CGPoint(x: 8, y: 164), "none"),
            (CGPoint(x: 312, y: 164), "none"), (CGPoint(x: 160, y: 144), "none"),
            (CGPoint(x: 160, y: 184), "none"), (CGPoint(x: 160, y: 68), "none")
        ]
        for (point, expected) in samples {
            let beforeSettings = settingsClicks, beforeHide = hideClicks
            var targets: [String] = []
            for index in 0..<2 {
                let host = hosts[index]
                let local = localPoint(point, host: host)
                let target = try XCTUnwrap(host.hitTest(host.convert(local, to: host.superview)))
                targets.append(String(reflecting: type(of: target)) + ":" + NSStringFromRect(host.convert(target.bounds, from: target)))
                try await click(point, index: index)
                if expected == "primary" { try await wait { stores[index].confirmation != nil } }
                else { XCTAssertNil(stores[index].confirmation) }
                XCTAssertEqual(settingsClicks[index], beforeSettings[index] + (expected == "settings" ? 1 : 0))
                XCTAssertEqual(hideClicks[index], beforeHide[index] + (expected == "hide" ? 1 : 0))
            }
            XCTAssertEqual(targets[0], targets[1], "Same native hit node and frame at \(point)")
            try await compare("mouse route \(expected) at \(point)")
            if expected == "primary" {
                for index in 0..<2 {
                    try await wait { layouts[index].frames["cancel"] != nil }
                    let cancel = try XCTUnwrap(layouts[index].frames["cancel"])
                    try await click(CGPoint(x: cancel.midX, y: cancel.midY), index: index)
                    try await wait { stores[index].confirmation == nil && layouts[index].frames["primaryAction"] != nil }
                }
                try await compare("cancel preserved records at \(point)")
            }
            XCTAssertEqual(layouts[0].frames, layouts[1].frames)
        }
        // Retain both isolated fixtures. No system cursor/settings changes,
        // screenshots, true business settlement, or production-data writes.
    }

    func testOptionalProfileAndMaskUseValidatedStandardFallbackAndNeverRenderMask() async throws {
        let root = try temporaryRoot()
        let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        var base = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        base["optionalCapabilities"] = [["name": "shaped-panel", "version": 7], ["name": "layout-profile", "version": 4]]
        base["panelProfile"] = ["id": "future-panel@7", "fallback": "standard-panel@1"]
        base["layoutProfile"] = ["id": "future-layout@4", "fallback": "standard-layout@1"]
        base["visualMask"] = "mask.png"
        var hashes = try XCTUnwrap(base["hashes"] as? [String: String])
        hashes["mask.png"] = SHA256.hash(data: Self.validPNG).map { String(format: "%02x", $0) }.joined()
        base["hashes"] = hashes
        func archive(_ name: String, object: [String: Any], mask: Data = Stage8ThemeImportTests.validPNG) throws -> URL {
            try makeArchive(named: name, entries: [
                CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])),
                CorpusEntry("preview.png", Self.validPNG), CorpusEntry("mask.png", mask)
            ], in: root)
        }
        let candidate = try await repository.validatePackage(at: archive("optional-fallback", object: base)) { _ in }
        XCTAssertEqual(Set(candidate.ignoredOptionalCapabilities.map(\.name)), ["shaped-panel", "layout-profile"])
        XCTAssertTrue(candidate.validatedTheme.manifest.decorations.isEmpty)
        XCTAssertFalse(candidate.validatedTheme.manifest.decorations.values.contains("mask.png"))
        let installed = try await repository.install(candidate)
        XCTAssertEqual(installed.id, "com.example.safe-theme")
        let restored = await ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0").loadInstalledThemes()
        XCTAssertEqual(restored.themes.map(\.id), [installed.id])
        XCTAssertTrue(restored.themes[0].manifest.decorations.isEmpty)

        for variant in ["required", "missing-fallback", "unknown-fallback", "missing-optional", "unknown-subkey", "invalid-standard", "invalid-mask"] {
            var bad = base
            switch variant {
            case "required": bad["requiredCapabilities"] = [["name": "shaped-panel", "version": 7]]
            case "missing-fallback": bad["panelProfile"] = "future-panel@7"
            case "unknown-fallback": bad["layoutProfile"] = ["id": "future-layout@4", "fallback": "unknown@1"]
            case "missing-optional": bad["optionalCapabilities"] = []
            case "unknown-subkey": bad["panelProfile"] = ["id": "future-panel@7", "fallback": "standard-panel@1", "execute": "none"]
            case "invalid-standard": bad["tokens"] = ["light": [:]]
            default: break
            }
            let badURL = try archive(variant, object: bad,
                mask: variant == "invalid-mask" ? Data("not-a-mask".utf8) : Self.validPNG)
            let diagnostics = await validationDiagnostics(repository, badURL)
            XCTAssertFalse(diagnostics.isEmpty, variant)
            if variant == "invalid-mask" { XCTAssertTrue(diagnostics.contains { $0.item == "mask.png" }) }
            let stillInstalled = await repository.loadInstalledThemes()
            XCTAssertEqual(stillInstalled.themes.map(\.id), [installed.id], variant)
        }
    }

    @MainActor
    func testStartupRevalidatesActualManifestAndFallsBackWithoutTouchingBusinessRecords() async throws {
        for invalidField in ["schemaVersion", "minimumAppVersion", "requiredCapabilities", "panelProfile", "layoutProfile"] {
            let root = try temporaryRoot()
            let repository = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
            let package = try validPackage(in: root, name: "startup-" + invalidField)
            _ = try await repository.install(try await repository.validatePackage(at: package) { _ in })
            let preferences = EphemeralThemePreferencesRepository()
            let store = ThemeStore(repository: preferences, themeRepository: repository)
            await store.restore()
            await store.selectTheme(id: "com.example.safe-theme")
            XCTAssertEqual(store.selectedTheme.id, "com.example.safe-theme")
            let themeRoot = root.appendingPathComponent("Themes/com.example.safe-theme")
            let manifestURL = themeRoot.appendingPathComponent("manifest.json")
            let metadataURL = themeRoot.appendingPathComponent(".incomeclock-installed.json")
            let validManifest = try Data(contentsOf: manifestURL)
            let validMetadata = try Data(contentsOf: metadataURL)
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifest) as? [String: Any])
            switch invalidField {
            case "schemaVersion": manifest[invalidField] = 9
            case "minimumAppVersion": manifest[invalidField] = "9.0.0"
            case "requiredCapabilities": manifest[invalidField] = [["name": "standard-theme", "version": 99]]
            case "panelProfile": manifest[invalidField] = "retired-panel@9"
            default: manifest[invalidField] = "retired-layout@9"
            }
            // Model an installed package whose original declaration is no longer supported.
            // Keep the cached packageManifest and normalizedManifest deliberately valid:
            // startup must inspect actual manifest.json rather than trust those caches.
            let changedManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: validMetadata) as? [String: Any])
            var receipt = try XCTUnwrap(metadata["record"] as? [String: Any])
            receipt["manifestSHA256"] = SHA256.hash(data: changedManifest).map { String(format: "%02x", $0) }.joined()
            metadata["record"] = receipt
            try changedManifest.write(to: manifestURL)
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL)
            let businessPaths = RecordRepositoryPaths(root: root)
            let businessRepository = RecordRepositoryActor(paths: businessPaths)
            let settings = try await businessRepository.saveSettings(
                ApplicationTestSupport.proposedSettings(wageCents: 90_000), expectedRevision: nil)
            let calendar = try BusinessWorkdayCalendar(timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            let today = try await businessRepository.saveToday(
                calendar.proposedToday(from: settings, at: ApplicationTestSupport.timestamp(hour: 10)),
                expectedRevision: nil)
            let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 12))
            let business = try BusinessStore(repository: RecordRepositoryActor(paths: businessPaths),
                nowProvider: clock, timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
            await business.restore()
            XCTAssertEqual(business.viewState?.state, .earning, invalidField)
            XCTAssertEqual(business.viewState?.amount, .live(try .init(validating: 200_000)), invalidField)
            XCTAssertEqual(business.todayRecordForValidation, today, invalidField)
            let businessBeforeFallback = business.viewState
            let todayURL = businessPaths.today
            let settingsURL = businessPaths.settings
            let todayBytes = try Data(contentsOf: todayURL)
            let settingsBytes = try Data(contentsOf: settingsURL)
            let restarted = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
            let snapshot = await restarted.loadInstalledThemes()
            XCTAssertTrue(snapshot.themes.isEmpty, invalidField)
            XCTAssertEqual(snapshot.disabledThemes.map(\.id), ["com.example.safe-theme"], invalidField)
            let restoredStore = ThemeStore(repository: preferences, themeRepository: restarted)
            await restoredStore.restore()
            XCTAssertEqual(restoredStore.selectedTheme.id, BuiltinThemeID.warmIsland, invalidField)
            XCTAssertNotNil(restoredStore.viewState.fallbackNotice, invalidField)
            XCTAssertFalse(restoredStore.viewState.isProcessing, invalidField)
            await business.refresh()
            XCTAssertEqual(business.viewState, businessBeforeFallback, invalidField)
            XCTAssertEqual(business.settingsRecordForValidation, settings, invalidField)
            XCTAssertEqual(business.todayRecordForValidation, today, invalidField)
            clock.set(ApplicationTestSupport.timestamp(hour: 13))
            await business.refresh()
            XCTAssertEqual(business.viewState?.state, .earning, invalidField)
            XCTAssertEqual(business.viewState?.amount, .live(try .init(validating: 300_000)), invalidField)
            XCTAssertEqual(business.viewState?.clockInAt, ApplicationTestSupport.timestamp(hour: 10), invalidField)
            clock.set(ApplicationTestSupport.timestamp(hour: 18))
            await business.refresh()
            XCTAssertEqual(business.viewState?.state, .awaitingClockOut, invalidField)
            XCTAssertEqual(business.viewState?.amount, .rounded(try .init(validating: 80_000)), invalidField)
            let amountAtScheduledEnd = business.viewState?.amount
            clock.set(ApplicationTestSupport.timestamp(hour: 20))
            await business.refresh()
            XCTAssertEqual(business.viewState?.amount, amountAtScheduledEnd, invalidField)
            XCTAssertEqual(business.todayRecordForValidation, today, invalidField)
            XCTAssertEqual(try Data(contentsOf: todayURL), todayBytes, invalidField)
            XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBytes, invalidField)
            XCTAssertEqual(try Data(contentsOf: manifestURL), changedManifest, invalidField)
            // Repairing the package restores availability; rejection never deletes it.
            try validManifest.write(to: manifestURL); try validMetadata.write(to: metadataURL)
            let repaired = await restarted.loadInstalledThemes()
            XCTAssertEqual(repaired.themes.map(\.id), ["com.example.safe-theme"], invalidField)
            let businessBeforeThemeRepair = business.viewState
            await restoredStore.restore()
            await restoredStore.selectTheme(id: "com.example.safe-theme")
            await business.refresh()
            XCTAssertEqual(business.viewState, businessBeforeThemeRepair, invalidField)
            XCTAssertEqual(try Data(contentsOf: todayURL), todayBytes, invalidField)
            XCTAssertEqual(try Data(contentsOf: settingsURL), settingsBytes, invalidField)
        }
    }

    @MainActor
    func testLegacy05PackageWithoutCapabilityFieldsInstallsSelectsAndRestores() async throws {
        let root = try temporaryRoot()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        for field in ["requiredCapabilities", "optionalCapabilities", "panelProfile", "layoutProfile", "visualMask", "extensions"] {
            manifest.removeValue(forKey: field)
        }
        let package = try makeArchive(named: "legacy05", entries: [
            CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])),
            CorpusEntry("preview.png", Self.validPNG)
        ], in: root)
        let repository = ThemeRepositoryActor(applicationSupportRoot: root)
        let installed = try await repository.install(try await repository.validatePackage(at: package) { _ in })
        let preferences = EphemeralThemePreferencesRepository()
        let store = ThemeStore(repository: preferences, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: installed.id)
        XCTAssertEqual(store.selectedTheme.id, "com.example.safe-theme")
        let restartedRepository = ThemeRepositoryActor(applicationSupportRoot: root)
        let snapshot = await restartedRepository.loadInstalledThemes()
        XCTAssertEqual(snapshot.themes.map(\.id), [installed.id])
        XCTAssertTrue(snapshot.disabledThemes.isEmpty)
        let restarted = ThemeStore(repository: preferences, themeRepository: restartedRepository)
        await restarted.restore()
        XCTAssertEqual(restarted.selectedTheme.id, installed.id)
        XCTAssertEqual(restarted.selectedTheme.manifest.light, installed.manifest.light)
        XCTAssertEqual(restarted.selectedTheme.manifest.dark, installed.manifest.dark)
        XCTAssertNil(restarted.viewState.fallbackNotice)
    }

    @MainActor
    func testChangedAppVersionRevalidatesEveryInstalledThemeAndKeepsCompatiblePackages() async throws {
        let root = try temporaryRoot()
        let initial = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "2.0.0")
        var bytesByID: [String: Data] = [:]
        for (id, minimum) in [("com.example.old-compatible", "0.1.0"),
                              ("com.example.new-first", "2.0.0"), ("com.example.new-second", "1.5.0")] {
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData(id: id)) as? [String: Any])
            manifest["minimumAppVersion"] = minimum
            let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            let package = try makeArchive(named: id, entries: [CorpusEntry("manifest.json", bytes),
                CorpusEntry("preview.png", Self.validPNG)], in: root)
            _ = try await initial.install(try await initial.validatePackage(at: package) { _ in })
            bytesByID[id] = try Data(contentsOf: root.appendingPathComponent("Themes/" + id + "/manifest.json"))
        }
        let before = await initial.loadInstalledThemes()
        XCTAssertEqual(before.themes.count, 3)
        let preferences = EphemeralThemePreferencesRepository()
        let selected = ThemeStore(repository: preferences, themeRepository: initial)
        await selected.restore()
        await selected.selectTheme(id: "com.example.new-second")
        // A downgrade is an application-version change that makes two installed
        // declarations incompatible without rewriting any package or metadata.
        let olderApplication = ThemeRepositoryActor(applicationSupportRoot: root, currentAppVersion: "1.0.0")
        let after = await olderApplication.loadInstalledThemes()
        XCTAssertEqual(after.themes.map(\.id), ["com.example.old-compatible"])
        XCTAssertEqual(Set(after.disabledThemes.map(\.id)), Set(["com.example.new-first", "com.example.new-second"]))
        let restored = ThemeStore(repository: preferences, themeRepository: olderApplication)
        await restored.restore()
        XCTAssertEqual(restored.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertNotNil(restored.viewState.fallbackNotice)
        for (id, bytes) in bytesByID {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Themes/" + id + "/manifest.json")), bytes)
        }
        let compatibleAgain = await initial.loadInstalledThemes()
        XCTAssertEqual(Set(compatibleAgain.themes.map(\.id)), Set(bytesByID.keys))
        XCTAssertTrue(compatibleAgain.disabledThemes.isEmpty)
    }

    @MainActor
    func testSelectedThemeUpgradeReconcilesAppearanceChangedDuringHeldInstall() async throws {
        let root = try temporaryRoot()
        let base = ThemeRepositoryActor(applicationSupportRoot: root)
        let first = try validPackage(in: root, name: "initial")
        _ = try await base.install(try await base.validatePackage(at: first) { _ in })
        let repository = HeldThemeInstallRepository(base: base)
        let preferences = EphemeralThemePreferencesRepository()
        let store = ThemeStore(repository: preferences, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: "com.example.safe-theme")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData(version: "1.1.0")) as? [String: Any])
        manifest["appearance"] = ["supportedModes": ["light"]]
        let upgrade = try makeArchive(named: "upgrade-light-only", entries: [
            CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: manifest)),
            CorpusEntry("preview.png", Self.validPNG)], in: root)
        await store.beginImport(from: upgrade)
        XCTAssertNotNil(store.importCandidate)
        await repository.holdNextInstall()
        let install = Task { await store.installImportCandidate() }
        try await repository.waitUntilHeld()
        await store.setAppearance(.dark)
        XCTAssertEqual(store.selectedTheme.id, "com.example.safe-theme", "Old package supports dark")
        await repository.release()
        await install.value
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertEqual(store.effectiveTheme(systemIsDark: true), .warmIslandFallback)
        XCTAssertNotNil(store.viewState.fallbackNotice)
        XCTAssertEqual(store.viewState.themes.first { $0.id == "com.example.safe-theme" }?.manifest.themeVersion, "1.1.0")
        guard case let .loaded(saved, _) = await preferences.loadThemePreferences() else { return XCTFail("Missing preference") }
        XCTAssertEqual(saved.selectedThemeId, BuiltinThemeID.warmIsland)
    }

    @MainActor
    func testInstallCompletingDuringHeldAutomaticFallbackSaveRetainsNewCatalogEntry() async throws {
        let root = try temporaryRoot()
        let repository = ThemeRepositoryActor(applicationSupportRoot: root)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData()) as? [String: Any])
        manifest["appearance"] = ["supportedModes": ["light"]]
        let old = try makeArchive(named: "old-light-only", entries: [
            CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: manifest)),
            CorpusEntry("preview.png", Self.validPNG)], in: root)
        _ = try await repository.install(try await repository.validatePackage(at: old) { _ in })
        let preferences = HeldThemeFallbackPreferences()
        let store = ThemeStore(repository: preferences, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: "com.example.safe-theme")
        let new = try makeArchive(named: "new-independent", entries: [
            CorpusEntry("manifest.json", try validManifestData(id: "com.example.new-independent")),
            CorpusEntry("preview.png", Self.validPNG)], in: root)
        await store.beginImport(from: new)
        XCTAssertNotNil(store.importCandidate)
        await preferences.holdNextSave()
        let fallback = Task { await store.reconcileAppearance(systemIsDark: true) }
        try await preferences.waitUntilHeld()
        XCTAssertTrue(store.viewState.isProcessing)
        await store.installImportCandidate()
        XCTAssertTrue(store.viewState.isProcessing, "Catalog installation cannot release a pending preference transaction")
        XCTAssertTrue(store.viewState.themes.contains { $0.id == "com.example.new-independent" })
        await preferences.release()
        await fallback.value
        XCTAssertFalse(store.viewState.isProcessing)
        XCTAssertTrue(store.viewState.themes.contains { $0.id == "com.example.new-independent" })
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.warmIsland)
        guard case let .loaded(saved, _) = await preferences.loadThemePreferences() else { return XCTFail("Missing fallback preference") }
        XCTAssertEqual(saved.selectedThemeId, BuiltinThemeID.warmIsland)
        let installed = await repository.loadInstalledThemes()
        XCTAssertEqual(Set(installed.themes.map(\.id)), Set(["com.example.safe-theme", "com.example.new-independent"]))
    }

    @MainActor
    func testHostedPendingThemeControlsExposeSharedDisabledReasons() async throws {
        let root = try temporaryRoot()
        let repository = HeldThemeInstallRepository(base: ThemeRepositoryActor(applicationSupportRoot: root))
        let preferences = HeldThemeFallbackPreferences()
        let themes = ThemeStore(repository: preferences, themeRepository: repository)
        await themes.restore()
        let business = try BusinessStore(repository: BusinessRecordRepositorySpy(),
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 12)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier)
        await business.restore()
        let environment = AppEnvironment(businessStore: business, panelController: PanelControllerSpy(),
            themeStore: themes, loginItemService: FakeLoginItemService())
        let general = HostedSettings(IncomeSettingsView(environment: environment))
        let host = HostedSettings(IncomeSettingsView(environment: environment))
        var generalClosed = false
        defer { if !generalClosed { general.close() }; host.close() }
        try general.press(try await general.element(identifier: "settings-nav-通用"))
        _ = try await general.element(identifier: "settings-page-通用")
        try host.press(try await host.element(identifier: "settings-nav-外观与皮肤"))
        _ = try await host.element(identifier: "settings-page-外观与皮肤")
        let reset = try await host.button(label: "恢复默认皮肤", scope: "settings-page-外观与皮肤", enabled: false)
        XCTAssertTrue(host.help(reset).contains("正在使用默认皮肤"))
        try host.press(try await host.element(identifier: "theme-preview-" + BuiltinThemeID.windowCompanion))
        _ = try await host.element(identifier: "theme-details-preview")
        await preferences.holdNextSave()
        defer { Task { await preferences.release() } }
        let preference = Task { await themes.setSoundsEnabled(true) }
        try await preferences.waitUntilHeld()
        // Button/card and native segmented/toggle/pop-up kinds consume the same real held Store state.
        let controls: [(HostedSettings, NSObject)] = [
            (host, try await host.element(identifier: "theme-preview-" + BuiltinThemeID.windowCompanion)),
            (host, try await host.element(identifier: "theme-use")),
            (host, try await host.button(label: "恢复默认皮肤", scope: "settings-page-外观与皮肤")),
            (host, try await host.control(role: "AXPopUpButton", scope: "settings-page-外观与皮肤")),
            (host, try await host.control(role: "AXCheckBox", scope: "settings-page-外观与皮肤")),
            (general, try await general.control(role: "AXRadioGroup", scope: "settings-page-通用")),
            (general, try await general.control(role: "AXCheckBox", label: "皮肤提示音", scope: "settings-page-通用"))
        ]
        for (view, control) in controls {
            XCTAssertEqual(view.boolAttribute(control, "isAccessibilityEnabled"), false)
            XCTAssertTrue(view.help(control).contains("正在保存皮肤偏好") || view.containsText("正在保存皮肤偏好"),
                "The disabled native control has shared help or a co-present pending explanation")
        }
        XCTAssertNotNil(host.find(identifier: "theme-details-preview"), "Read-only preview remains present")
        await preferences.release()
        await preference.value
        general.close()
        generalClosed = true

        // Reuse one held install, rather than another validation corpus or native chooser run.
        let package = try validPackage(in: root, name: "held-disabled-controls")
        await themes.beginImport(from: package)
        let candidate = try XCTUnwrap(themes.importCandidate)
        for _ in 0..<100 {
            if host.window.attachedSheet != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let sheet = try XCTUnwrap(host.window.attachedSheet)
        _ = try await host.element(identifier: "theme-import-preview", root: sheet)
        await repository.holdNextInstall()
        defer { Task { await repository.release() } }
        let installation = Task { await themes.installImportCandidate() }
        try await repository.waitUntilHeld()
        XCTAssertEqual(themes.importProgress?.stage, .committing)
        let entry = try await host.element(identifier: "theme-import-open", root: host.window)
        XCTAssertEqual(host.boolAttribute(entry, "isAccessibilityEnabled"), false)
        XCTAssertTrue(host.help(entry).contains("正在处理一个皮肤文件"))
        for id in ["theme-import-cancel", "theme-import-confirm"] {
            let button = try await host.element(identifier: id, root: sheet)
            XCTAssertEqual(host.boolAttribute(button, "isAccessibilityEnabled"), false)
        }
        let heldCancel = try await host.element(identifier: "theme-import-cancel", root: sheet)
        XCTAssertTrue(host.help(heldCancel).contains("正在完成安装"))
        // UI15.6 forbids cancellation; UI15.7 permits preview-state selection. There is
        // no Contract requirement to disable that local picker or the file chooser.
        // Check the real mutation guard instead of creating an unsupported disabled rule.
        await themes.beginImport(from: package)
        await themes.installImportCandidate()
        XCTAssertEqual(themes.importCandidate?.id, candidate.id)
        XCTAssertEqual(themes.importProgress?.stage, .committing)
        host.dumpAccessibility(reason: "Held theme import actual controls; preview picker not required disabled", root: sheet)
        await repository.release()
        await installation.value
        XCTAssertNil(themes.importError)
    }

    @MainActor
    func testHostedImportCommitRejectsEscapeAndCancelUntilInstallationCompletes() async throws {
        let root = try temporaryRoot()
        let repository = HeldThemeInstallRepository(base: ThemeRepositoryActor(applicationSupportRoot: root))
        let store = ThemeStore(repository: EphemeralThemePreferencesRepository(), themeRepository: repository)
        await store.restore()
        let host = HostedSettings(ScrollView { ThemeAppearanceSettingsView(themeStore: store) })
        defer { host.close() }
        let package = try validPackage(in: root, name: "held-ui-install")
        await store.beginImport(from: package)
        let candidate = try XCTUnwrap(store.importCandidate)
        for _ in 0..<100 {
            if !host.window.sheets.isEmpty { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let sheet = try XCTUnwrap(host.window.sheets.first)
        await repository.holdNextInstall()
        try host.press(try await host.button(label: "安装皮肤", scope: "theme-import-preview", root: sheet))
        try await repository.waitUntilHeld()
        XCTAssertEqual(store.importProgress?.stage, .committing)
        let cancel = try await host.button(label: "取消", scope: "theme-import-preview", root: sheet, enabled: false)
        XCTAssertEqual(host.boolAttribute(cancel, "isAccessibilityEnabled"), false)
        try await host.sendKey(code: 53, characters: "\u{1b}", target: sheet)
        // Also verify the model rejects a non-UI dismissal during commit.
        await store.dismissImportCandidate()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.importCandidate?.id, candidate.id)
        XCTAssertFalse(host.window.sheets.isEmpty)
        XCTAssertNil(store.importError)
        await repository.release()
        for _ in 0..<100 {
            if store.importCandidate == nil && host.window.sheets.isEmpty { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNil(store.importCandidate)
        XCTAssertTrue(host.window.sheets.isEmpty)
        XCTAssertNil(store.importError)
        XCTAssertEqual(store.lastInstalledThemeID, candidate.validatedTheme.id)
        XCTAssertTrue(store.viewState.themes.contains { $0.id == candidate.validatedTheme.id })
    }

    @MainActor
    func testEarningThemeSwitchHeldUpgradeDeleteFallbackPreservesFullBusinessTrajectory() async throws {
        let root = try temporaryRoot()
        let themedPaths = RecordRepositoryPaths(root: root.appendingPathComponent("themed"))
        let controlPaths = RecordRepositoryPaths(root: root.appendingPathComponent("control"))
        let records = RecordRepositoryActor(paths: themedPaths)
        let controlRecords = RecordRepositoryActor(paths: controlPaths)
        for repository in [records, controlRecords] {
            _ = try await repository.saveSettings(ApplicationTestSupport.proposedSettings(
                wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
        }
        let notifications = FakeNotificationService(authorization: .authorized)
        let controlNotifications = FakeNotificationService(authorization: .authorized)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let business = try BusinessStore(repository: records, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        let control = try BusinessStore(repository: controlRecords, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: controlNotifications)
        let base = ThemeRepositoryActor(applicationSupportRoot: themedPaths.root)
        let repository = HeldThemeInstallRepository(base: base)
        let themes = ThemeStore(repository: records, themeRepository: repository)
        let environment = AppEnvironment(businessStore: business, panelController: PanelControllerSpy(), themeStore: themes)
        await environment.start()
        await control.restore()
        let start = await business.send(.clockIn, source: .panel)
        let controlStart = await control.send(.clockIn, source: .panel)
        XCTAssertEqual(start, .committed)
        XCTAssertEqual(controlStart, .committed)
        let todayBytes = try Data(contentsOf: themedPaths.today)
        let settingsBytes = try Data(contentsOf: themedPaths.settings)
        let notificationBaseline = await notifications.operationLog()
        XCTAssertTrue(notificationBaseline.contains(.add("workday-end-2026-08-13")))

        func compare(_ step: String, unchangedToday: Bool = true,
                     expectedNotificationDelta: [FakeNotificationService.Operation] = []) async throws {
            await business.refresh()
            await control.refresh()
            XCTAssertEqual(business.viewState, control.viewState, step)
            XCTAssertEqual(business.todayRecordForValidation, control.todayRecordForValidation, step)
            XCTAssertEqual(business.settingsRecordForValidation, control.settingsRecordForValidation, step)
            XCTAssertEqual(try Data(contentsOf: themedPaths.settings), settingsBytes, step)
            XCTAssertEqual(try Data(contentsOf: themedPaths.today), try Data(contentsOf: controlPaths.today), step)
            if unchangedToday { XCTAssertEqual(try Data(contentsOf: themedPaths.today), todayBytes, step) }
            let calls = await notifications.operationLog()
            let controlCalls = await controlNotifications.operationLog()
            XCTAssertEqual(calls, controlCalls, step)
            XCTAssertEqual(calls, notificationBaseline + expectedNotificationDelta,
                "Exact notification trajectory (theme/tick delta is zero): " + step)
            XCTAssertNil(business.notificationPreferenceError, step)
            XCTAssertEqual(business.notificationDiagnostics, control.notificationDiagnostics, step)
        }
        // P22-064: vary an actual standard-profile value in the production
        // presentation while the independent control keeps the original profile.
        // This injected test value does not replace the product registry default.
        let standard = PanelPresentationProfileRegistry().standard
        let changed = PanelPresentationProfileRegistry(profiles: [PanelPresentationProfile(
            id: standard.id, contentSize: CGSize(width: 336, height: 206),
            contentSafeArea: CGRect(x: 12, y: 8, width: 312, height: 188),
            primaryDragRegion: standard.primaryDragRegion, defaultEdgeOffset: 28)]).standard
        let themedPulse = PanelRenderPulseCoordinator(isVisible: false)
        let controlPulse = PanelRenderPulseCoordinator(isVisible: false)
        let controlThemes = ThemeStore()
        await controlThemes.restore()
        let themedHost = NSHostingView(rootView: IncomePanelView(businessStore: business,
            themeStore: themes, profile: standard, onOpenSettings: {}, onHide: {}, renderPulse: themedPulse))
        let controlHost = NSHostingView(rootView: IncomePanelView(businessStore: control,
            themeStore: controlThemes, profile: standard, onOpenSettings: {}, onHide: {}, renderPulse: controlPulse))
        let windows = [themedHost, controlHost].map { host -> NSWindow in
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: standard.contentSize),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            return window
        }
        defer { windows.forEach { $0.orderOut(nil); $0.close() } }
        XCTAssertEqual(themedHost.fittingSize, standard.contentSize)
        XCTAssertEqual(controlHost.fittingSize, standard.contentSize)
        XCTAssertNotEqual(changed, standard)
        XCTAssertEqual(business.viewState?.state, .earning)
        themedHost.rootView = IncomePanelView(businessStore: business, themeStore: themes,
            profile: changed, onOpenSettings: {}, onHide: {}, renderPulse: themedPulse)
        windows[0].setContentSize(changed.contentSize)
        themedHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(themedHost.fittingSize, changed.contentSize,
            "The production profile frame must actually consume the changed value")
        XCTAssertEqual(controlHost.fittingSize, standard.contentSize)
        try await compare("standard Profile changed during EARNING")

        clock.set(ApplicationTestSupport.timestamp(hour: 12))
        await themes.beginImport(from: try validPackage(in: root, name: "earning-initial"))
        await themes.installImportCandidate()
        await themes.useImportedTheme()
        XCTAssertEqual(themes.selectedTheme.id, "com.example.safe-theme")
        try await compare("switch")
        XCTAssertEqual(business.viewState?.amount, .live(try .init(validating: 200_000)))
        await themes.beginImport(from: try validPackage(in: root, name: "earning-upgrade", version: "1.1.0"))
        XCTAssertNotNil(themes.importCandidate)
        await repository.holdNextInstall()
        let installation = Task { await themes.installImportCandidate() }
        defer { Task { await repository.release() } }
        do { try await repository.waitUntilHeld() }
        catch { await repository.release(); await installation.value; throw error }
        XCTAssertEqual(themes.importProgress?.stage, .committing)
        XCTAssertEqual(themes.selectedTheme.manifest.themeVersion, "1.0.0")
        clock.set(ApplicationTestSupport.timestamp(hour: 13))
        try await compare("real installation suspended across earning tick")
        XCTAssertEqual(business.viewState?.amount, .live(try .init(validating: 300_000)))
        await repository.release()
        await installation.value
        XCTAssertNil(themes.importError)
        XCTAssertEqual(themes.selectedTheme.manifest.themeVersion, "1.1.0")
        try await compare("upgrade committed")
        clock.set(ApplicationTestSupport.timestamp(hour: 14))
        await themes.deleteTheme(id: "com.example.safe-theme")
        XCTAssertNil(themes.importError)
        XCTAssertEqual(themes.selectedTheme.id, BuiltinThemeID.warmIsland)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            themedPaths.root.appendingPathComponent("Themes/com.example.safe-theme").path))
        guard case let .loaded(saved, _) = await records.loadThemePreferences() else {
            return XCTFail("Missing durable fallback preference")
        }
        XCTAssertEqual(saved.selectedThemeId, BuiltinThemeID.warmIsland)
        try await compare("delete and durable fallback")
        XCTAssertEqual(business.viewState?.state, .earning)
        XCTAssertEqual(business.viewState?.amount, .live(try .init(validating: 400_000)))
        clock.set(ApplicationTestSupport.timestamp(hour: 18))
        try await compare("scheduled stop")
        XCTAssertEqual(business.viewState?.state, .awaitingClockOut)
        XCTAssertEqual(business.viewState?.amount, .rounded(try .init(validating: 80_000)))
        clock.set(ApplicationTestSupport.timestamp(hour: 20))
        try await compare("late clock does not grow earnings")
        let finish = await business.send(.requestClockOut, source: .panel)
        let controlFinish = await control.send(.requestClockOut, source: .panel)
        XCTAssertEqual(finish, .committed)
        XCTAssertEqual(controlFinish, .committed)
        // This fixture settles at 20:00, after the 18:00 scheduled end, so
        // commitClockOut must not cancel an already-due notification. An early
        // settlement would instead require [.remove(identifier), .pending].
        try await compare("final settlement", unchangedToday: false, expectedNotificationDelta: [])
        XCTAssertEqual(business.viewState?.state, .completed)
        XCTAssertEqual(business.viewState?.amount, .rounded(try .init(validating: 80_000)))
        withExtendedLifetime(environment) {}
    }

    @MainActor
    func testPersistedUserThemeRestoresInFreshProcessesWithoutChangingBusinessOrNotifications() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomeClockRecovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let paths = RecordRepositoryPaths(root: root)
        let records = RecordRepositoryActor(paths: paths)
        _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(
            wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
        let clock = MutableTestClock(ApplicationTestSupport.timestamp(hour: 10))
        let notifications = FakeNotificationService(authorization: .authorized)
        let business = try BusinessStore(repository: records, nowProvider: clock,
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        await business.restore()
        let start = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(start, .committed)
        let themes = ThemeStore(repository: records,
            themeRepository: ThemeRepositoryActor(applicationSupportRoot: root))
        await themes.restore()
        await themes.beginImport(from: try validPackage(in: root, name: "process-theme", version: "1.2.0"))
        await themes.installImportCandidate()
        await themes.useImportedTheme()
        await themes.setAppearance(.dark)
        await themes.setSoundsEnabled(true)
        XCTAssertEqual(themes.selectedTheme.id, "com.example.safe-theme")
        let todayBytes = try Data(contentsOf: paths.today)
        let settingsBytes = try Data(contentsOf: paths.settings)
        let preferencesBytes = try Data(contentsOf: paths.themePreferences)
        var childPIDs: Set<Int32> = []
        for hour in [12, 18, 20] {
            clock.set(ApplicationTestSupport.timestamp(hour: hour))
            await business.refresh()
            let expected = Stage9RecoverySnapshot.object(business.viewState)
            let output = root.appendingPathComponent("theme-restore-\(hour).json")
            let child = try await Stage9IsolatedApplicationProcess.launch(root: root, mode: "theme-restore",
                output: output, time: ApplicationTestSupport.timestamp(hour: hour))
            defer { child.terminateIfRunning() }
            let result = try await child.readResult()
            try await child.waitForTermination()
            XCTAssertFalse(child.isRunning, "Isolated reader must exit after its validated result/ack handshake")
            XCTAssertTrue(childPIDs.insert(child.processIdentifier).inserted)
            XCTAssertNotEqual(child.processIdentifier, ProcessInfo.processInfo.processIdentifier)
            XCTAssertEqual(result["pid"] as? Int32, child.processIdentifier)
            XCTAssertEqual(result["root"] as? String, root.resolvingSymlinksInPath().path)
            XCTAssertEqual(result["selectedThemeID"] as? String, "com.example.safe-theme")
            XCTAssertEqual(result["selectedThemeVersion"] as? String, "1.2.0")
            XCTAssertEqual(result["appearance"] as? String, "dark")
            XCTAssertEqual(result["soundsEnabled"] as? Bool, true)
            XCTAssertEqual(result["fallbackNoticeNil"] as? Bool, true)
            XCTAssertEqual(result["themeErrorNil"] as? Bool, true)
            for key in ["businessBeforeThemeRestore", "businessAfterThemeRestore"] {
                let snapshot = try XCTUnwrap(result[key] as? [String: Any])
                XCTAssertEqual(NSDictionary(dictionary: snapshot), NSDictionary(dictionary: expected), key)
                XCTAssertEqual(snapshot.count, 19, "Every BusinessViewState field is bound")
            }
            let calls = hour < 18 ? ["pending"] : []
            XCTAssertEqual(result["notificationCallsBefore"] as? [String], calls)
            XCTAssertEqual(result["notificationCallsAfter"] as? [String], calls)
            XCTAssertEqual(result["writes"] as? Int, 0)
            XCTAssertEqual(result["writesAfterThemeRestore"] as? Int, 0)
            XCTAssertEqual(try Data(contentsOf: paths.today), todayBytes)
            XCTAssertEqual(try Data(contentsOf: paths.settings), settingsBytes)
            XCTAssertEqual(try Data(contentsOf: paths.themePreferences), preferencesBytes)
            let attachment = XCTAttachment(contentsOfFile: output)
            attachment.name = "theme-fresh-process-\(hour)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(business.viewState?.state, .awaitingClockOut)
        XCTAssertEqual(business.viewState?.amount, .rounded(try .init(validating: 80_000)))
    }



    @MainActor
    func testAudioPayloadMustFullyDecodeBeforeImportPreviewWithoutSideEffects() async throws {
        // A real AAC encoder supplies the positive control. Only mdat payload
        // bytes change in the negative case; container headers remain valid.
        let fixtureRoot = try ApplicationTestSupport.makeResume008FixtureRoot(
            name: "sound-full-decode-fixtures", reservedGrowthBytes: 512 * 1_024)
        let validURL = fixtureRoot.appendingPathComponent("valid.m4a")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: validURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ])
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 4_410))
            let channel = try XCTUnwrap(pcm.floatChannelData).pointee
            channel.initialize(repeating: 0, count: 4_410)
            pcm.frameLength = 4_410
            try writer.write(from: pcm)
        } // Release writer to finalize M4A headers (works on macOS13).
        let validBytes = try Data(contentsOf: validURL)
        guard validBytes.count <= 64 * 1_024 else {
            XCTFail("Encoded AAC fixture exceeded64KiB"); throw ThemeImportError.installFailed
        }
        var corruptBytes = validBytes
        func big32(_ offset: Int) -> UInt64 {
            validBytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var offset = 0
        var payload: Range<Int>?
        while offset + 8 <= validBytes.count {
            var atomBytes = big32(offset)
            var header = 8
            if atomBytes == 1 {
                guard offset + 16 <= validBytes.count else { throw ThemeImportError.installFailed }
                atomBytes = (big32(offset + 8) << 32) | big32(offset + 12)
                header = 16
            }
            if atomBytes == 0 { atomBytes = UInt64(validBytes.count - offset) }
            guard atomBytes >= UInt64(header), atomBytes <= UInt64(validBytes.count - offset) else {
                throw ThemeImportError.installFailed
            }
            if validBytes.subdata(in: (offset + 4)..<(offset + 8)) == Data("mdat".utf8) {
                payload = (offset + header)..<(offset + Int(atomBytes))
                break
            }
            offset += Int(atomBytes)
        }
        let range = try XCTUnwrap(payload)
        XCTAssertFalse(range.isEmpty)
        corruptBytes.replaceSubrange(range, with: repeatElement(UInt8(0xff), count: range.count))
        XCTAssertEqual(validBytes.count, corruptBytes.count)
        XCTAssertEqual(validBytes.prefix(range.lowerBound), corruptBytes.prefix(range.lowerBound))
        XCTAssertEqual(validBytes.suffix(from: range.upperBound), corruptBytes.suffix(from: range.upperBound))
        let corruptURL = fixtureRoot.appendingPathComponent("corrupt-payload.m4a")
        try corruptBytes.write(to: corruptURL, options: .withoutOverwriting)

        let valid = try AVAudioFile(forReading: validURL)
        XCTAssertEqual(valid.length, 4_410)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: valid.processingFormat, frameCapacity: 4_096))
        var decoded: AVAudioFramePosition = 0
        while decoded < valid.length {
            let requested = AVAudioFrameCount(min(4_096, valid.length - decoded))
            buffer.frameLength = 0
            try valid.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0, buffer.frameLength <= requested else {
                XCTFail("Positive AAC fixture did not fully decode"); throw ThemeImportError.installFailed
            }
            decoded += AVAudioFramePosition(buffer.frameLength)
        }
        XCTAssertEqual(decoded, valid.length)
        let corrupt = try AVAudioFile(forReading: corruptURL)
        XCTAssertEqual(corrupt.length, valid.length, "Container still opens with the same declared length")
        XCTAssertEqual(corrupt.fileFormat.sampleRate, valid.fileFormat.sampleRate)
        XCTAssertLessThanOrEqual(Double(corrupt.length) / corrupt.fileFormat.sampleRate, 30)
        let badBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: corrupt.processingFormat, frameCapacity: 4_096))
        var decoderError: NSError?
        do {
            try corrupt.read(into: badBuffer, frameCount: 4_096)
        } catch { decoderError = error as NSError }
        let actualError = try XCTUnwrap(decoderError,
            "Corrupt fixture must fail a real frame read, not merely opening or parsing headers")

        for (name, bytes, code) in [
            ("sound-full-decode-valid", validBytes, nil as String?),
            ("sound-full-decode-corrupt", corruptBytes, "sound.decode")
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData(
                resourceData: ["preview.png": Self.validPNG, "sound.m4a": bytes])) as? [String: Any])
            object["sounds"] = ["clockIn": "sound.m4a"]
            try await assertStage9Boundary(name: name, entries: [
                CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])),
                CorpusEntry("preview.png", Self.validPNG, compression: .none),
                CorpusEntry("sound.m4a", bytes, compression: .none)
            ], expectedCode: code, expectedItem: code == nil ? nil : "sound.m4a")
        }
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let evidence: [String: Any] = ["validSHA256": hash(validBytes), "corruptSHA256": hash(corruptBytes),
            "encodedBytes": validBytes.count, "mdatOffset": range.lowerBound, "mdatBytes": range.count,
            "openedBoth": true, "declaredFrames": valid.length, "validDecodedFrames": decoded,
            "corruptReadErrorDomain": actualError.domain, "corruptReadErrorCode": actualError.code,
            "fixtureRoot": fixtureRoot.path, "scope": "Actual decoder failure after open; no playback or install"]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        guard data.count <= 8_192 else { throw ThemeImportError.installFailed }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Stage9-Audio-Full-Decode-Corpus"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testFullAudioReadRetainsThirtySecondAndTenMiBBoundaries() async throws {
        // Reuse immutable inputs from the already executed boundary corpus.
        // A fresh repository only receives production's temporary validation
        // copy/payload; no duplicate10MiB source package is written.
        let family = URL(fileURLWithPath:
            "/private/tmp/visual-income-check-in/stage9-closeout/run-20260907-001/UIData/Resume008BoundedFixtures",
            isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let cases: [(String, String, Int, String, String?)] = [
            ("wav-accepted", "sound-recheck-wav", 9443, "71faf145ef2393d6575aa5cd83aec659d3e2e087a5eb0f2f4984fcb24e054542", nil),
            ("unsupported-mp3-extension", "sound-recheck-mp3", 9443, "21990790c6d27dc0175a7d046ad5edecfaa1fef245d124c1727ed57e78e1a95f", "sound.decode"),
            ("invalid-wav", "sound-recheck-invalid-wav", 1411, "bdbd03b6190720283aff1008de1fa6715583ed812620b1a58173396e8ab85164", "sound.decode"),
            ("sound-exact-10MiB", "sound-recheck-10MiB", 10487161, "b1f80a94f298f27cb3cf2068d5eff795fa6becdc7f41dd1cb6aa49d55f706070", nil),
            ("sound-over-10MiB-one-byte", "sound-recheck-over-10MiB", 10487158, "54a8c1c17108b1678a01b929e96354bd7006d9e39224895e890e159b72bf06df", "sound.decode"),
            ("sound-exact-30-seconds", "sound-recheck-30s", 241442, "28ac1cbe3dc539b56e83b6a9abf0edbdfcafc3136e3045482252448bc2e4a0df", nil),
            ("sound-over-30-seconds-one-frame", "sound-recheck-over-30s", 241446, "735a0e378f095c10200b088f55793e4fd5b0899919ece9e39e62465b4a0bef60", "sound.duration")
        ]
        for (sourceName, freshName, size, digest, code) in cases {
            let source = family.appendingPathComponent(sourceName, isDirectory: true)
                .appendingPathComponent(sourceName + ".incomeclocktheme")
            try await assertStage9Boundary(name: freshName, entries: [], expectedCode: code,
                expectedItem: code == nil ? nil : (sourceName == "unsupported-mp3-extension" ? "sound.mp3" : "sound.wav"),
                retainedArchive: (source, size, digest))
        }
    }

    // Finite direct media corpus: no media attachments, playback, UI or install.
    @MainActor
    func testAudioFormatByteAndDurationBoundariesRejectWithoutSideEffects() async throws {
        let short = stage9PCMFrames(8_000)
        let exactBytes = stage9PCMFrames(8_000, totalBytes: 10 * 1_024 * 1_024)
        var overBytes = exactBytes
        overBytes.append(0)
        writeUInt32(UInt32(overBytes.count - 8), to: &overBytes, at: 4)
        let cases: [(String, String, Data, String?)] = [
            ("wav-accepted", "sound.wav", short, nil),
            ("unsupported-mp3-extension", "sound.mp3", short, "sound.decode"),
            ("invalid-wav", "sound.wav", Data("invalid WAV".utf8), "sound.decode"),
            ("sound-exact-10MiB", "sound.wav", exactBytes, nil),
            ("sound-over-10MiB-one-byte", "sound.wav", overBytes, "sound.decode"),
            ("sound-exact-30-seconds", "sound.wav", stage9PCMFrames(240_000), nil),
            ("sound-over-30-seconds-one-frame", "sound.wav", stage9PCMFrames(240_001), "sound.duration")
        ]
        XCTAssertEqual(exactBytes.count, 10 * 1_024 * 1_024)
        XCTAssertEqual(overBytes.count, exactBytes.count + 1)
        for (name, path, bytes, code) in cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData(
                resourceData: ["preview.png": Self.validPNG, path: bytes])) as? [String: Any])
            object["sounds"] = ["clockIn": path]
            try await assertStage9Boundary(name: name, entries: [
                CorpusEntry("manifest.json", try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])),
                CorpusEntry("preview.png", Self.validPNG, compression: .none),
                CorpusEntry(path, bytes, compression: .none)
            ], expectedCode: code, expectedItem: code == nil ? nil : path)
        }
    }

    @MainActor
    func testImageDimensionAndPixelBoundariesRejectWithoutSideEffects() async throws {
        // Independently cross each limit: the dimension cases have very few pixels;
        // both pixel cases keep width and height below the dimension limit.
        for (name, width, height, accepted) in [
            ("dimension-exact-4096", 4096, 1, true),
            ("dimension-over-4096", 4097, 1, false),
            ("pixels-exact-16000000", 4000, 4000, true),
            ("pixels-over-16000000", 4000, 4001, false)
        ] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 1,
                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                bytesPerRow: width, bitsPerPixel: 8))
            let storage = try XCTUnwrap(bitmap.bitmapData)
            storage.initialize(repeating: 127, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            guard png.count <= 128 * 1_024 else {
                XCTFail("Flat grayscale PNG exceeded 128KiB before any fixture write")
                throw ThemeImportError.installFailed
            }
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(decoded.pixelsWide, width)
            XCTAssertEqual(decoded.pixelsHigh, height)
            try await assertStage9Boundary(name: name, entries: [
                CorpusEntry("manifest.json", try validManifestData(resourceData: ["preview.png": png])),
                CorpusEntry("preview.png", png, compression: .none)
            ], expectedCode: accepted ? nil : "image.bounds", expectedItem: accepted ? nil : "preview.png")
        }
    }

    @MainActor
    func testUnicodeCanonicalAndWidthPathCollisionsRejectBeforeExtraction() async throws {
        for (name, first, second) in [
            ("unicode-nfc-nfd", "caf\u{00E9}.png", "cafe\u{0301}.png"),
            ("unicode-width-fold", "A.png", "\u{FF21}.png"),
            ("unicode-diacritic-fold", "cafe.png", "caf\u{00E9}.png")
        ] {
            XCTAssertNotEqual(Array(first.utf8), Array(second.utf8))
            // Construct distinct ASCII entries, then replace local and central UTF-8
            // filename bytes. This avoids Swift canonical String equality inside
            // an archive writer masking the importer collision under test.
            let a = String(repeating: "a", count: first.utf8.count)
            let b = String(repeating: "b", count: second.utf8.count)
            try await assertStage9Boundary(name: name, entries: [
                CorpusEntry(a, Self.validPNG, compression: .none),
                CorpusEntry(b, Self.validPNG, compression: .none)
            ], expectedCode: "path.duplicate", expectedItem: nil) { archive in
                var data = try Data(contentsOf: archive)
                for (placeholder, replacement) in [(a, first), (b, second)] {
                    let old = Data(placeholder.utf8), new = Data(replacement.utf8)
                    XCTAssertEqual(old.count, new.count)
                    var positions: [Range<Data.Index>] = []
                    var start = data.startIndex
                    while start < data.endIndex,
                          let range = data.range(of: old, in: start..<data.endIndex) {
                        positions.append(range); start = range.upperBound
                    }
                    XCTAssertEqual(positions.count, 2, "one local and one central filename")
                    guard positions.count == 2 else { throw ThemeImportError.installFailed }
                    for range in positions { data.replaceSubrange(range, with: new) }
                }
                // ZIPFoundation writes UTF-8 filenames. Set the flag explicitly in
                // both headers so no system legacy encoding changes the fixture.
                for offset in self.signatureOffsets(0x04034b50, in: data) {
                    self.writeUInt16(self.readUInt16(data, offset + 6) | 0x0800, to: &data, at: offset + 6)
                }
                for offset in self.signatureOffsets(0x02014b50, in: data) {
                    self.writeUInt16(self.readUInt16(data, offset + 8) | 0x0800, to: &data, at: offset + 8)
                }
                try data.write(to: archive)
            }
        }
    }

    // PCM RIFF/WAVE, mono unsigned 8-bit at 8 kHz. Optional JUNK makes
    // a valid short sound exactly 10 MiB without conflating duration and size.
    private func stage9PCMFrames(_ frames: Int, totalBytes: Int? = nil) -> Data {
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8((value >> shift) & 255)) }
        }
        let paddedFrames = frames + (frames % 2)
        let byteCount = totalBytes ?? (44 + paddedFrames)
        precondition(byteCount >= 44 + paddedFrames && byteCount <= 10 * 1_024 * 1_024)
        tag("RIFF"); u32(UInt32(byteCount - 8)); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(8_000); u32(8_000); u16(1); u16(8)
        if totalBytes != nil {
            let junkBytes = byteCount - 44 - paddedFrames - 8
            precondition(junkBytes >= 0 && junkBytes % 2 == 0)
            tag("JUNK"); u32(UInt32(junkBytes)); data.append(Data(repeating: 0, count: junkBytes))
        }
        tag("data"); u32(UInt32(frames)); data.append(Data(repeating: 128, count: frames))
        if frames % 2 == 1 { data.append(0) }
        precondition(data.count == byteCount)
        return data
    }

    @MainActor
    private func assertStage9Boundary(
        name: String, entries: [CorpusEntry], expectedCode: String?, expectedItem: String?,
        retainedArchive: (url: URL, bytes: Int, sha256: String)? = nil,
        mutateArchive: ((URL) throws -> Void)? = nil
    ) async throws {
        if let retainedArchive {
            // The read-only branch cannot invoke a mutator or create a package.
            guard entries.isEmpty, mutateArchive == nil else { throw ThemeImportError.installFailed }
            let values = try retainedArchive.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == retainedArchive.bytes,
                  retainedArchive.url.resolvingSymlinksInPath().standardizedFileURL == retainedArchive.url.standardizedFileURL,
                  retainedArchive.bytes > 0, retainedArchive.bytes <= 10 * 1_024 * 1_024 + 32 * 1_024 else {
                throw ThemeImportError.installFailed
            }
            let digest = SHA256.hash(data: try Data(contentsOf: retainedArchive.url)).map { String(format: "%02x", $0) }.joined()
            guard digest == retainedArchive.sha256 else { throw ThemeImportError.installFailed }
        }
        let decodedBytes = retainedArchive?.bytes ?? entries.reduce(0) { $0 + $1.data.count }
        guard entries.count <= 3, decodedBytes <= 10 * 1_024 * 1_024 + 32 * 1_024,
              entries.filter({ $0.path == "manifest.json" }).allSatisfy({ $0.data.count <= 16 * 1_024 }) else {
            throw ThemeImportError.installFailed
        }
        // Existing source bytes are already counted by the family inventory.
        // Reserve only copy+payload for reuse, or source+copy+payload otherwise.
        // The same2MiB margin covers decoded manifest difference/block rounding,
        // tiny records/metadata and atomic writes; no family cap is enlarged.
        let copiesToCreate = retainedArchive == nil ? 3 : 2
        let root = try ApplicationTestSupport.makeResume008FixtureRoot(name: name,
            reservedGrowthBytes: decodedBytes * copiesToCreate + 2 * 1_024 * 1_024)
        let paths = RecordRepositoryPaths(root: root)
        let writes = RejectionMutationRecorder()
        let records = RecordRepositoryActor(paths: paths, fileStore: writes)
        _ = try await records.saveSettings(ApplicationTestSupport.proposedSettings(
            wageCents: 90_000, notificationsEnabled: true), expectedRevision: nil)
        let notifications = FakeNotificationService(authorization: .authorized)
        let business = try BusinessStore(repository: records,
            nowProvider: MutableTestClock(ApplicationTestSupport.timestamp(hour: 10)),
            timeZoneIdentifier: ApplicationTestSupport.timeZoneIdentifier, notificationService: notifications)
        await business.restore()
        let started = await business.send(.clockIn, source: .panel)
        XCTAssertEqual(started, .committed)
        let repository = ThemeRepositoryActor(applicationSupportRoot: root,
            currentAppVersion: "1.2.3", committer: writes)
        let store = ThemeStore(repository: records, themeRepository: repository)
        await store.restore()
        await store.selectTheme(id: BuiltinThemeID.windowCompanion)
        XCTAssertEqual(store.selectedTheme.id, BuiltinThemeID.windowCompanion)
        let recordURLs = [paths.settings, paths.today, paths.themePreferences]
        let beforeBytes = try recordURLs.map { try Data(contentsOf: $0) }
        let themeBefore = store.viewState
        let businessBefore = business.viewState
        let notificationsBefore = await notifications.operationLog()
        let recordWritesBefore = writes.recordMutations
        let plannedBytes = entries.reduce(0) { $0 + $1.data.count }
        guard plannedBytes < 11 * 1_024 * 1_024 else {
            XCTFail("finite decoded corpus budget exceeded"); throw ThemeImportError.installFailed
        }
        let archive: URL
        if let retainedArchive {
            archive = retainedArchive.url
        } else {
            archive = try makeArchive(named: name, entries: entries, in: root)
            try mutateArchive?(archive)
        }
        let bytes = try Data(contentsOf: archive)
        guard bytes.count <= decodedBytes + 16 * 1_024,
              beforeBytes.allSatisfy({ $0.count <= 16 * 1_024 }) else {
            XCTFail("ZIP overhead or record bytes exceeded finite fixture accounting")
            throw ThemeImportError.installFailed
        }
        var observed = "accepted"
        if let expectedCode {
            await store.beginImport(from: archive)
            guard case let .validation(items)? = store.importError else {
                return XCTFail("expected structured rejection: \(name), got \(String(describing: store.importError))")
            }
            XCTAssertEqual(items.count, 1, name)
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.code, expectedCode, name)
            XCTAssertEqual(item.category, expectedCode.hasPrefix("path.") ? .path : .media, name)
            if let expectedItem { XCTAssertEqual(item.item, expectedItem, name) }
            XCTAssertFalse(item.reason.isEmpty); XCTAssertFalse(item.suggestion.isEmpty)
            XCTAssertNil(store.importCandidate)
            await store.installImportCandidate() // absent candidate cannot bypass rejection
            XCTAssertNil(store.lastInstalledThemeID)
            XCTAssertEqual(store.importError, .validation(items))
            observed = item.code
        } else {
            let candidate = try await repository.validatePackage(at: archive) { _ in }
            await repository.discard(candidate)
        }
        XCTAssertEqual(store.viewState, themeBefore, name)
        XCTAssertEqual(business.viewState, businessBefore, name)
        XCTAssertEqual(try recordURLs.map { try Data(contentsOf: $0) }, beforeBytes, name)
        XCTAssertEqual(writes.recordMutations, recordWritesBefore, name)
        XCTAssertEqual(writes.themeMutations, 0, name)
        let notificationsAfter = await notifications.operationLog()
        XCTAssertEqual(notificationsAfter, notificationsBefore, name)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            root.appendingPathComponent("Themes").path), [], name)
        try assertStagingClean(root)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let retainedArchive {
            let after = try Data(contentsOf: retainedArchive.url)
            XCTAssertEqual(after.count, retainedArchive.bytes)
            XCTAssertEqual(SHA256.hash(data: after).map { String(format: "%02x", $0) }.joined(), retainedArchive.sha256,
                "Read-only retained corpus must remain byte-identical after validation")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".incomeclocktheme").path),
                "Reuse must not create a second source archive")
        }
        let evidence = "case=\(name) result=\(observed) archiveBytes=\(bytes.count) sha256=\(hash) root=\(root.path) source=\(archive.path)"
        XCTAssertLessThan(evidence.utf8.count, 2048)
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "stage9-media-boundary-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func validManifestData(
        id: String = "com.example.safe-theme",
        version: String = "1.0.0",
        author: String = "Example Author",
        preview: String = "preview.png",
        resources: [String: String] = [:],
        resourceData: [String: Data] = ["preview.png": Stage8ThemeImportTests.validPNG]
    ) throws -> Data {
        let manifest = ThemePackageManifest(
            schemaVersion: 1,
            themeId: id,
            name: "Safe Local Theme",
            author: author,
            themeVersion: version,
            minimumAppVersion: "0.1.0",
            description: "A deterministic local-only test theme",
            preview: preview,
            appearance: .init(supportedModes: [.light, .dark]),
            tokens: .init(
                light: ValidatedTheme.warmIslandFallback.manifest.light,
                dark: ValidatedTheme.warmIslandFallback.manifest.dark
            ),
            metrics: ValidatedTheme.warmIslandFallback.manifest.metrics,
            resources: resources,
            hashes: Dictionary(uniqueKeysWithValues: resourceData.map {
                ($0.key, SHA256.hash(data: $0.value).map { String(format: "%02x", $0) }.joined())
            }),
            animationPresets: ["none", "softFade"],
            sounds: nil,
            licenseOrSource: "Original test fixture",
            requiredCapabilities: [.init(name: "standard-theme", version: 1)],
            optionalCapabilities: [.init(name: "future-decoration", version: 9)],
            panelProfile: "standard-panel@1",
            layoutProfile: "standard-layout@1",
            visualMask: nil,
            extensions: ["com.example.fixture": .object(["note": .string("ignored")])]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private func validPackage(
        in root: URL,
        name: String,
        version: String = "1.0.0",
        author: String = "Example Author"
    ) throws -> URL {
        try package(name: name, preview: Self.validPNG, version: version, author: author, in: root)
    }

    private func package(
        name: String,
        preview: Data?,
        version: String = "1.0.0",
        author: String = "Example Author",
        declaredHash: String? = nil,
        in root: URL
    ) throws -> URL {
        let bytesForHash = preview ?? Self.validPNG
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validManifestData(
            version: version, author: author, resourceData: ["preview.png": bytesForHash]
        )) as? [String: Any])
        if let declaredHash { object["hashes"] = ["preview.png": declaredHash] }
        let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var entries = [CorpusEntry("manifest.json", manifest)]
        if let preview { entries.append(CorpusEntry("preview.png", preview)) }
        return try makeArchive(named: name, entries: entries, in: root)
    }

    private func makeArchive(named name: String, entries: [CorpusEntry], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("incomeclocktheme")
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(entry.data.count),
                permissions: entry.permissions,
                compressionMethod: entry.compression
            ) { position, size in
                let start = Int(position)
                guard start < entry.data.count else { return Data() }
                return entry.data.subdata(in: start..<min(entry.data.count, start + size))
            }
        }
        return url
    }

    private func validationDiagnostics(
        _ repository: ThemeRepositoryActor,
        _ url: URL
    ) async -> [ThemeValidationDiagnostic] {
        do {
            let candidate = try await repository.validatePackage(at: url) { _ in }
            await repository.discard(candidate)
            XCTFail("expected validation failure: \(url.lastPathComponent)")
            return []
        } catch let ThemeImportError.validation(items) {
            return items
        } catch {
            XCTFail("unexpected error \(error): \(url.lastPathComponent)")
            return []
        }
    }

    private func assertStagingClean(_ root: URL) throws {
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    private func preserveCorpus(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "stage8-corpus-\(name).incomeclocktheme"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let output = ProcessInfo.processInfo.environment["STAGE8_CORPUS_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name).appendingPathExtension("incomeclocktheme")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    private func writeCorpus(_ data: Data, name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("incomeclocktheme")
        try data.write(to: url, options: .atomic)
        preserveCorpus(url, name: name)
        return url
    }

    private func rewriteUncompressedSizes(in data: inout Data, sizes: [UInt32]) throws {
        let offsets = signatureOffsets(0x02014B50, in: data)
        XCTAssertEqual(offsets.count, sizes.count)
        for (offset, size) in zip(offsets, sizes) {
            let localOffset = Int(readUInt32(data, offset + 42))
            writeUInt32(size, to: &data, at: offset + 24)
            writeUInt32(size, to: &data, at: localOffset + 22)
        }
    }

    private func rewriteUncompressedSize(in data: inout Data, entryNamed name: String, size: UInt32) throws {
        for offset in signatureOffsets(0x02014B50, in: data) {
            let nameLength = Int(readUInt16(data, offset + 28))
            let entryName = String(data: data.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8)
            if entryName == name {
                let localOffset = Int(readUInt32(data, offset + 42))
                writeUInt32(size, to: &data, at: offset + 24)
                writeUInt32(size, to: &data, at: localOffset + 22)
                return
            }
        }
        XCTFail("entry not found: \(name)")
    }

    private func signatureOffsets(_ signature: UInt32, in data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        return (0...(data.count - 4)).filter { readUInt32(data, $0) == signature }
    }

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
