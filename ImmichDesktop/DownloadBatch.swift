import Foundation
import Observation

/// App-owned lifecycle for one cancellable batch of original Asset downloads.
///
/// The gallery observes this model, but does not own it. That lets an active batch
/// continue while its window is closed and lets a later gallery reconnect to the same
/// progress or retained result.
@MainActor
@Observable
final class DownloadBatch {
    typealias OriginalFileTransfer = @Sendable (_ assetID: String, _ temporaryURL: URL) async throws -> URL

    enum Phase: Equatable {
        case idle
        case running
        case completed
    }

    struct Progress: Equatable {
        let completedCount: Int
        let totalCount: Int
        let currentFileName: String?
    }

    struct Failure: Identifiable, Equatable {
        let assetID: String
        let originalFileName: String
        let message: String

        var id: String { assetID }
    }

    struct UnfinishedAsset: Identifiable, Equatable {
        let assetID: String
        let originalFileName: String

        var id: String { assetID }
    }

    struct BatchResult: Equatable {
        let destination: URL
        let totalCount: Int
        let successfulAssetIDs: [String]
        let failures: [Failure]
        let unfinished: [UnfinishedAsset]
        let cancelled: Bool

        var isFullSuccess: Bool {
            !cancelled && failures.isEmpty && unfinished.isEmpty
                && successfulAssetIDs.count == totalCount
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = Progress(completedCount: 0, totalCount: 0, currentFileName: nil)
    /// Successful Asset IDs are published as each file is placed, so the gallery can
    /// remove completed Assets from its transient selection immediately.
    private(set) var successfulAssetIDs: [String] = []
    private(set) var result: BatchResult?

    private let transfer: OriginalFileTransfer
    private var task: Task<Void, Never>?
    private var cancelRequested = false

    init(originalTransfer: OriginalFileTransfer? = nil) {
        self.transfer = originalTransfer ?? { assetID, temporaryURL in
            guard let client = ImmichClient() else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await client.downloadOriginal(id: assetID, to: temporaryURL)
        }
    }

    /// Starts one batch. The Asset snapshot and destination are fixed until the batch
    /// reaches a retained result. A second start is rejected while running or while a
    /// completed result is waiting to be consumed.
    @discardableResult
    func start(assets: [ImmichAsset], destination: URL) -> Bool {
        guard phase == .idle, task == nil, !assets.isEmpty else { return false }

        // A URL returned by NSOpenPanel may require a security-scoped extension
        // before even reading its resource values. Keep that extension alive for
        // every validation and for the complete transfer lifetime.
        let securityScopeActive = destination.startAccessingSecurityScopedResource()
        var securityScopeTransferredToRun = false
        defer {
            if securityScopeActive && !securityScopeTransferredToRun {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            return false
        }

        var seenIDs = Set<String>()
        let snapshot = assets.filter { seenIDs.insert($0.id).inserted }
        guard !snapshot.isEmpty else {
            return false
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmichDesktop-DownloadBatch-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory,
                                                     withIntermediateDirectories: true)
        } catch {
            return false
        }

        phase = .running
        progress = Progress(completedCount: 0,
                            totalCount: snapshot.count,
                            currentFileName: nil)
        successfulAssetIDs = []
        result = nil
        cancelRequested = false
        securityScopeTransferredToRun = true

        task = Task { [weak self] in
            await self?.run(snapshot: snapshot,
                            destination: destination,
                            temporaryDirectory: temporaryDirectory,
                            securityScopeActive: securityScopeActive)
        }
        return true
    }

    /// Requests cancellation. Completed files remain in the destination; the current
    /// or not-yet-started Assets are reported as unfinished.
    func cancel() {
        guard phase == .running else { return }
        cancelRequested = true
        task?.cancel()
    }

    /// Dismisses the retained result without touching any downloaded files.
    func consumeResult() {
        guard phase == .completed else { return }
        phase = .idle
        progress = Progress(completedCount: 0, totalCount: 0, currentFileName: nil)
        successfulAssetIDs = []
        result = nil
        cancelRequested = false
    }

    private func run(snapshot: [ImmichAsset],
                     destination: URL,
                     temporaryDirectory: URL,
                     securityScopeActive: Bool) async {
        var successfulIDs: [String] = []
        var failures: [Failure] = []
        var unfinished: [UnfinishedAsset] = []
        var reservedNames = Set<String>()
        var processedCount = 0
        var cancelled = false

        for index in snapshot.indices {
            let asset = snapshot[index]
            if cancelRequested || Task.isCancelled {
                unfinished.append(contentsOf: snapshot[index...].map(Self.unfinished))
                cancelled = true
                break
            }

            progress = Progress(completedCount: processedCount,
                                totalCount: snapshot.count,
                                currentFileName: asset.originalFileName)
            let temporaryURL = temporaryDirectory
                .appendingPathComponent("asset-\(UUID().uuidString)", isDirectory: false)
            var returnedTemporaryURL: URL?

            do {
                let downloadedURL = try await transfer(asset.id, temporaryURL)
                returnedTemporaryURL = downloadedURL

                guard !cancelRequested, !Task.isCancelled else {
                    removeOwnedTemporaryFiles(temporaryURL, returnedTemporaryURL,
                                              in: temporaryDirectory)
                    unfinished.append(contentsOf: snapshot[index...].map(Self.unfinished))
                    cancelled = true
                    break
                }
                guard FileManager.default.fileExists(atPath: downloadedURL.path) else {
                    throw BatchError.temporaryFileMissing
                }

                let outputURL = try place(downloadedURL,
                                          originalFileName: asset.originalFileName,
                                          in: destination,
                                          reservedNames: &reservedNames)
                applyDates(from: asset, to: outputURL)
                removeOwnedTemporaryFiles(temporaryURL, downloadedURL, in: temporaryDirectory)

                successfulIDs.append(asset.id)
                successfulAssetIDs = successfulIDs
                processedCount += 1
                progress = Progress(completedCount: processedCount,
                                    totalCount: snapshot.count,
                                    currentFileName: nil)
            } catch is CancellationError {
                removeOwnedTemporaryFiles(temporaryURL, returnedTemporaryURL,
                                          in: temporaryDirectory)
                unfinished.append(contentsOf: snapshot[index...].map(Self.unfinished))
                cancelled = true
                break
            } catch {
                removeOwnedTemporaryFiles(temporaryURL, returnedTemporaryURL,
                                          in: temporaryDirectory)
                if cancelRequested || Task.isCancelled {
                    unfinished.append(contentsOf: snapshot[index...].map(Self.unfinished))
                    cancelled = true
                    break
                }
                failures.append(Failure(assetID: asset.id,
                                        originalFileName: asset.originalFileName,
                                        message: Self.userMessage(for: error)))
                processedCount += 1
                progress = Progress(completedCount: processedCount,
                                    totalCount: snapshot.count,
                                    currentFileName: nil)
            }
        }

        if cancelled, unfinished.isEmpty, successfulIDs.count < snapshot.count {
            let completedIDs = Set(successfulIDs)
            unfinished = snapshot
                .filter { !completedIDs.contains($0.id) }
                .map(Self.unfinished)
        }

        try? FileManager.default.removeItem(at: temporaryDirectory)
        if securityScopeActive {
            destination.stopAccessingSecurityScopedResource()
        }

        progress = Progress(completedCount: processedCount,
                            totalCount: snapshot.count,
                            currentFileName: nil)
        result = BatchResult(destination: destination,
                             totalCount: snapshot.count,
                             successfulAssetIDs: successfulIDs,
                             failures: failures,
                             unfinished: unfinished,
                             cancelled: cancelled)
        phase = .completed
        task = nil
    }

    private func place(_ source: URL,
                       originalFileName: String,
                       in destination: URL,
                       reservedNames: inout Set<String>) throws -> URL {
        let fileManager = FileManager.default
        let safeName = Self.safeFileName(originalFileName)
        var suffix = 1

        while true {
            let candidateName = Self.filename(safeName, suffix: suffix)
            let candidateKey = Self.filenameKey(candidateName)
            let candidateURL = destination.appendingPathComponent(candidateName,
                                                                  isDirectory: false)
            guard !reservedNames.contains(candidateKey),
                  !fileManager.fileExists(atPath: candidateURL.path) else {
                suffix += 1
                continue
            }

            do {
                try fileManager.moveItem(at: source, to: candidateURL)
                reservedNames.insert(candidateKey)
                return candidateURL
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileWriteFileExistsError {
                // A file may have appeared after the existence check. Keep the same
                // collision rule and try the next suffix rather than overwriting it.
                suffix += 1
            }
        }
    }

    private func applyDates(from asset: ImmichAsset, to outputURL: URL) {
        var mutableURL = outputURL
        if let date = Self.parseDate(asset.fileCreatedAt) {
            var values = URLResourceValues()
            values.creationDate = date
            try? mutableURL.setResourceValues(values)
        }
        if let date = Self.parseDate(asset.fileModifiedAt) {
            var values = URLResourceValues()
            values.contentModificationDate = date
            try? mutableURL.setResourceValues(values)
        }
    }

    private func removeOwnedTemporaryFiles(_ urls: URL?..., in directory: URL) {
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        for url in urls.compactMap({ $0 }) {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func unfinished(_ asset: ImmichAsset) -> UnfinishedAsset {
        UnfinishedAsset(assetID: asset.id, originalFileName: asset.originalFileName)
    }

    private static func safeFileName(_ originalFileName: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: originalFileName).lastPathComponent
        guard !lastPathComponent.isEmpty, lastPathComponent != ".", lastPathComponent != ".." else {
            return "Asset"
        }
        return lastPathComponent
    }

    private static func filename(_ name: String, suffix: Int) -> String {
        guard suffix > 1 else { return name }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return "\(name) \(suffix)"
        }
        return "\(name[..<dot]) \(suffix)\(name[dot...])"
    }

    private static func filenameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
    }

    private static func userMessage(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? String(describing: error) : description
    }

    private enum BatchError: LocalizedError {
        case temporaryFileMissing

        var errorDescription: String? {
            switch self {
            case .temporaryFileMissing:
                return "The original file transfer produced no file."
            }
        }
    }
}
