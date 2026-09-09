import Foundation
import Darwin

/// App-written deletion intent and immutable confirmations, scoped to one credential
/// fingerprint. Finder reads confirmations only and owns its own application receipts.
struct DeletionJournal {
    struct ConfirmedDeletion: Codable, Sendable, Equatable {
        let id: UUID
        let assetID: String
        let deletedAt: Date
    }

    struct Asset: Codable, Equatable {
        enum State: String, Codable { case pending, inFlight, succeeded, failed, uncertain }
        let id: UUID
        let assetID: String
        let originalFileName: String
        var state: State = .pending
        var message: String?
    }

    struct Batch: Codable {
        let id: UUID
        let connectionID: String
        let createdAt: Date
        var assets: [Asset]
        var completed = false
        var acknowledged = false
        var stopped = false
        var message: String?
    }

    enum StorageError: Error, LocalizedError {
        case unavailable
        case invalidConnection
        case conflictingConfirmation

        var errorDescription: String? {
            "The deletion safety journal could not be saved or read. No further deletion requests will be sent. Check Immich for any unconfirmed Asset."
        }
    }

    let storageDirectory: URL?

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)?
            .appendingPathComponent("DeletionJournal", isDirectory: true)
    }

    private func directory(connectionID: String, kind: String) throws -> URL {
        guard connectionID.count == 64,
              connectionID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw StorageError.invalidConnection
        }
        guard let storageDirectory else { throw StorageError.unavailable }
        return storageDirectory.appendingPathComponent(connectionID, isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    func confirmedDeletions(connectionID: String) throws -> [ConfirmedDeletion] {
        try records(ConfirmedDeletion.self, connectionID: connectionID, kind: "confirmed")
            .sorted { $0.deletedAt == $1.deletedAt ? $0.id.uuidString < $1.id.uuidString : $0.deletedAt < $1.deletedAt }
    }

    func pendingBatches(connectionID: String) throws -> [Batch] {
        let batches = try records(Batch.self, connectionID: connectionID, kind: "batches")
        guard batches.allSatisfy({ $0.connectionID == connectionID }) else {
            throw StorageError.invalidConnection
        }
        return batches.filter { !$0.acknowledged }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Must complete before each request is allowed onto the network.
    func save(_ batch: Batch) throws {
        let folder = try directory(connectionID: batch.connectionID, kind: "batches")
        try persist(batch, to: folder.appendingPathComponent(batch.id.uuidString + ".json"))
    }

    /// Stable attempt ID makes crash recovery idempotent; existing records are immutable.
    func confirm(asset: Asset, connectionID: String) throws {
        let folder = try directory(connectionID: connectionID, kind: "confirmed")
        let url = folder.appendingPathComponent(asset.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try JSONDecoder().decode(ConfirmedDeletion.self, from: Data(contentsOf: url))
            guard existing.id == asset.id, existing.assetID == asset.assetID else {
                throw StorageError.conflictingConfirmation
            }
            try synchronize(url)
            return
        }
        try persist(ConfirmedDeletion(id: asset.id, assetID: asset.assetID, deletedAt: Date()), to: url)
    }

    private func records<T: Decodable>(_ type: T.Type, connectionID: String, kind: String) throws -> [T] {
        let folder = try directory(connectionID: connectionID, kind: kind)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(type, from: Data(contentsOf: $0)) }
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try synchronize(url)
    }

    private func synchronize(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        // Flush directory entries as well as content, including newly created parents.
        guard let storageDirectory else { throw StorageError.unavailable }
        var directory = url.deletingLastPathComponent()
        while true {
            let descriptor = open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let result = fsync(descriptor)
            let failure = errno
            close(descriptor)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            if directory == storageDirectory.deletingLastPathComponent() { break }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
    }
}
