import SwiftUI

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = AppConfig.serverURL ?? ""
    @State private var apiKey = AppConfig.apiKey ?? ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Immich Server") {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                SecureField("API Key", text: $apiKey)
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
            Section {
                Text("After activating, \"Immich\" appears in the Finder sidebar.")
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
