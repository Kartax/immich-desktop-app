import SwiftUI
import AppKit

/// The "All Photos" gallery window: a lazily-paged thumbnail grid with month
/// sections, plus an in-window enlarged view (`AssetDetailView`) on click.
struct GalleryView: View {
    let downloadBatch: DownloadBatch

    @State private var model: GalleryViewModel
    @State private var loader = ThumbnailLoader()
    @State private var selectedIndex: Int?

    init(downloadBatch: DownloadBatch) {
        self.downloadBatch = downloadBatch
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
                    Button("Retry") { Task { await model.initialLoad() } }
                }
            case .loaded:
                grid
            }

            if let index = selectedIndex {
                AssetDetailView(model: model,
                                loader: loader,
                                index: index,
                                onNavigate: { selectedIndex = $0 },
                                onClose: { selectedIndex = nil })
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Keep the app-owned batch observable while the gallery is still loading
        // or has temporarily failed to load its timeline.
        .overlay(alignment: .topTrailing) {
            galleryControls
        }
        .overlay(alignment: .bottom) {
            downloadResultBanner
        }
        .task { await model.initialLoad() }
        .onChange(of: downloadBatch.successfulAssetIDs) { _, completedIDs in
            model.removeSelectedAssets(completedIDs)
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
                                    selectionDisabled: downloadBatch.phase == .running,
                                    onToggleSelection: { withShift in
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
            if model.selectionCount > 0 || downloadBatch.phase == .running {
                selectionBar
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
            } else {
                Text(selectionText)
                Button {
                    model.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .disabled(downloadBatch.phase == .running)
                .accessibilityLabel("Clear Asset selection")
                .help("Clear selection")

                Button {
                    chooseDestinationAndStart()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .disabled(downloadBatch.phase != .idle)
                .accessibilityLabel("Download selected Assets")
                .help("Download selected Assets")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
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
        .disabled(downloadBatch.phase == .running)
    }

    @ViewBuilder
    private var downloadResultBanner: some View {
        if let result = downloadBatch.result {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.isFullSuccess
                     ? "Download complete"
                     : result.cancelled ? "Download cancelled" : "Download finished")
                    .font(.headline)
                Text("\(result.successfulAssetIDs.count) of \(result.totalCount) Assets downloaded.")
                if !result.failures.isEmpty || !result.unfinished.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.failures) { failure in
                                Text("\(failure.originalFileName): \(failure.message)")
                            }
                            ForEach(result.unfinished) { asset in
                                Text("\(asset.originalFileName): Not downloaded")
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([result.destination])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button("Dismiss") {
                        downloadBatch.consumeResult()
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 620, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .padding(12)
        }
    }

    private func jump(toMonth month: String?) {
        guard downloadBatch.phase != .running else { return }
        Task { await model.jump(toMonth: month) }
    }

    private func chooseDestinationAndStart() {
        guard downloadBatch.phase == .idle, !model.selectedAssets.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Download"
        panel.message = "Choose a destination folder for the selected Assets."
        let galleryModel = model
        let batch = downloadBatch
        panel.begin { response in
            let destination = response == .OK ? panel.url : nil
            Task { @MainActor in
                guard let destination else { return }
                let assets = galleryModel.selectedAssets
                guard !assets.isEmpty else { return }
                _ = batch.start(assets: assets, destination: destination)
            }
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
