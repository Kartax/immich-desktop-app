import Foundation

struct ImmichAlbum: Codable, Identifiable {
    let id: String
    let albumName: String
    let assetCount: Int?
}

struct ImmichAlbumDetail: Codable, Identifiable {
    let id: String
    let albumName: String
    let assets: [ImmichAsset]
}

struct ImmichExif: Codable {
    let fileSizeInByte: Int?
}

struct ImmichAsset: Codable, Identifiable {
    let id: String
    let type: String              // IMAGE | VIDEO | AUDIO | OTHER
    let originalFileName: String
    let fileCreatedAt: String?
    let fileModifiedAt: String?
    let exifInfo: ImmichExif?
}

/// Eintrag aus GET /api/timeline/buckets?size=MONTH
struct ImmichTimeBucket: Codable {
    let timeBucket: String        // ISO, z. B. "2024-03-01T00:00:00.000Z"
    let count: Int
}

/// Antwort von POST /api/search/metadata (nur die benoetigten Felder).
struct ImmichSearchResponse: Codable {
    struct Assets: Codable {
        let items: [ImmichAsset]
        let nextPage: String?
    }
    let assets: Assets
}
