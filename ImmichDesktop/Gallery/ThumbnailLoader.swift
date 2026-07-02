import AppKit

/// Loads and caches asset images for the gallery. One instance per gallery window,
/// released together with its cache when the window closes.
@MainActor
final class ThumbnailLoader {
    let client: ImmichClient?

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage, Error>] = [:]

    init() {
        client = ImmichClient()
        // Bounds decoded-image memory; evicted entries are simply refetched.
        cache.countLimit = 1000
    }

    /// Cache-only lookup, e.g. for showing the grid thumb while the preview loads.
    func cachedImage(for id: String, size: ImmichClient.ThumbnailSize = .thumbnail) -> NSImage? {
        cache.object(forKey: cacheKey(id, size))
    }

    func image(for id: String, size: ImmichClient.ThumbnailSize = .thumbnail) async throws -> NSImage {
        let key = cacheKey(id, size)
        if let cached = cache.object(forKey: key) { return cached }
        if let running = inFlight[key as String] { return try await running.value }
        guard let client else { throw URLError(.userAuthenticationRequired) }
        let task = Task<NSImage, Error> { [cache] in
            defer { inFlight[key as String] = nil }
            let data = try await client.thumbnail(id: id, size: size)
            guard let image = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            cache.setObject(image, forKey: key)
            return image
        }
        inFlight[key as String] = task
        return try await task.value
    }

    private func cacheKey(_ id: String, _ size: ImmichClient.ThumbnailSize) -> NSString {
        "\(id)-\(size.rawValue)" as NSString
    }
}
