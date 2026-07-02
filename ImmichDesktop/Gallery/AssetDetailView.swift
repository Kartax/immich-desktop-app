import SwiftUI
import AVKit

/// Full-window enlarged view over the gallery grid. Photos load the larger
/// `preview` rendition (grid thumb as instant placeholder); videos stream via
/// AVPlayer, falling back to downloading the original if streaming fails.
struct AssetDetailView: View {
    let model: GalleryViewModel
    let loader: ThumbnailLoader
    let index: Int
    let onNavigate: (Int) -> Void
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loadFailed = false
    @FocusState private var focused: Bool

    private var asset: ImmichAsset { model.assets[index] }
    private var isVideo: Bool { asset.type == "VIDEO" }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            content
        }
        .overlay(alignment: .topLeading) {
            // Opaque dark capsule + white text so the controls stay readable on any
            // photo (materials wash out over bright images).
            Button {
                onClose()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            Text(asset.originalFileName)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(10)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
        .onExitCommand { onClose() }
        .onAppear { focused = true }
        .task(id: asset.id) { await load() }
        .onDisappear { stopPlayback() }
    }

    @ViewBuilder private var content: some View {
        if let player {
            VideoPlayer(player: player)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else if loadFailed {
            ContentUnavailableView("Couldn't load this item.",
                                   systemImage: "exclamationmark.triangle")
        } else {
            ProgressView()
        }
    }

    private func navigate(_ delta: Int) {
        let target = index + delta
        guard model.assets.indices.contains(target) else { return }
        // Keep paging while stepping through the end of the loaded window.
        model.loadMoreIfNeeded(after: model.assets[target])
        onNavigate(target)
    }

    private func load() async {
        stopPlayback()
        loadFailed = false
        if isVideo {
            image = nil
            await loadVideo()
        } else {
            // Instant (blurry) placeholder from the grid cache, then the preview.
            image = loader.cachedImage(for: asset.id)
            if let preview = try? await loader.image(for: asset.id, size: .preview) {
                image = preview
            } else if image == nil {
                loadFailed = true
            }
        }
    }

    private func loadVideo() async {
        guard let client = loader.client else {
            loadFailed = true
            return
        }
        let resource = client.videoPlaybackResource(id: asset.id)
        let avAsset = AVURLAsset(url: resource.url,
                                 options: ["AVURLAssetHTTPHeaderFieldsKey": resource.headers])
        do {
            _ = try await avAsset.load(.isPlayable)
            player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
        } catch {
            // Streaming refused (e.g. key scope) — fall back to the original file.
            guard let local = try? await client.downloadOriginal(id: asset.id) else {
                loadFailed = true
                return
            }
            player = AVPlayer(url: local)
        }
        player?.play()
    }

    private func stopPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
