import SwiftUI

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = AppConfig.serverURL ?? ""
    @State private var apiKey = AppConfig.apiKey ?? ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL,
                          prompt: Text(verbatim: "http://192.168.1.10:2283"))
                    .textContentType(.URL)
                SecureField("API Key", text: $apiKey,
                            prompt: Text("Paste your Immich API key"))
            } header: {
                Text("Immich Server")
            }
            Section {
                HStack {
                    Button("Test Connection") { Task { await test() } }
                    Button("Save & Activate") { Task { await save() } }
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
        }
        .formStyle(.grouped)
        .padding()
    }

    @MainActor
    private func test() async {
        busy = true; defer { busy = false }
        guard let client = ImmichClient(serverURL: serverURL, apiKey: apiKey) else {
            status = "Invalid URL."; return
        }
        do {
            let albums = try await client.albums()
            status = "OK – found \(albums.count) album(s)."
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func save() async {
        busy = true; defer { busy = false }
        AppConfig.set(serverURL: serverURL, apiKey: apiKey)   // atomically into the App Group container
        do {
            try await DomainManager.activate(reset: true)
            status = "Activated. Immich is now available in Finder and file dialogs."
            try? await Task.sleep(for: .seconds(0.8))   // show success briefly, then close
            dismiss()
        } catch {
            status = "Domain error: \(error.localizedDescription)"
        }
    }
}
