import SwiftUI

/// The "All Photos" gallery window: a lazily-paged thumbnail grid with month
/// sections, plus an in-window enlarged view (`AssetDetailView`) on click.
struct GalleryView: View {
    @State private var model = GalleryViewModel()
    @State private var loader = ThumbnailLoader()
    @State private var selectedIndex: Int?

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView("Loading photos…")
            case .notConfigured:
                ContentUnavailableView {
                    Label("Not Configured", systemImage: "gearshape")
                } description: {
                    Text("Configure your Immich server in Settings first.")
                }
            case .empty:
                ContentUnavailableView {
                    Label("No Photos", systemImage: "photo.on.rectangle")
                } description: {
                    Text("No photos found.")
                } actions: {
                    // A jumped-to window can (rarely) come back empty — offer a way out.
                    if model.anchor != nil {
                        Button("Show Latest") { Task { await model.jump(toMonth: nil) } }
                    }
                }
            case .error(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Photos", systemImage: "exclamationmark.triangle")
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
        .task { await model.initialLoad() }
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
                                GalleryCell(asset: asset, loader: loader)
                                    .onAppear { model.loadMoreIfNeeded(after: asset) }
                                    .onTapGesture { selectedIndex = model.index(of: asset) }
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
        .overlay(alignment: .topTrailing) {
            if !model.yearGroups.isEmpty {
                jumpMenu.padding(12)
            }
        }
    }

    /// Year → month menu that re-anchors the timeline (no intervening pages are
    /// loaded; jumping resets the list, so the scroll position starts fresh).
    private var jumpMenu: some View {
        Menu {
            Button("Latest") { Task { await model.jump(toMonth: nil) } }
            ForEach(model.yearGroups) { year in
                Menu(year.id) {
                    ForEach(year.months) { month in
                        Button("\(month.title) (\(month.count))") {
                            Task { await model.jump(toMonth: month.id) }
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

/// One square grid tile: async thumbnail with a placeholder, video badge, tap target.
private struct GalleryCell: View {
    let asset: ImmichAsset
    let loader: ThumbnailLoader

    @State private var image: NSImage?

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
            .contentShape(Rectangle())
            .task(id: asset.id) {
                if image == nil {
                    image = try? await loader.image(for: asset.id)
                }
            }
    }
}
