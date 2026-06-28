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

    func thumbnail(id: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(
            for: request("assets/\(id)/thumbnail?size=thumbnail"))
        return data
    }

    // MARK: - Timeline (All Photos by year/month)

    func monthBuckets() async throws -> [ImmichTimeBucket] {
        let (data, _) = try await URLSession.shared.data(
            for: request("timeline/buckets?size=MONTH"))
        return try JSONDecoder().decode([ImmichTimeBucket].self, from: data)
    }

    /// All assets of a month ("YYYY-MM") via paginated metadata search.
    func assets(inMonth month: String) async throws -> [ImmichAsset] {
        let (after, before) = ImmichClient.monthRange(month)
        var out: [ImmichAsset] = []
        var page = 1
        while true {
            var req = request("search/metadata")
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "takenAfter": after,
                "takenBefore": before,
                "size": 1000,
                "page": page,
                "withExif": true,   // provides exifInfo.fileSizeInByte – otherwise size 0, no download
            ]
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
