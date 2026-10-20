import Foundation
import Darwin
import os

/// Advisory locks are released by the kernel if either process exits. No source
/// files or restart-recovery work are retained here.
enum UploadActivity {
    enum ActivityError: Error, LocalizedError {
        case unavailable, busy, connectionChanged
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Upload coordination is unavailable. Try again after reopening Immich Desktop."
            case .busy: return "Wait for uploads to finish, or cancel them, before changing the connection or Finder layout."
            case .connectionChanged: return "The connection changed. Drop the file again using the current connection."
            }
        }
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        func finish() {
            lock.lock()
            defer { lock.unlock() }
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }
        deinit { finish() }
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)
    }

    private static func acquire(_ operation: Int32) throws -> Lease {
        guard let directory else { throw ActivityError.unavailable }
        let path = directory.appendingPathComponent("upload-activity.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ActivityError.unavailable }
        guard flock(descriptor, operation | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK { throw ActivityError.busy }
            throw ActivityError.unavailable
        }
        return Lease(descriptor)
    }

    static func begin(client: ImmichClient) throws -> Lease {
        let lease = try acquire(LOCK_SH)
        guard let current = ImmichClient(), current.connectionID == client.connectionID,
              current.configurationVersion == client.configurationVersion else {
            lease.finish()
            throw ActivityError.connectionChanged
        }
        return lease
    }

    /// Hold this exclusive lease across configuration mutations AND domain reset.
    static func beginConfigurationChange() throws -> Lease { try acquire(LOCK_EX) }

    static func withConfigurationChange<T>(_ body: () throws -> T) throws -> T {
        let lease = try beginConfigurationChange()
        defer { lease.finish() }
        return try body()
    }

    static var hasActiveTransfers: Bool {
        do {
            let lease = try acquire(LOCK_EX)
            lease.finish()
            return false
        } catch { return true } // Fail closed if coordination cannot be read.
    }

    static var revision: String {
        guard let url = directory?.appendingPathComponent("upload-revision"),
              let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    /// Metadata only, not queued work or retained source content. Exact completions
    /// let Finder materialize old-date uploads without scanning the whole library.
    static func recordCompletion(client: ImmichClient, asset: ImmichAsset) {
        do {
            let folder = try completionDirectory(client: client)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = Data(asset.id.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
            try JSONEncoder().encode(asset).write(to: folder.appendingPathComponent(filename + ".json"), options: .atomic)
            recordCompletion(client: client)
        } catch {
            fpLog.error("Publishing uploaded asset metadata failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func completedAssets(client: ImmichClient) throws -> [ImmichAsset] {
        let folder = try completionDirectory(client: client)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ImmichAsset.self, from: Data(contentsOf: $0)) }
    }

    private static func completionDirectory(client: ImmichClient) throws -> URL {
        guard let directory else { throw ActivityError.unavailable }
        return directory.appendingPathComponent("UploadCompletions", isDirectory: true)
            .appendingPathComponent(client.connectionID, isDirectory: true)
    }

    static func recordCompletion(client: ImmichClient) {
        guard let url = directory?.appendingPathComponent("upload-revision") else { return }
        do {
            try Data((client.connectionID + ":" + UUID().uuidString).utf8).write(to: url, options: .atomic)
        } catch {
            fpLog.error("Publishing upload refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
