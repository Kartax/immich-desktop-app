import FileProvider

/// Manages the lifecycle of the Immich File Provider domain.
enum DomainManager {
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
    static func activate(reset: Bool) async throws {
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

    /// Removes all of this app's domains so Immich disappears from Finder.
    static func deactivate() async {
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        for d in existing { _ = try? await NSFileProviderManager.remove(d, mode: .removeAll) }
    }
}
