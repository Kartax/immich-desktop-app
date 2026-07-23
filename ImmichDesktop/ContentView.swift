import SwiftUI
import ServiceManagement

struct ContentView: View {
    /// Closes the hosting window. Injected by the AppKit status-item controller that
    /// owns the settings window (there is no SwiftUI presentation to `dismiss`).
    var onClose: () -> Void = {}
    @State private var serverURL = AppConfig.serverURL ?? ""
    @State private var apiKey = AppConfig.apiKey ?? ""
    @State private var result: Result?
    @State private var busy = false
    @State private var showTimeline = AppConfig.showTimeline
    @State private var showAlbums   = AppConfig.showAlbums
    @State private var showPersons  = AppConfig.showPersons
    @State private var showPlaces   = AppConfig.showPlaces
    @State private var groupLargeFolders = AppConfig.groupLargeFolders
    @State private var restoringGroupingSetting = false
    @State private var groupingUpdateFailed = false
    @State private var runOnStartup = SMAppService.mainApp.status == .enabled

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
            Section {
                Toggle("All Photos", isOn: $showTimeline)
                    .onChange(of: showTimeline) { _, v in
                        AppConfig.showTimeline = v
                        Task { await DomainManager.signalRoot() }
                    }
                Toggle("Albums", isOn: $showAlbums)
                    .onChange(of: showAlbums) { _, v in
                        AppConfig.showAlbums = v
                        Task { await DomainManager.signalRoot() }
                    }
                Toggle("Persons", isOn: $showPersons)
                    .onChange(of: showPersons) { _, v in
                        AppConfig.showPersons = v
                        Task { await DomainManager.signalRoot() }
                    }
                Toggle("Places", isOn: $showPlaces)
                    .onChange(of: showPlaces) { _, v in
                        AppConfig.showPlaces = v
                        Task { await DomainManager.signalRoot() }
                    }
                Toggle("Group large folders by year and month",
                       isOn: $groupLargeFolders)
                    .onChange(of: groupLargeFolders) { _, v in
                        Task { await applyGroupingSetting(v) }
                    }
                    .disabled(busy)
                if groupingUpdateFailed {
                    Text("Finder could not be refreshed. Please try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Views in Finder")
            }
            Section {
                Toggle("Run on startup", isOn: $runOnStartup)
                    .onChange(of: runOnStartup) { _, v in setRunOnStartup(v) }
            } header: {
                Text("System")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            runOnStartup = SMAppService.mainApp.status == .enabled
        }
    }

    @MainActor
    private func applyGroupingSetting(_ enabled: Bool) async {
        if restoringGroupingSetting {
            restoringGroupingSetting = false
            return
        }

        let previousValue = AppConfig.groupLargeFolders
        guard previousValue != enabled else { return }

        busy = true
        result = nil
        groupingUpdateFailed = false
        AppConfig.groupLargeFolders = enabled

        guard AppConfig.isConfigured else {
            busy = false
            return
        }

        do {
            try await DomainManager.activate(reset: true)
        } catch {
            fpLog.error(
                "Grouping setting update failed: \(error.localizedDescription, privacy: .public)"
            )
            // Keep the UI and shared configuration consistent with the hierarchy
            // that Finder still has when rebuilding its backing store fails.
            AppConfig.groupLargeFolders = previousValue
            restoringGroupingSetting = true
            groupLargeFolders = previousValue
            groupingUpdateFailed = true
        }
        busy = false
    }

    @MainActor
    private func setRunOnStartup(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            runOnStartup = SMAppService.mainApp.status == .enabled
        } catch {
            runOnStartup = SMAppService.mainApp.status == .enabled
        }
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
