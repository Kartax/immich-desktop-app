import FileProvider

/// Manages the lifecycle of the Immich File Provider domain.
enum DomainManager {
    private static var domain: NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: AppConfig.domainIdentifier),
            displayName: AppConfig.domainDisplayName)
    }

    /// Registers the domain so Immich appears in Finder.
    /// - Parameter reset: if true, removes any existing domain first (clears the cache
    ///   and any stale "signed out" state). Use after changing the configuration.
    static func activate(reset: Bool) async throws {
        let target = domain
        let existing = try await NSFileProviderManager.domains()
        if reset {
            for d in existing { try? await NSFileProviderManager.remove(d) }
        } else if existing.contains(where: { $0.identifier == target.identifier }) {
            return  // already active – keep the downloaded cache
        }
        try await NSFileProviderManager.add(target)
        if let manager = NSFileProviderManager(for: target) {
            try? await manager.signalEnumerator(for: .workingSet)
            try? await manager.signalEnumerator(for: .rootContainer)
        }
    }

    /// Removes all of this app's domains so Immich disappears from Finder.
    static func deactivate() async {
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        for d in existing { try? await NSFileProviderManager.remove(d) }
    }
}
