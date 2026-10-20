import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// App-owned preparation and lifetime management for original files on the clipboard.
@MainActor
@Observable
final class CopyBatch {
    typealias OriginalFileTransfer = DownloadBatch.OriginalFileTransfer

    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var result: String?

    private let transfer: OriginalFileTransfer
    private let pasteboard: NSPasteboard
    private var task: Task<Void, Never>?
    private var clipboardMonitor: Task<Void, Never>?
    private var publishedDirectory: URL?
    private var publishedChangeCount: Int?

    init(originalTransfer: OriginalFileTransfer? = nil,
         pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.transfer = originalTransfer ?? { assetID, temporaryURL in
            guard let client = ImmichClient() else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await client.downloadOriginal(id: assetID, to: temporaryURL)
        }
    }

    /// The display-ordered snapshot is fixed until preparation finishes. A retained
    /// result does not prevent starting another copy.
    @discardableResult
    func start(assets: [ImmichAsset]) -> Bool {
        guard !isRunning, task == nil else { return false }
        var seenIDs = Set<String>()
        let snapshot = assets.filter { seenIDs.insert($0.id).inserted }
        guard !snapshot.isEmpty else { return false }

        completedCount = 0
        totalCount = snapshot.count
        result = nil
        releaseReplacedClipboardFiles()
        let startingChangeCount = pasteboard.changeCount
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmichDesktop-CopyBatch-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        } catch {
            result = "Copy failed: \(error.localizedDescription)"
            return false
        }
        isRunning = true
        task = Task { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            await self.run(snapshot: snapshot, directory: directory,
                           startingChangeCount: startingChangeCount)
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    func dismissResult() {
        result = nil
    }

    private func run(snapshot: [ImmichAsset], directory: URL,
                     startingChangeCount: Int) async {
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: directory)
            }
            isRunning = false
            task = nil
        }

        do {
            var reservedNames = Set<String>()
            var items: [NSPasteboardItem] = []
            items.reserveCapacity(snapshot.count)

            for asset in snapshot {
                try Task.checkCancellation()
                let temporaryURL = directory.appendingPathComponent(".transfer-\(UUID().uuidString)")
                let downloadedURL = try await transfer(asset.id, temporaryURL)
                // Transfers return caller-owned files, including injected transfers.
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                try Task.checkCancellation()
                guard try downloadedURL.resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile == true else {
                    throw CopyError.missingOriginal
                }

                let fileName = Self.uniqueFileName(asset.originalFileName,
                                                  reservedNames: &reservedNames)
                let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
                try FileManager.default.moveItem(at: downloadedURL, to: fileURL)
                try Task.checkCancellation()

                let imageData: Data?
                if asset.type == "IMAGE" {
                    let decoding = Task.detached(priority: .userInitiated) {
                        try Self.tiffRepresentation(of: fileURL)
                    }
                    imageData = try await withTaskCancellationHandler {
                        try await decoding.value
                    } onCancel: {
                        decoding.cancel()
                    }
                } else {
                    imageData = nil
                }
                try Task.checkCancellation()

                let item = NSPasteboardItem()
                guard item.setString(fileURL.absoluteString, forType: .fileURL) else {
                    throw CopyError.representationFailed
                }
                if let imageData, !item.setData(imageData, forType: .tiff) {
                    throw CopyError.representationFailed
                }
                items.append(item)
                completedCount += 1
            }

            try Task.checkCancellation()
            guard pasteboard.changeCount == startingChangeCount else {
                throw CopyError.clipboardChanged
            }

            // Materialize the old contents before clearing, so a failed native write
            // can restore them. Do not disturb a clipboard we cannot fully preserve.
            let previousItems = try snapshotClipboard()
            try Task.checkCancellation()
            guard pasteboard.changeCount == startingChangeCount else {
                throw CopyError.clipboardChanged
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(items) else {
                pasteboard.clearContents()
                let restored = previousItems.isEmpty || pasteboard.writeObjects(previousItems)
                if restored, publishedChangeCount == startingChangeCount {
                    publishedChangeCount = pasteboard.changeCount
                }
                throw CopyError.publicationFailed
            }

            let previousDirectory = publishedDirectory
            publishedDirectory = directory
            publishedChangeCount = pasteboard.changeCount
            published = true
            // A previous successful copy stays readable throughout preparation and
            // publication; only the completed replacement releases its files.
            if let previousDirectory {
                try? FileManager.default.removeItem(at: previousDirectory)
            }
            startClipboardMonitor()
        } catch is CancellationError {
            result = "Copy cancelled"
        } catch {
            result = Task.isCancelled ? "Copy cancelled" : Self.message(for: error)
        }
    }

    private func snapshotClipboard() throws -> [NSPasteboardItem] {
        try (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type),
                      copy.setData(data, forType: type) else {
                    throw CopyError.clipboardSnapshotFailed
                }
            }
            return copy
        }
    }

    private func startClipboardMonitor() {
        guard clipboardMonitor == nil else { return }
        clipboardMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                // Never hold self across the sleep: the app owns this model, not
                // the otherwise unbounded clipboard monitor.
                guard let self else { return }
                self.releaseReplacedClipboardFiles()
                if self.publishedDirectory == nil {
                    self.clipboardMonitor = nil
                    return
                }
            }
        }
    }

    private func releaseReplacedClipboardFiles() {
        guard let directory = publishedDirectory,
              publishedChangeCount != pasteboard.changeCount else { return }
        try? FileManager.default.removeItem(at: directory)
        publishedDirectory = nil
        publishedChangeCount = nil
    }

    /// ImageIO decoding and TIFF encoding run off the main actor. Unsupported
    /// originals still publish their file URL, without a misleading thumbnail.
    nonisolated private static func tiffRepresentation(of url: URL) throws -> Data? {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.tiff.identifier as CFString, 1, nil) else {
                throw CopyError.representationFailed
            }
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else {
                throw CopyError.representationFailed
            }
            try Task.checkCancellation()
            return data as Data
        }
    }

    private static func uniqueFileName(_ original: String,
                                       reservedNames: inout Set<String>) -> String {
        let normalized = original.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "\0", with: "")
        let basename = (normalized as NSString).lastPathComponent
        let safeName = basename.isEmpty || [".", "..", "/"].contains(basename)
            ? "Asset" : basename
        var suffix = 1
        while true {
            let candidate: String
            if suffix == 1 {
                candidate = safeName
            } else if let dot = safeName.lastIndex(of: "."), dot != safeName.startIndex {
                candidate = "\(safeName[..<dot]) (\(suffix))\(safeName[dot...])"
            } else {
                candidate = "\(safeName) (\(suffix))"
            }
            let key = candidate.precomposedStringWithCanonicalMapping.lowercased()
            if reservedNames.insert(key).inserted { return candidate }
            suffix += 1
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CopyError, error == .clipboardChanged {
            return "Copy cancelled because clipboard changed"
        }
        return "Copy failed: \(error.localizedDescription)"
    }

    private enum CopyError: LocalizedError, Equatable {
        case missingOriginal
        case representationFailed
        case clipboardChanged
        case clipboardSnapshotFailed
        case publicationFailed

        var errorDescription: String? {
            switch self {
            case .missingOriginal:
                return "The original file transfer produced no readable file."
            case .representationFailed:
                return "The clipboard representation could not be prepared."
            case .clipboardChanged:
                return "The clipboard changed during preparation."
            case .clipboardSnapshotFailed:
                return "The existing clipboard could not be preserved."
            case .publicationFailed:
                return "The original files could not be placed on the clipboard."
            }
        }
    }
}
