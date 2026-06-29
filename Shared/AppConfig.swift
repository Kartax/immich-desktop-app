import Foundation

/// Shared configuration between the container app and the extension.
///
/// Deliberately NOT via UserDefaults(suiteName:) — that is unreliable for App Groups
/// on macOS (cfprefsd refuses "kCFPreferencesAnyUser with a container"). Instead a
/// JSON file directly in the App Group container that both processes can read.
enum AppConfig {
    static let appGroup = "group.org.kartax.ImmichDesktop"
    // Stable, permanent domain identifier — do NOT version-bump it as a recovery trick.
    // A stuck "signed out" state is cleared by a thorough teardown in DomainManager
    // (remove with .removeAll), not by renaming the identifier.
    static let domainIdentifier = "ImmichDesktop"
    static let domainDisplayName = "ImmichDesktop"   // the label shown in Finder's sidebar

    private struct Stored: Codable {
        var serverURL: String?
        var apiKey: String?
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("config.json")
    }

    private static func load() -> Stored {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored()
        }
        return stored
    }

    private static func store(_ stored: Stored) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var serverURL: String? {
        get { load().serverURL }
        set { var s = load(); s.serverURL = newValue; store(s) }
    }

    static var apiKey: String? {
        get { load().apiKey }
        set { var s = load(); s.apiKey = newValue; store(s) }
    }

    static var isConfigured: Bool {
        let s = load()
        return !(s.serverURL ?? "").isEmpty && !(s.apiKey ?? "").isEmpty
    }

    /// Set both values atomically in a single write.
    static func set(serverURL: String, apiKey: String) {
        store(Stored(serverURL: serverURL, apiKey: apiKey))
    }

    static func flush() { /* file write is already synchronous/atomic */ }
}
