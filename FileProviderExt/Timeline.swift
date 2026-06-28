import Foundation

/// Helpers for the time view (All Photos -> Year -> Month).
enum TimelineFormat {
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "2024-03" -> "03 March" (leading number keeps Finder sorting chronological).
    static func monthDisplay(_ month: String) -> String {
        let mm = String(month.suffix(2))
        if let i = Int(mm), (1...12).contains(i) {
            return "\(mm) \(monthNames[i - 1])"
        }
        return month
    }

    /// Unique values, preserving input order.
    static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values where seen.insert(v).inserted { out.append(v) }
        return out
    }
}
