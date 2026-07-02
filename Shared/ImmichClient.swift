import Foundation
import os

let fpLog = Logger(subsystem: "org.kartax.ImmichDesktop", category: "fileprovider")

/// Lightweight client for the Immich REST API (read-only).
struct ImmichClient {
    let baseURL: URL      // ends with .../api
    let apiKey: String

    init?(serverURL: String, apiKey: String) {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/api") { s += "/api" }
        guard let url = URL(string: s) else { return nil }
        self.baseURL = url
        self.apiKey = apiKey
    }

    /// Initializes from the shared App Group configuration.
    init?() {
        let s = AppConfig.serverURL
        let k = AppConfig.apiKey
        fpLog.info("ImmichClient(): serverURL=\(s ?? "nil", privacy: .public), hasKey=\(k?.isEmpty == false, privacy: .public)")
        guard let s, !s.isEmpty, let k, !k.isEmpty else {
            fpLog.error("ImmichClient(): configuration missing – notAuthenticated")
            return nil
        }
        self.init(serverURL: s, apiKey: k)
    }

    private func request(_ path: String) -> URLRequest {
        let url = URL(string: baseURL.absoluteString + "/" + path)!
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// Lightweight reachability + auth probe used by the connection monitor.
    /// Hits `/albums` and throws unless it returns 200. Must use an endpoint covered by
    /// the required API-key scopes (`album.read`) — e.g. `/users/me` would 403 with our
    /// key and make the status icon look perpetually disconnected.
    func checkConnection() async throws {
        let (_, response) = try await URLSession.shared.data(for: request("albums"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    func albums() async throws -> [ImmichAlbum] {
        let (data, _) = try await URLSession.shared.data(for: request("albums"))
        return try JSONDecoder().decode([ImmichAlbum].self, from: data)
    }

    func album(id: String) async throws -> ImmichAlbumDetail {
        let (data, _) = try await URLSession.shared.data(for: request("albums/\(id)"))
        return try JSONDecoder().decode(ImmichAlbumDetail.self, from: data)
    }

    func asset(id: String) async throws -> ImmichAsset {
        let (data, _) = try await URLSession.shared.data(for: request("assets/\(id)"))
        return try JSONDecoder().decode(ImmichAsset.self, from: data)
    }

    /// Downloads the original into a temporary file and returns its URL.
    func downloadOriginal(id: String) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(for: request("assets/\(id)/original"))
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Server-generated image sizes for GET /assets/{id}/thumbnail. `fullsize` is
    /// deliberately absent — it only exists on newer Immich servers.
    enum ThumbnailSize: String {
        case thumbnail   // small, for grid tiles
        case preview     // larger, for enlarged views
    }

    func thumbnail(id: String, size: ThumbnailSize = .thumbnail) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(
            for: request("assets/\(id)/thumbnail?size=\(size.rawValue)"))
        return data
    }

    /// URL + auth header for streaming a video with AVPlayer (the server transcodes
    /// when needed). Inject the headers via `AVURLAssetHTTPHeaderFieldsKey`.
    func videoPlaybackResource(id: String) -> (url: URL, headers: [String: String]) {
        (URL(string: baseURL.absoluteString + "/assets/\(id)/video/playback")!,
         ["x-api-key": apiKey])
    }

    // MARK: - Timeline (All Photos by year/month)

    func monthBuckets() async throws -> [ImmichTimeBucket] {
        let (data, _) = try await URLSession.shared.data(
            for: request("timeline/buckets?size=MONTH"))
        return try JSONDecoder().decode([ImmichTimeBucket].self, from: data)
    }

    /// One page of the global "All Photos" timeline, newest first. Unlike `pagedSearch`
    /// this fetches a SINGLE page — the gallery pages in more while scrolling instead
    /// of materializing the whole library. `takenBefore` anchors the timeline at a
    /// date (gallery "jump to month") without loading any intervening pages.
    func assetsPage(page: Int, size: Int = 200,
                    takenBefore: String? = nil) async throws -> (assets: [ImmichAsset], nextPage: Int?) {
        var req = request("search/metadata")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "page": page,
            "size": size,
            "order": "desc",
        ]
        if let takenBefore { body["takenBefore"] = takenBefore }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let resp = try JSONDecoder().decode(ImmichSearchResponse.self, from: data)
        return (resp.assets.items, resp.assets.nextPage.flatMap(Int.init))
    }

    /// All assets of a month ("YYYY-MM") via paginated metadata search.
    func assets(inMonth month: String) async throws -> [ImmichAsset] {
        let (after, before) = ImmichClient.monthRange(month)
        return try await pagedSearch([
            "takenAfter": after,
            "takenBefore": before,
            "withExif": true,   // provides exifInfo.fileSizeInByte – otherwise size 0, no download
        ])
    }

    // MARK: - Persons

    /// GET /api/people — returns only visible, named persons.
    func people() async throws -> [ImmichPerson] {
        let (data, _) = try await URLSession.shared.data(for: request("people"))
        let resp = try JSONDecoder().decode(ImmichPeopleResponse.self, from: data)
        return resp.people.filter { ($0.isHidden ?? false) == false && !($0.name ?? "").isEmpty }
    }

    /// Assets for a person via POST /api/search/metadata with personIds filter.
    func assets(forPerson personId: String) async throws -> [ImmichAsset] {
        return try await pagedSearch([
            "personIds": [personId],
            "withExif": true,
        ])
    }

    // MARK: - Places

    /// GET /api/search/suggestions?type=country — all unique country name strings.
    func countries() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(
            for: request("search/suggestions?type=country"))
        return try JSONDecoder().decode([String].self, from: data).sorted()
    }

    /// GET /api/search/suggestions?type=city&country={name} — unique city names for a country.
    func cities(inCountry country: String) async throws -> [String] {
        let encoded = country.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? country
        let (data, _) = try await URLSession.shared.data(
            for: request("search/suggestions?type=city&country=\(encoded)"))
        return try JSONDecoder().decode([String].self, from: data).sorted()
    }

    /// POST /api/search/metadata filtered by city + country.
    func assets(inCity city: String, country: String) async throws -> [ImmichAsset] {
        return try await pagedSearch([
            "city": city,
            "country": country,
            "withExif": true,
        ])
    }

    // MARK: - Private helpers

    private func pagedSearch(_ baseBody: [String: Any]) async throws -> [ImmichAsset] {
        var out: [ImmichAsset] = []
        var page = 1
        while true {
            var req = request("search/metadata")
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = baseBody
            body["size"] = 1000
            body["page"] = page
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(ImmichSearchResponse.self, from: data)
            out.append(contentsOf: resp.assets.items)
            guard let next = resp.assets.nextPage, let p = Int(next) else { break }
            page = p
        }
        return out
    }

    /// Half-open interval [month start, next month start) as ISO strings.
    static func monthRange(_ month: String) -> (after: String, before: String) {
        let parts = month.split(separator: "-")
        let y = Int(parts.first ?? "") ?? 1970
        let m = Int(parts.count > 1 ? parts[1] : "") ?? 1
        let after = String(format: "%04d-%02d-01T00:00:00.000Z", y, m)
        let (ny, nm) = (m >= 12) ? (y + 1, 1) : (y, m + 1)
        let before = String(format: "%04d-%02d-01T00:00:00.000Z", ny, nm)
        return (after, before)
    }
}
