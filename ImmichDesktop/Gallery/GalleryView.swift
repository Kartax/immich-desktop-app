import SwiftUI
import AppKit

/// The "All Photos" gallery window: a lazily-paged thumbnail grid with month
/// sections, plus an in-window enlarged view (`AssetDetailView`) on click.
struct GalleryView: View {
    let downloadBatch: DownloadBatch
    let deletionBatch: DeletionBatch
    let canStartOperation: () -> Bool

    @State private var model: GalleryViewModel
    @State private var loader = ThumbnailLoader()
    @State private var selectedIndex: Int?
    @State private var actionPending = false
    @State private var isVisible = false
    @State private var appliedDeletionIDs = Set<String>()

    init(downloadBatch: DownloadBatch, deletionBatch: DeletionBatch,
         canStartOperation: @escaping () -> Bool) {
        self.downloadBatch = downloadBatch
        self.deletionBatch = deletionBatch
        self.canStartOperation = canStartOperation
        _model = State(initialValue: GalleryViewModel())
    }

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView("Loading Assets…")
            case .notConfigured:
                ContentUnavailableView {
                    Label("Not Configured", systemImage: "gearshape")
                } description: {
                    Text("Configure your Immich server in Settings first.")
                }
            case .empty:
                ContentUnavailableView {
                    Label("No Assets", systemImage: "photo.on.rectangle")
                } description: {
                    Text("No Assets found.")
                } actions: {
                    if model.anchor != nil {
                        Button("Show Latest") { jump(toMonth: nil) }
                    }
                }
            case .error(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Assets", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        selectedIndex = nil
                        Task { await loadInitialGallery() }
                    }
                }
            case .loaded:
                grid
            }

            if let index = selectedIndex {
                AssetDetailView(
                    model: model,
                    loader: loader,
                    index: index,
                    canDownload: operationsIdle && !actionPending,
                    showDelete: deletionBatch.allowDeletions,
                    canDelete: operationsIdle && deletionBatch.canDelete && !actionPending,
                    deletePermissionMissing: deletionBatch.permission == .missing,
                    onNavigate: { selectedIndex = $0 },
                    onDownload: { chooseDestinationAndStart(assets: [$0]) },
                    onDelete: { confirmDeletion(assets: [$0]) },
                    onClose: { selectedIndex = nil }
                )
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Keep the app-owned batch observable while the gallery is still loading
        // or has temporarily failed to load its timeline.
        .overlay(alignment: .topTrailing) {
            if selectedIndex == nil {
                galleryControls
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                downloadResultBanner
                deletionResultBanner
            }
        }
        .task {
            isVisible = true
            await deletionBatch.refreshCapabilities()
            await loadInitialGallery()
        }
        .onDisappear { isVisible = false }
        .onChange(of: deletionBatch.connectionID) { _, _ in
            guard model.connectionID != deletionBatch.connectionID else { return }
            selectedIndex = nil
            loader = ThumbnailLoader()
            appliedDeletionIDs = []
            Task { await loadInitialGallery() }
        }
        .onChange(of: deletionBatch.successfulAssetIDs) { _, _ in
            applyConfirmedDeletions()
        }
        .onChange(of: deletionBatch.result) { _, _ in
            applyConfirmedDeletions()
            restoreRetryableSelection()
        }
        .onChange(of: operationRunning) { _, running in
            model.setPagingSuspended(running)
        }
        .onChange(of: downloadBatch.successfulAssetIDs) { _, completedIDs in
            model.removeSelectedAssets(completedIDs)
        }
        .onChange(of: downloadBatch.result) { _, _ in
            restoreRetryableSelection()
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 2)],
                          spacing: 2,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.assets) { asset in
                                GalleryCell(
                                    asset: asset,
                                    loader: loader,
                                    isSelected: model.isSelected(asset.id),
                                    selectionDisabled: operationRunning || actionPending,
                                    onToggleSelection: { withShift in
                                        guard !operationRunning, !actionPending else { return }
                                        model.toggleSelection(of: asset.id, withShift: withShift)
                                    },
                                    onOpen: {
                                        selectedIndex = model.index(of: asset)
                                    }
                                )
                                .onAppear { model.loadMoreIfNeeded(after: asset) }
                            }
                        } header: {
                            sectionHeader(section.title)
                        }
                    }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
            }
        }
    }

    private var galleryControls: some View {
        HStack(spacing: 8) {
            if model.selectionCount > 0 || operationRunning {
                selectionBar
            }
            if model.selectionCount > 0 && !operationRunning {
                selectionActions
            }
            if case .loaded = model.phase, !model.yearGroups.isEmpty {
                jumpMenu
            }
        }
        .padding(12)
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if downloadBatch.phase == .running {
                Text(downloadProgressText)
                    .monospacedDigit()
                Button {
                    downloadBatch.cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Download")
                .help("Cancel Download")
            } else if deletionBatch.phase == .running {
                Text("Deleting \(deletionBatch.progress.completedCount) of \(deletionBatch.progress.totalCount)")
                    .monospacedDigit()
                Button("Stop") { deletionBatch.stop() }
                    .buttonStyle(.plain)
                    .help("Stop after the current request finishes")
            } else {
                Text(selectionText)
                Button {
                    guard !operationRunning, !actionPending else { return }
                    model.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .disabled(operationRunning || actionPending)
                .accessibilityLabel("Clear Asset selection")
                .help("Clear selection")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .fixedSize()
    }

    /// Separate action surface for selection-wide actions. Keep this panel
    /// independent so additional actions can be added without crowding the
    /// selection status.
    private var selectionActions: some View {
        HStack(spacing: 8) {
            Button {
                chooseDestinationAndStart(assets: model.selectedAssets)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(!operationsIdle || actionPending)
            .accessibilityLabel("Download selected Assets")
            .help("Download selected Assets")
            if deletionBatch.allowDeletions {
                Button {
                    confirmDeletion(assets: model.selectedAssets)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(!operationsIdle || !deletionBatch.canDelete || actionPending)
                .accessibilityLabel("Delete selected Assets")
                .help(deletionBatch.permission == .missing
                      ? "Delete is disabled: this API key needs asset.delete permission. See Settings."
                      : "Delete selected Assets from the Immich library")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .fixedSize()
    }

    private var selectionText: String {
        let noun = model.selectionCount == 1 ? "Asset" : "Assets"
        return "\(model.selectionCount) \(noun) selected"
    }

    private var downloadProgressText: String {
        let progress = downloadBatch.progress
        let current = progress.currentFileName == nil
            ? progress.completedCount
            : min(progress.completedCount + 1, progress.totalCount)
        return "Downloading \(current) of \(progress.totalCount)"
    }

    private var operationRunning: Bool {
        downloadBatch.phase == .running || deletionBatch.phase == .running
    }

    private var operationsIdle: Bool {
        canStartOperation() && downloadBatch.phase == .idle && deletionBatch.phase == .idle
    }

    /// Year → month menu that re-anchors the timeline (no intervening pages are
    /// loaded; jumping resets the list, so the scroll position starts fresh).
    private var jumpMenu: some View {
        Menu {
            Button("Latest") { jump(toMonth: nil) }
            ForEach(model.yearGroups) { year in
                Menu(year.id) {
                    ForEach(year.months) { month in
                        Button("\(month.title) (\(month.count))") {
                            jump(toMonth: month.id)
                        }
                    }
                }
            }
        } label: {
            Label("Jump to", systemImage: "calendar")
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(operationRunning || actionPending)
    }

    @ViewBuilder
    private var downloadResultBanner: some View {
        if let result = downloadBatch.result {
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.isFullSuccess
                     ? "Download complete"
                     : result.cancelled ? "Download cancelled" : "Download finished")
                    .font(.headline)
                    .padding(.trailing, 28)
                Text(resultSummary(result))
                if !result.failures.isEmpty {
                    resultSection(title: "Failed Assets") {
                        ForEach(result.failures) { failure in
                            Text("\(failure.originalFileName): \(failure.message)")
                        }
                    }
                }
                if !result.unfinished.isEmpty {
                    resultSection(title: "Unfinished Assets (retained for retry)") {
                        ForEach(result.unfinished) { asset in
                            Text("\(asset.originalFileName): Not downloaded")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 620, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .overlay(alignment: .topTrailing) {
                Button(action: dismissDownloadResult) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss download result")
                .help("Dismiss download result")
                .padding(14)
            }
            .padding(12)
            .task {
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    guard downloadBatch.result == result else { return }
                    dismissDownloadResult()
                } catch {}
            }
        }
    }

    @ViewBuilder
    private var deletionResultBanner: some View {
        if let result = deletionBatch.result {
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.isFullSuccess ? "Deletion complete"
                     : result.stopped ? "Deletion stopped" : "Deletion finished")
                    .font(.headline)
                    .padding(.trailing, 28)
                Text("\(result.successfulAssetIDs.count) deleted, \(result.failures.count) failed, \(result.unfinished.count) not attempted, \(result.uncertain.count) uncertain.")
                if let message = result.message {
                    Text(message).font(.callout)
                }
                if !result.successfulAssetIDs.isEmpty {
                    Text("Server deletion is confirmed. Finder updates may still be pending; downloaded copies are not removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.failures.isEmpty {
                    resultSection(title: "Failed Assets (retained for retry)") {
                        ForEach(result.failures) { failure in
                            Text("\(failure.originalFileName): \(failure.message)")
                        }
                    }
                }
                if !result.unfinished.isEmpty {
                    resultSection(title: "Not attempted (retained for retry)") {
                        ForEach(result.unfinished) { asset in
                            Text(asset.originalFileName)
                        }
                    }
                }
                if !result.uncertain.isEmpty {
                    resultSection(title: "Uncertain outcomes — check Immich before trying again") {
                        ForEach(result.uncertain) { failure in
                            Text("\(failure.originalFileName): \(failure.message)")
                        }
                    }
                    Text("These Assets are not selected for retry. The server may already have deleted them.")
                        .font(.caption)
                }
                if deletionBatch.batchConnectionID != model.connectionID {
                    Text("This result belongs to another server or API key. Reconnect to that connection to retry.")
                        .font(.caption)
                } else if !result.retryableAssetIDs.isEmpty {
                    Text("Failed and not-attempted Assets stay selected as their pages load. Load them all to retry this result, or dismiss it to act on a smaller selection. Retry always asks for a new confirmation.")
                        .font(.caption)
                }
                    if deletionBatch.allowDeletions,
                       deletionBatch.batchConnectionID == model.connectionID,
                       !result.retryableAssetIDs.isEmpty {
                        let retryIDs = Set(result.retryableAssetIDs)
                        let retryAssets = model.assets.filter { retryIDs.contains($0.id) }
                        Button("Retry \(retryIDs.count) Assets…") {
                            confirmDeletion(assets: retryAssets, retrying: true)
                        }
                        .disabled(retryAssets.count != retryIDs.count || actionPending || operationRunning
                                  || downloadBatch.phase != .idle
                                  || deletionBatch.permission == .missing)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 620, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .overlay(alignment: .topTrailing) {
                Button(action: dismissDeletionResult) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .disabled(actionPending)
                .accessibilityLabel("Dismiss deletion result")
                .help("Dismiss deletion result")
                .padding(14)
            }
            .padding(12)
            .task(id: actionPending) {
                // Keep the retained result alive while a retry confirmation is open.
                guard !actionPending else { return }
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    guard deletionBatch.result == result else { return }
                    dismissDeletionResult()
                } catch {}
            }
        }
    }

    private func dismissDownloadResult() {
        restoreRetryableSelection()
        downloadBatch.consumeResult()
    }

    private func dismissDeletionResult() {
        guard !actionPending else { return }
        restoreRetryableSelection()
        deletionBatch.consumeResult()
    }

    private func resultSummary(_ result: DownloadBatch.BatchResult) -> String {
        var parts = ["\(result.completedCount) completed"]
        if result.failureCount > 0 {
            parts.append("\(result.failureCount) failed")
        }
        if result.unfinishedCount > 0 {
            parts.append("\(result.unfinishedCount) unfinished")
        }
        return parts.joined(separator: ", ") + "."
    }

    private func resultSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .font(.caption)
        }
    }

    private func jump(toMonth month: String?) {
        guard !operationRunning, !actionPending else { return }
        // A timeline reset replaces the loaded ordering, so detail must close
        // before the old index can become invalid.
        selectedIndex = nil
        Task {
            await model.jump(toMonth: month)
            restoreRetryableSelection()
        }
    }

    private func loadInitialGallery() async {
        // A new server snapshot is authoritative for older confirmed deletions:
        // an Asset restored in Immich must be allowed to appear again.
        appliedDeletionIDs = deletionBatch.batchConnectionID == ImmichClient()?.connectionID
            ? Set(deletionBatch.successfulAssetIDs) : []
        model.setPagingSuspended(operationRunning)
        await model.initialLoad()
        applyConfirmedDeletions()
        restoreRetryableSelection()
        if !operationRunning { model.setPagingSuspended(false) }
    }

    private func restoreRetryableSelection() {
        if downloadBatch.phase == .completed, let result = downloadBatch.result {
            model.removeSelectedAssets(result.successfulAssetIDs)
            model.restoreSelection(for: result.retryableAssetIDs)
        }
        if deletionBatch.phase == .completed,
           deletionBatch.batchConnectionID == model.connectionID,
           let result = deletionBatch.result {
            model.removeSelectedAssets(result.successfulAssetIDs + result.uncertain.map(\.assetID))
            model.restoreSelection(for: result.retryableAssetIDs)
        }
    }

    private func chooseDestinationAndStart(assets: [ImmichAsset]) {
        guard operationsIdle, !actionPending, !assets.isEmpty,
              let connectionID = model.connectionID,
              connectionID == ImmichClient()?.connectionID else { return }
        actionPending = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = assets.count == 1
            ? "Choose a destination folder for this Asset."
            : "Choose a destination folder for the selected Assets."
        panel.begin { response in
            let destination = response == .OK ? panel.url : nil
            Task { @MainActor in
                actionPending = false
                guard isVisible, operationsIdle,
                      connectionID == ImmichClient()?.connectionID,
                      let destination else { return }
                _ = downloadBatch.start(assets: assets, destination: destination)
            }
        }
    }

    private func applyConfirmedDeletions() {
        guard model.connectionID == deletionBatch.batchConnectionID else { return }
        let newIDs = deletionBatch.successfulAssetIDs.filter {
            !appliedDeletionIDs.contains($0)
        }
        guard !newIDs.isEmpty else { return }
        // Detail navigation uses indices, so close before mutating the ordering.
        selectedIndex = nil
        loader.invalidate(assetIDs: newIDs)
        appliedDeletionIDs.formUnion(newIDs)
        model.removeConfirmedAssets(newIDs)
        if !operationRunning { model.setPagingSuspended(false) }
    }

    private func confirmDeletion(assets: [ImmichAsset], retrying: Bool = false) {
        guard canStartOperation(), !assets.isEmpty, !actionPending, !operationRunning,
              downloadBatch.phase == .idle,
              deletionBatch.allowDeletions, deletionBatch.permission != .missing,
              retrying ? deletionBatch.phase == .completed : deletionBatch.phase == .idle,
              let connectionID = model.connectionID,
              connectionID == ImmichClient()?.connectionID,
              let window = NSApp.keyWindow else { return }
        let retainedResult = deletionBatch.result
        actionPending = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(assets.count) \(assets.count == 1 ? "Asset" : "Assets") from Immich?"
        alert.informativeText = "This removes the selected Assets from your entire library and all albums, not just this gallery.\n\n\(trashWarning)\(permissionWarning)\n\nThere is no Undo in Immich Desktop."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete \(assets.count) \(assets.count == 1 ? "Asset" : "Assets")")
            .hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                actionPending = false
                guard canStartOperation(), response == .alertSecondButtonReturn, isVisible,
                      !operationRunning, downloadBatch.phase == .idle,
                      deletionBatch.allowDeletions, deletionBatch.permission != .missing,
                      connectionID == ImmichClient()?.connectionID,
                      connectionID == model.connectionID else { return }
                if retrying {
                    guard deletionBatch.phase == .completed,
                          deletionBatch.result == retainedResult,
                          deletionBatch.batchConnectionID == connectionID else { return }
                    deletionBatch.consumeResult()
                }
                guard operationsIdle else { return }
                appliedDeletionIDs = []
                _ = deletionBatch.start(assets: assets)
            }
        }
    }

    private var permissionWarning: String {
        if case .unknown = deletionBatch.permission {
            return "\n\nThe API key's deletion permission could not be verified. You explicitly enabled deletion attempts in Settings."
        }
        return ""
    }

    private var trashWarning: String {
        switch deletionBatch.trashPolicy {
        case .enabled(let days):
            if let days {
                return "Immich reports that trash is enabled with a \(days)-day retention period. The server controls recovery and may empty trash sooner."
            }
            return "Immich reports that trash is enabled. Retention and recovery are controlled by the server."
        case .disabled:
            return "Immich reports that trash is disabled. Deletion may be permanent."
        case .unknown:
            return "The server's trash policy could not be verified. Deletion may be permanent."
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// One square grid tile: async thumbnail, video badge, detail tap target, and a
/// hover-revealed Asset selection control.
private struct GalleryCell: View {
    let asset: ImmichAsset
    let loader: ThumbnailLoader
    let isSelected: Bool
    let selectionDisabled: Bool
    let onToggleSelection: (Bool) -> Void
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var isHovering = false
    private var selectionSymbol: String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }
    private var selectionAccessibilityLabel: String {
        isSelected ? "Deselect \(asset.originalFileName)" : "Select \(asset.originalFileName)"
    }

    private var selectionButton: some View {
        Button {
            onToggleSelection(NSEvent.modifierFlags.contains(.shift))
        } label: {
            Image(systemName: selectionSymbol)
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                .shadow(radius: 2)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .opacity(isSelected || isHovering ? 1 : 0)
        .allowsHitTesting(!selectionDisabled && (isSelected || isHovering))
        .disabled(selectionDisabled)
        .accessibilityLabel(selectionAccessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .help(isSelected ? "Deselect Asset" : "Select Asset")
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.type == "VIDEO" {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                selectionButton
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    .padding(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onHover { isHovering = $0 }
            .task(id: asset.id) {
                if image == nil {
                    image = try? await loader.image(for: asset.id)
                }
            }
    }
}
