import SwiftUI
import FileProvider

struct ContentView: View {
    @State private var serverURL = AppConfig.serverURL ?? ""
    @State private var apiKey = AppConfig.apiKey ?? ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Immich-Server") {
                TextField("Server-URL", text: $serverURL)
                    .textContentType(.URL)
                SecureField("API-Key", text: $apiKey)
            }
            Section {
                HStack {
                    Button("Verbindung testen") { Task { await test() } }
                    Button("Speichern & aktivieren") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Text("Nach dem Aktivieren erscheint \"Immich\" in der Finder-Seitenleiste.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @MainActor
    private func test() async {
        busy = true; defer { busy = false }
        guard let client = ImmichClient(serverURL: serverURL, apiKey: apiKey) else {
            status = "Ungueltige URL."; return
        }
        do {
            let albums = try await client.albums()
            status = "OK – \(albums.count) Alben gefunden."
        } catch {
            status = "Fehler: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func save() async {
        busy = true; defer { busy = false }
        AppConfig.set(serverURL: serverURL, apiKey: apiKey)   // atomar in den Group-Container
        do {
            try await registerDomain()
            status = "Aktiviert. Immich ist jetzt im Finder und in Datei-Dialogen verfuegbar."
        } catch {
            status = "Domain-Fehler: \(error.localizedDescription)"
        }
    }

    private func registerDomain() async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: AppConfig.domainIdentifier),
            displayName: AppConfig.domainDisplayName
        )
        // ALLE bisherigen (eigenen) Domains entfernen – auch alte/abgemeldete –
        // und dann frisch hinzufuegen. domains() liefert nur Domains dieser App.
        let existing = try await NSFileProviderManager.domains()
        for d in existing {
            try? await NSFileProviderManager.remove(d)
        }
        try await NSFileProviderManager.add(domain)
        if let manager = NSFileProviderManager(for: domain) {
            try? await manager.signalEnumerator(for: .workingSet)
            try? await manager.signalEnumerator(for: .rootContainer)
        }
    }
}
