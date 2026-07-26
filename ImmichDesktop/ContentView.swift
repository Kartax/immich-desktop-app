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
    @State private var albumGroupingMode = AppConfig.albumGroupingMode
    @State private var personGroupingMode = AppConfig.personGroupingMode
    @State private var placeGroupingMode = AppConfig.placeGroupingMode
    @State private var restoringGroupingViews: Set<AdditionalView> = []
    @State private var groupingUpdateFailed = false
    @State private var runOnStartup = SMAppService.mainApp.status == .enabled

    private enum Result { case ok, failed }
    private enum AdditionalView: Hashable { case albums, persons, places }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL,
                          prompt: Text(verbatim: "http://192.168.1.10:2283"))
                    .textContentType(.URL)
                    .disabled(busy)
                SecureField("API Key", text: $apiKey,
                            prompt: Text("Paste your Immich API key"))
                    .disabled(busy)
            } header: {
                Text("Immich Server")
            }
            Section {
                HStack {
                    Button("Test Connection") { Task { await test() } }
                        .disabled(busy)
                    Button("Save & Activate") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
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
                    .disabled(busy)
                Text("Always grouped by year and month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            } header: {
                Text("Views in Finder")
            }
            Section {
                additionalViewRow(
                    "Albums", isOn: $showAlbums,
                    groupingMode: $albumGroupingMode, view: .albums)
                additionalViewRow(
                    "Persons", isOn: $showPersons,
                    groupingMode: $personGroupingMode, view: .persons)
                additionalViewRow(
                    "Places", isOn: $showPlaces,
                    groupingMode: $placeGroupingMode, view: .places)
                if groupingUpdateFailed {
                    Text("Finder could not be refreshed. Please try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Additional Views")
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

    private func additionalViewRow(
        _ title: String,
        isOn: Binding<Bool>,
        groupingMode: Binding<AppConfig.FolderGroupingMode>,
        view: AdditionalView
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: isOn)
                .onChange(of: isOn.wrappedValue) { _, enabled in
                    setVisibility(enabled, for: view)
                }
                .disabled(busy)
            Picker("Group by year and month", selection: groupingMode) {
                ForEach(AppConfig.FolderGroupingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .padding(.leading, 20)
            .disabled(!isOn.wrappedValue || busy)
            .onChange(of: groupingMode.wrappedValue) { _, mode in
                Task { await applyGroupingMode(mode, for: view) }
            }
        }
    }

    private func setVisibility(_ enabled: Bool, for view: AdditionalView) {
        switch view {
        case .albums: AppConfig.showAlbums = enabled
        case .persons: AppConfig.showPersons = enabled
        case .places: AppConfig.showPlaces = enabled
        }
        Task { await DomainManager.signalRoot() }
    }

    @MainActor
    private func applyGroupingMode(
        _ mode: AppConfig.FolderGroupingMode,
        for view: AdditionalView
    ) async {
        if restoringGroupingViews.remove(view) != nil {
            return
        }

        guard !busy else {
            restoreDisplayedGroupingMode(configuredGroupingMode(for: view), for: view)
            return
        }

        let previousMode = configuredGroupingMode(for: view)
        guard previousMode != mode else { return }

        busy = true
        result = nil
        groupingUpdateFailed = false
        setGroupingMode(mode, for: view)

        guard AppConfig.isConfigured else {
            busy = false
            return
        }

        do {
            try await DomainManager.activate(reset: true)
            AppConfig.completeGroupingModeMigration()
        } catch {
            fpLog.error(
                "Grouping setting update failed: \(error.localizedDescription, privacy: .public)"
            )
            // Keep the UI and shared configuration consistent with the hierarchy
            // that Finder still has when rebuilding its backing store fails.
            setGroupingMode(previousMode, for: view)
            restoreDisplayedGroupingMode(previousMode, for: view)
            groupingUpdateFailed = true
        }
        busy = false
    }

    private func setGroupingMode(
        _ mode: AppConfig.FolderGroupingMode,
        for view: AdditionalView
    ) {
        switch view {
        case .albums: AppConfig.albumGroupingMode = mode
        case .persons: AppConfig.personGroupingMode = mode
        case .places: AppConfig.placeGroupingMode = mode
        }
    }

    private func configuredGroupingMode(
        for view: AdditionalView
    ) -> AppConfig.FolderGroupingMode {
        switch view {
        case .albums: AppConfig.albumGroupingMode
        case .persons: AppConfig.personGroupingMode
        case .places: AppConfig.placeGroupingMode
        }
    }

    private func restoreDisplayedGroupingMode(
        _ mode: AppConfig.FolderGroupingMode,
        for view: AdditionalView
    ) {
        switch view {
        case .albums where albumGroupingMode != mode:
            restoringGroupingViews.insert(view)
            albumGroupingMode = mode
        case .persons where personGroupingMode != mode:
            restoringGroupingViews.insert(view)
            personGroupingMode = mode
        case .places where placeGroupingMode != mode:
            restoringGroupingViews.insert(view)
            placeGroupingMode = mode
        default:
            break
        }
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
            AppConfig.completeGroupingModeMigration()
            await ConnectionMonitor.shared.check()   // refresh the menu bar icon right away
            result = .ok
            try? await Task.sleep(for: .seconds(0.8))   // show success briefly, then close
            onClose()
        } catch {
            result = .failed
        }
    }
}

private extension AppConfig.FolderGroupingMode {
    var title: String {
        switch self {
        case .never: "Never"
        case .atLeast500: "500 files or more"
        case .always: "Always"
        }
    }
}
