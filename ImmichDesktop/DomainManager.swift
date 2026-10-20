import FileProvider
import OSLog

/// Manages the lifecycle of the Immich File Provider domain.
enum DomainManager {
    private enum PendingUploadError: LocalizedError {
        case unfinished

        var errorDescription: String? {
            "Finish or resolve pending Finder uploads before changing the connection, rebuilding Finder views, or removing the Finder domain."
        }
    }

    private final class PendingUploadObserver: NSObject, NSFileProviderEnumerationObserver {
        private let enumerator: NSFileProviderPendingSetEnumerator
        private var continuation: CheckedContinuation<Bool, Error>?
        private var foundUpload = false

        init(enumerator: NSFileProviderPendingSetEnumerator) {
            self.enumerator = enumerator
        }

        func hasPendingUploads() async throws -> Bool {
            defer { enumerator.invalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage(rawValue: Data()))
            }
        }

        func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
            foundUpload = foundUpload || updatedItems.contains {
                $0.isUploaded != true || $0.isUploading == true || $0.uploadingError != nil
            }
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            if !foundUpload, let nextPage {
                enumerator.enumerateItems(for: self, startingAt: nextPage)
                return
            }
            let completion = continuation
            continuation = nil
            completion?.resume(returning: foundUpload)
        }

        func finishEnumeratingWithError(_ error: Error) {
            let completion = continuation
            continuation = nil
            completion?.resume(throwing: error)
        }
    }

    /// Call while holding the configuration lease, before writing configuration.
    /// The system's pending set complements active-transfer locking, but omits
    /// initial transfers and can lag queued changes; it is not a complete queue.
    static func ensureNoPendingUploads() async throws {
        let registeredDomains = try await NSFileProviderManager.domains()
        for registeredDomain in registeredDomains {
            guard let manager = NSFileProviderManager(for: registeredDomain) else {
                throw CocoaError(.fileReadUnknown)
            }
            let observer = PendingUploadObserver(enumerator: manager.enumeratorForPendingItems())
            if try await observer.hasPendingUploads() {
                throw PendingUploadError.unfinished
            }
        }
    }

    private actor LifecycleQueue {
        private var tail = Task<Void, Never> {}
        private var acceptsActivations = true

        func activate(
            _ operation: @escaping @Sendable () async throws -> Void
        ) async throws {
            guard acceptsActivations else { throw CancellationError() }
            let predecessor = tail
            let task = Task {
                await predecessor.value
                try await operation()
            }
            tail = Task { _ = try? await task.value }
            try await task.value
        }

        func deactivate(
            _ operation: @escaping @Sendable () async -> Void
        ) async {
            acceptsActivations = false
            let predecessor = tail
            let task = Task {
                await predecessor.value
                await operation()
            }
            tail = task
            await task.value
        }
    }

    private static let lifecycleQueue = LifecycleQueue()

    private static var domain: NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: AppConfig.domainIdentifier),
            displayName: AppConfig.domainDisplayName)
    }

    /// Registers the domain so Immich appears in Finder.
    /// - Parameter reset: if true, tears every domain down completely (`.removeAll`)
    ///   before re-adding — this clears the cache and any stale "signed out" state, so
    ///   the same identifier can be reused without resurrecting the stuck state. Use
    ///   after changing the configuration.
    static func activate(
        reset: Bool,
        configurationLease: UploadActivity.Lease? = nil
    ) async throws {
        // Exclude uploads across both configuration writes (when the caller owns
        // the lease) and every removal, including legacy-domain cleanup on launch.
        let lease = try configurationLease ?? UploadActivity.beginConfigurationChange()
        defer {
            if configurationLease == nil { lease.finish() }
        }
        try await lifecycleQueue.activate {
            try await ensureNoPendingUploads()
            try await performActivation(reset: reset)
        }
    }

    private static func performActivation(reset: Bool) async throws {
        let target = domain
        let existing = try await NSFileProviderManager.domains()
        if reset {
            // A hierarchy change requires a genuinely new backing store. Do not
            // swallow removal errors: adding the same identifier would otherwise
            // succeed as a mere domain update and keep Finder's stale database.
            for legacyDomain in existing
            where legacyDomain.identifier != target.identifier {
                _ = try? await NSFileProviderManager.remove(
                    legacyDomain, mode: .removeAll)
            }
            if let currentDomain = existing.first(where: {
                $0.identifier == target.identifier
            }) {
                try await NSFileProviderManager.remove(
                    currentDomain, mode: .removeAll)
            }
            let remaining = try await NSFileProviderManager.domains()
            guard !remaining.contains(where: {
                $0.identifier == target.identifier
            }) else {
                throw NSError(
                    domain: "org.kartax.ImmichDesktop.DomainManager",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The existing File Provider domain could not be removed."
                    ])
            }
        } else {
            // Normal launch: keep our domain (and its downloaded cache), but clear any
            // stale/old domains from previous versions (e.g. the former "immich-v2") so
            // they don't linger in Finder.
            for d in existing where d.identifier != target.identifier {
                _ = try? await NSFileProviderManager.remove(d, mode: .removeAll)
            }
            if existing.contains(where: { $0.identifier == target.identifier }) {
                return  // already active – keep the downloaded cache
            }
        }
        try await addWithRetry(target)
        if let manager = NSFileProviderManager(for: target) {
            try? await manager.signalEnumerator(for: .workingSet)
            try? await manager.signalEnumerator(for: .rootContainer)
        }
    }

    /// Domain removal can finish registration before its old on-disk location has
    /// disappeared. Retry only that documented transient add failure.
    private static func addWithRetry(
        _ domain: NSFileProviderDomain
    ) async throws {
        let maximumAttempts = 4
        for attempt in 1...maximumAttempts {
            do {
                try await NSFileProviderManager.add(domain)
                return
            } catch {
                let nsError = error as NSError
                guard attempt < maximumAttempts,
                      nsError.domain == NSCocoaErrorDomain,
                      nsError.code == NSFileWriteFileExistsError else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Signals Finder to re-enumerate the root container without a full domain reset.
    /// Use after toggling view visibility so changes appear immediately with no cache loss.
    static func signalRoot() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try? await manager.signalEnumerator(for: .rootContainer)
    }

    /// Wakes the extension's durable deletion reconciler. It signals every known
    /// container after committing per-occurrence working-set deletions; the app
    /// never edits extension metadata or resets/removes the domain.
    static func signalDeletionChanges() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let containers: [NSFileProviderItemIdentifier] = [.workingSet, .rootContainer]
        for container in containers {
            do {
                try await manager.signalEnumerator(for: container)
            } catch {
                Logger(subsystem: AppConfig.domainIdentifier, category: "Deletion")
                    .error("Finder deletion wake remains pending: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Wakes Finder after completed gallery uploads without rebuilding its domain.
    static func signalUploadChanges() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        // ItemID belongs to the extension target; use its documented timeline ID.
        let containers: [NSFileProviderItemIdentifier] = [
            .rootContainer, NSFileProviderItemIdentifier("timeline"), .workingSet
        ]
        for container in containers {
            do {
                try await manager.signalEnumerator(for: container)
            } catch {
                Logger(subsystem: AppConfig.domainIdentifier, category: "Upload")
                    .error("Finder upload wake remains pending: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Returns the Finder-visible location of the Immich domain root.
    static func userVisibleRootURL() async throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    /// Removes all of this app's domains so Immich disappears from Finder.
    static func deactivate() async {
        let lease: UploadActivity.Lease
        do {
            lease = try UploadActivity.beginConfigurationChange()
            try await ensureNoPendingUploads()
        } catch {
            fpLog.error("Finder remains active: stop or wait for uploads before removing its domain. \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { lease.finish() }
        await lifecycleQueue.deactivate {
            let existing = (try? await NSFileProviderManager.domains()) ?? []
            for d in existing {
                _ = try? await NSFileProviderManager.remove(d, mode: .removeAll)
            }
        }
    }
}
