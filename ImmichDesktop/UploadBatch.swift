import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Owns only access to original sources, never copies or a persistent queue.
@MainActor
@Observable
final class UploadBatch {
    struct Failure: Identifiable {
        let id = UUID()
        let filename: String
        let message: String
        fileprivate let source: Source?
    }

    fileprivate final class Source {
        let url: URL
        private let scoped: Bool
        init(_ url: URL) {
            self.url = url
            scoped = url.startAccessingSecurityScopedResource()
        }
        deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    private(set) var isRunning = false
    private(set) var hasResult = false
    private(set) var failures: [Failure] = []
    private(set) var revision = 0
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var alreadyExistedCount = 0
    private(set) var currentFilename: String?
    private(set) var fractionCompleted: Double = 0
    private(set) var retrying = false
    private(set) var wasCancelled = false
    private(set) var uploadedAssets: [ImmichAsset] = []
    private(set) var connectionID: String?

    var summary: String {
        if isRunning {
            let action = retrying ? "Retrying" : "Uploading"
            let current = currentFilename.map { " — \($0) (\(Int(fractionCompleted * 100))%)" } ?? ""
            return "\(action) \(completedCount) of \(totalCount)\(current)"
        }
        let added = completedCount - alreadyExistedCount
        let cancelled = wasCancelled ? "Uploads stopped. " : ""
        return "\(cancelled)\(added) uploaded, \(alreadyExistedCount) already in library, \(failures.count) failed."
    }

    var canRetry: Bool { !isRunning && failures.contains { $0.source != nil } }

    private var queue: [Source?] = []
    private var nextIndex = 0
    private var pendingProviders = 0
    private var pendingNames: [UUID: String] = [:]
    private var configurationVersion: Int?
    private var client: ImmichClient?
    private var lease: UploadActivity.Lease?
    private var task: Task<Void, Never>?
    private var cancelRequested = false
    private var dropGeneration = UUID()

    func start(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let sources = urls.filter(\.isFileURL).map(Source.init)
        guard prepare(filenames: urls.map(\.lastPathComponent)) else { return }
        failures += urls.filter { !$0.isFileURL }.map {
            Failure(filename: $0.lastPathComponent,
                    message: "Only local files can be uploaded. Drop the original file again.", source: nil)
        }
        enqueue(sources)
    }

    /// Reserve the connection before resolving providers. Start security-scoped
    /// access in each provider callback, before its temporary grant can disappear.
    @discardableResult
    func start(providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty, prepare(filenames: providers.map { $0.suggestedName ?? "Dropped file" }) else {
            return false
        }
        totalCount += providers.count
        pendingProviders += providers.count
        let generation = dropGeneration
        for provider in providers {
            let name = provider.suggestedName ?? "Dropped file"
            let providerID = UUID()
            pendingNames[providerID] = name
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let string = item as? String { url = URL(string: string) }
                else { url = nil }
                let source = url.flatMap { $0.isFileURL ? Source($0) : nil }
                let message = error?.localizedDescription ?? "Source unavailable. Drop the original file again."
                Task { @MainActor in
                    guard generation == self.dropGeneration else { return }
                    guard !self.cancelRequested else { return }
                    self.pendingProviders -= 1
                    self.pendingNames.removeValue(forKey: providerID)
                    if let source { self.queue.append(source) }
                    else { self.failures.append(Failure(filename: name, message: message, source: nil)) }
                }
            }
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        task?.cancel()
    }

    func waitForCompletion() async { await task?.value }

    func retryFailures() {
        guard canRetry else { return }
        guard let current = ImmichClient(), current.connectionID == connectionID,
              current.configurationVersion == configurationVersion else {
            failures = failures.map {
                Failure(filename: $0.filename,
                        message: "The connection changed. Drop the original file again.", source: nil)
            }
            return
        }
        let sources = failures.compactMap(\.source)
        // Unavailable sources are intentionally not retried; retain their explanation.
        let unavailable = failures.filter { $0.source == nil }
        guard prepare(filenames: sources.map { $0.url.lastPathComponent },
                      expectedConnectionID: connectionID,
                      expectedConfigurationVersion: configurationVersion) else { return }
        failures = unavailable
        enqueue(sources)
    }

    func dismissResult() {
        guard !isRunning else { return }
        failures = []
        hasResult = false
        queue = []
    }

    private func prepare(filenames: [String], expectedConnectionID: String? = nil,
                         expectedConfigurationVersion: Int? = nil) -> Bool {
        if isRunning {
            // A cancellation has a short settling interval. Do not silently accept
            // a drop whose sources would immediately be discarded.
            return !cancelRequested
        }
        do {
            guard let snapshot = ImmichClient() else { throw URLError(.userAuthenticationRequired) }
            let lease = try UploadActivity.begin(client: snapshot)
            if let expectedConnectionID,
               snapshot.connectionID != expectedConnectionID || snapshot.configurationVersion != expectedConfigurationVersion {
                lease.finish()
                throw UploadActivity.ActivityError.connectionChanged
            }
            self.client = snapshot
            self.connectionID = snapshot.connectionID
            self.configurationVersion = snapshot.configurationVersion
            self.lease = lease
        } catch {
            failures += filenames.map { Failure(filename: $0, message: error.localizedDescription, source: nil) }
            hasResult = true
            return false
        }
        failures = []
        uploadedAssets = []
        queue = []
        nextIndex = 0
        pendingProviders = 0
        dropGeneration = UUID()
        pendingNames = [:]
        totalCount = 0
        completedCount = 0
        alreadyExistedCount = 0
        wasCancelled = false
        cancelRequested = false
        hasResult = false
        isRunning = true
        task = Task { await self.run() }
        return true
    }

    private func enqueue(_ sources: [Source]) {
        totalCount += sources.count
        queue.append(contentsOf: sources.map(Optional.some))
    }

    private func run() async {
        guard let client else { return }
        while !cancelRequested {
            guard nextIndex < queue.count else {
                if pendingProviders == 0 { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                continue
            }
            guard let source = queue[nextIndex] else { nextIndex += 1; continue }
            nextIndex += 1
            currentFilename = source.url.lastPathComponent
            var attempt = 0
            var sourceCompleted = false
            while !cancelRequested {
                let progress = Progress(totalUnitCount: 1)
                fractionCompleted = 0
                let observer = Task { @MainActor in
                    while !Task.isCancelled {
                        self.fractionCompleted = progress.fractionCompleted
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    }
                }
                do {
                    let result = try await client.uploadFile(at: source.url, progress: progress)
                    observer.cancel()
                    sourceCompleted = true
                    completedCount += 1
                    if result.alreadyExisted { alreadyExistedCount += 1 }
                    uploadedAssets.append(result.asset)
                    UploadActivity.recordCompletion(client: client, asset: result.asset)
                    revision += 1
                    break
                } catch {
                    observer.cancel()
                    if cancelRequested || Task.isCancelled { break }
                    if ImmichClient.isTransientUploadError(error) {
                        retrying = true
                        let delay = min(30, 1 << min(attempt, 5))
                        attempt = min(attempt + 1, 5)
                        do { try await Task.sleep(for: .seconds(delay)) }
                        catch { break }
                        retrying = false
                        continue
                    }
                    let unavailable: Bool
                    if case AssetUploadError.sourceUnavailable = error { unavailable = true }
                    else { unavailable = !FileManager.default.isReadableFile(atPath: source.url.path) }
                    failures.append(Failure(filename: source.url.lastPathComponent,
                        message: unavailable ? "Source unavailable. Drop the original file again." : error.localizedDescription,
                        source: unavailable ? nil : source))
                    break
                }
            }
            // Release successful grants immediately; failed sources alone retain
            // access for explicit retry, without shifting all remaining entries.
            if !cancelRequested || sourceCompleted {
                queue[nextIndex - 1] = nil
            }
        }
        wasCancelled = cancelRequested
        if cancelRequested {
            for name in pendingNames.values {
                failures.append(Failure(filename: name,
                    message: "Source access was cancelled. Drop the original file again.", source: nil))
            }
            // Includes the uncertain active source, which is safe to retry through
            // the client's checksum handling. Never remove any original.
            for source in queue.compactMap({ $0 }) {
                failures.append(Failure(filename: source.url.lastPathComponent,
                    message: "Not completed. Retry this file, or drop it again if unavailable.", source: source))
            }
        }
        queue = []
        dropGeneration = UUID()
        pendingProviders = 0
        pendingNames = [:]
        nextIndex = 0
        currentFilename = nil
        retrying = false
        lease?.finish()
        lease = nil
        self.client = nil
        isRunning = false
        hasResult = true
        task = nil
    }
}
