import SwiftUI

struct ContentView: View {
    /// Closes the hosting window. Injected by the AppKit status-item controller that
    /// owns the settings window (there is no SwiftUI presentation to `dismiss`).
    var onClose: () -> Void = {}
    @State private var serverURL = AppConfig.serverURL ?? ""
    @State private var apiKey = AppConfig.apiKey ?? ""
    @State private var result: Result?
    @State private var busy = false

    private enum Result { case ok, failed }

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
                    if let result {
                        Text(result == .ok ? "OK" : "Failed")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(result == .ok ? Color.green : Color.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @MainActor
    private func test() async {
        busy = true; result = nil; defer { busy = false }
        guard let client = ImmichClient(serverURL: serverURL, apiKey: apiKey) else {
            result = .failed; return
        }
        do {
            _ = try await client.albums()
            result = .ok
        } catch {
            result = .failed
        }
    }

    @MainActor
    private func save() async {
        busy = true; result = nil; defer { busy = false }
        AppConfig.set(serverURL: serverURL, apiKey: apiKey)   // atomically into the App Group container
        do {
            try await DomainManager.activate(reset: true)
            await ConnectionMonitor.shared.check()   // refresh the menu bar icon right away
            result = .ok
            try? await Task.sleep(for: .seconds(0.8))   // show success briefly, then close
            onClose()
        } catch {
            result = .failed
        }
    }
}
