import Foundation

/// Geteilte Konfiguration zwischen Container-App und Extension.
///
/// Bewusst NICHT ueber UserDefaults(suiteName:) — das ist auf macOS mit App Groups
/// unzuverlaessig (cfprefsd verweigert "kCFPreferencesAnyUser with a container").
/// Stattdessen eine JSON-Datei direkt im App-Group-Container, die beide Prozesse lesen.
enum AppConfig {
    static let appGroup = "group.org.kartax.ImmichDesktop"
    static let domainIdentifier = "immich-v2"   // frische ID, umgeht alten "abgemeldet"-Zustand
    static let domainDisplayName = "Immich"

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

    /// Beide Werte atomar in einem Schreibvorgang setzen.
    static func set(serverURL: String, apiKey: String) {
        store(Stored(serverURL: serverURL, apiKey: apiKey))
    }

    static func flush() { /* Dateischreibvorgang ist bereits synchron/atomar */ }
}
