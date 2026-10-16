import Darwin
import Foundation

protocol RecordFileStore: Sendable {
    func readData(at url: URL) throws -> Data?
    func commitAtomically(_ data: Data, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
}

protocol AtomicFileReplacing: Sendable {
    func replaceItem(at temporaryURL: URL, withItemAt destinationURL: URL) throws
}

struct POSIXAtomicFileReplacer: AtomicFileReplacing {
    func replaceItem(at temporaryURL: URL, withItemAt destinationURL: URL) throws {
        guard rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw PersistenceError.atomicWriteFailed
        }
    }
}

struct AtomicRecordFileStore: RecordFileStore {
    private let replacer: any AtomicFileReplacing

    init(replacer: any AtomicFileReplacing = POSIXAtomicFileReplacer()) {
        self.replacer = replacer
    }

    func readData(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
            return nil
        }
    }

    func commitAtomically(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PersistenceError.atomicWriteFailed
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var cursor = baseAddress
                while bytesRemaining > 0 {
                    let written = Darwin.write(descriptor, cursor, bytesRemaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw PersistenceError.atomicWriteFailed
                    }
                    guard written > 0 else {
                        throw PersistenceError.atomicWriteFailed
                    }
                    bytesRemaining -= written
                    cursor = cursor.advanced(by: written)
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                throw PersistenceError.atomicWriteFailed
            }
        } catch {
            _ = close(descriptor)
            throw PersistenceError.atomicWriteFailed
        }

        do {
            try replacer.replaceItem(at: temporaryURL, withItemAt: destinationURL)
        } catch {
            throw PersistenceError.atomicWriteFailed
        }
        shouldRemoveTemporaryFile = false
    }

    func removeItem(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw PersistenceError.deleteFailed
        }
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw PersistenceError.diagnosticBackupFailed
        }
    }
}

struct RecordRepositoryPaths: Equatable, Sendable {
    let root: URL
    let recordsDirectory: URL
    let diagnosticsCorruptDirectory: URL
    let settings: URL
    let today: URL
    let themePreferences: URL

    init(root: URL) {
        self.root = root
        recordsDirectory = root.appendingPathComponent("Records", isDirectory: true)
        diagnosticsCorruptDirectory = root
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Corrupt", isDirectory: true)
        settings = recordsDirectory.appendingPathComponent("settings.json", isDirectory: false)
        today = recordsDirectory.appendingPathComponent("today.json", isDirectory: false)
        themePreferences = recordsDirectory.appendingPathComponent(
            "theme-preferences.json",
            isDirectory: false
        )
    }

    static func applicationSupport(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard !bundleIdentifier.isEmpty else {
            throw PersistenceError.invalidProposedRecord
        }
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(root: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }
}
