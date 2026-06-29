import Foundation
import Observation

/// Tracks whether the configured Immich server is actually reachable, so the menu bar
/// icon can reflect it. App-side only — the extension never observes this.
///
/// Polls a lightweight authenticated probe (`ImmichClient.checkConnection`) on a timer
/// and on demand. "Not connected" deliberately covers both "no config yet" and "server
/// unreachable / bad key": from the user's point of view the integration isn't live in
/// either case, and the icon dims the same way (the macOS-standard "inactive" look).
@MainActor
@Observable
final class ConnectionMonitor {
    enum Status {
        case notConfigured
        case connected
        case disconnected

        /// Whether Immich is live — drives the full-strength vs. dimmed menu bar icon.
        var isConnected: Bool { self == .connected }
    }

    static let shared = ConnectionMonitor()

    private(set) var status: Status = .notConfigured

    /// How often to re-probe while the app is running.
    private let interval: Duration = .seconds(30)
    private var pollTask: Task<Void, Never>?

    private init() {}

    /// Starts (or restarts) the background polling loop.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: self?.interval ?? .seconds(30))
            }
        }
    }

    /// Runs a single probe now and updates `status`. Safe to call from UI actions
    /// (e.g. right after "Save & Activate") to refresh the icon immediately.
    func check() async {
        guard AppConfig.isConfigured, let client = ImmichClient() else {
            status = .notConfigured
            return
        }
        do {
            try await client.checkConnection()
            status = .connected
        } catch {
            status = .disconnected
        }
    }
}
