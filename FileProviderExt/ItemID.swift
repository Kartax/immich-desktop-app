import FileProvider

/// Encodes/decodes an item's identity as an NSFileProviderItemIdentifier.
///
/// Scheme (separator "|"):
///   root                        -> NSFileProviderItemIdentifier.rootContainer
///   "All Photos"                -> "timeline"
///   Year                        -> "year|2024"
///   Month                       -> "month|2024-03"
///   Album                       -> "album|<albumId>"
///   Persons root                -> "persons"
///   Person                      -> "person|<personId>"
///   Places root                 -> "places"
///   Country                     -> "place|<countryName>"
///   City                        -> "place|<countryName>|<cityName>"
///   Asset                       -> "asset|<parentRaw>|<assetId>"  (parent identifier embedded
///                                   so the same asset can exist under both an album and a month;
///                                   parentRaw may itself contain "|", assetId never does)
struct ItemID {
    enum Kind { case root, timeline, year, month, album, asset, persons, person, places, country, city }

    let kind: Kind
    let value: String                              // year, "YYYY-MM", albumId or assetId
    let parent: NSFileProviderItemIdentifier?

    init(_ identifier: NSFileProviderItemIdentifier) {
        let raw = identifier.rawValue

        if identifier == .rootContainer || raw == "root" {
            kind = .root; value = ""; parent = nil
            return
        }

        // Asset first: parentRaw may itself contain "|", an assetId (UUID) does not.
        if raw.hasPrefix("asset|") {
            let rest = String(raw.dropFirst("asset|".count))   // "<parentRaw>|<assetId>"
            if let sep = rest.range(of: "|", options: .backwards) {
                kind = .asset
                value = String(rest[sep.upperBound...])
                let parentRaw = String(rest[rest.startIndex..<sep.lowerBound])
                parent = (parentRaw == "root")
                    ? .rootContainer
                    : NSFileProviderItemIdentifier(rawValue: parentRaw)
                return
            }
        }

        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "timeline":
            kind = .timeline; value = ""; parent = .rootContainer
        case "year" where parts.count >= 2:
            kind = .year; value = parts[1]; parent = ItemID.timeline
        case "month" where parts.count >= 2:
            kind = .month; value = parts[1]; parent = ItemID.year(String(parts[1].prefix(4)))
        case "album" where parts.count >= 2:
            kind = .album; value = parts[1]; parent = .rootContainer
        case "persons":
            kind = .persons; value = ""; parent = .rootContainer
        case "person" where parts.count >= 2:
            kind = .person; value = parts[1]; parent = ItemID.persons
        case "places":
            kind = .places; value = ""; parent = .rootContainer
        case "place" where parts.count == 2:
            kind = .country; value = parts[1]; parent = ItemID.places
        case "place" where parts.count >= 3:
            kind = .city; value = "\(parts[1])|\(parts[2])"; parent = ItemID.country(parts[1])
        default:
            kind = .root; value = ""; parent = nil
        }
    }

    /// For .city kind, decomposes the compound value "France|Paris" → (country, city).
    var cityComponents: (country: String, city: String)? {
        guard kind == .city, let sep = value.firstIndex(of: "|") else { return nil }
        return (String(value[..<sep]), String(value[value.index(after: sep)...]))
    }

    static let timeline = NSFileProviderItemIdentifier(rawValue: "timeline")
    static let persons  = NSFileProviderItemIdentifier(rawValue: "persons")
    static let places   = NSFileProviderItemIdentifier(rawValue: "places")

    static func year(_ year: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "year|\(year)")
    }

    static func month(_ month: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "month|\(month)")
    }

    static func album(_ id: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "album|\(id)")
    }

    static func person(_ id: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "person|\(id)")
    }

    static func country(_ name: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "place|\(name)")
    }

    static func city(country: String, city: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "place|\(country)|\(city)")
    }

    static func asset(_ assetId: String,
                      parent: NSFileProviderItemIdentifier) -> NSFileProviderItemIdentifier {
        let parentRaw = (parent == .rootContainer) ? "root" : parent.rawValue
        return NSFileProviderItemIdentifier(rawValue: "asset|\(parentRaw)|\(assetId)")
    }
}
