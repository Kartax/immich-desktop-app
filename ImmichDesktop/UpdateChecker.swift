import Foundation
import Observation

/// Checks GitHub for a newer published release. This is *not* an auto-updater: it
/// only reports whether a newer version exists and points at the download page.
///
/// Releases are published as tags `vX.Y.Z` in this repo
/// `Kartax/immich-desktop-app` (see scripts/release.sh). We read the
/// latest release via the unauthenticated GitHub API (60 req/h per IP is plenty
/// for a launch check plus the occasional manual click).
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(latest: String)
        case failed
    }

    static let shared = UpdateChecker()

    private(set) var state: State = .idle

    /// How often to re-check while the app runs. Once a day is plenty for a long-lived
    /// menu bar app (the check is also run immediately on `start()`).
    private let interval: Duration = .seconds(24 * 60 * 60)
    private var pollTask: Task<Void, Never>?

    /// Checks now and then re-checks daily. Call once on launch.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: self?.interval ?? .seconds(24 * 60 * 60))
            }
        }
    }

    /// Public GitHub Pages download site.
    static let downloadPageURL = URL(string: "https://kartax.github.io/immich-desktop-app/")!

    /// Latest published release of this repo.
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/Kartax/immich-desktop-app/releases/latest")!

    private struct Release: Decodable { let tag_name: String }

    /// The running app's marketing version (CFBundleShortVersionString).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            // The tag IS the marketing version, so a plain inequality means there's a
            // different (i.e. newer, in practice) release than what's installed. We
            // only strip a leading "v" so "v0.1.0" matches CFBundleShortVersionString
            // "0.1.0". (A local dev build whose version is ahead of the latest release
            // would also flag here, but that's harmless — this is report-only.)
            let latest = Self.normalize(release.tag_name)
            state = (latest == Self.currentVersion) ? .upToDate : .updateAvailable(latest: latest)
        } catch {
            state = .failed
        }
    }

    /// Strip a leading "v" from a tag like "v0.2.0".
    private static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
