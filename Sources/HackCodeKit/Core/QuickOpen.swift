import Foundation

/// "Open Quickly" (⌘⇧O): one fuzzy search across modules, processes, findings, folders, commands and operations.
public struct QuickItem: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case module = "MODULE", command = "COMMAND", finding = "FINDING", process = "PROCESS", folder = "FOLDER", operation = "OP"

        /// Tie-break order when scores are equal.
        var priority: Int { Self.allCases.firstIndex(of: self) ?? 99 }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String

    public init(id: String, kind: Kind, title: String, subtitle: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

public enum QuickOpen {
    /// Empty query → the first `limit` items as given. Otherwise items whose title (or, with a penalty, subtitle)
    /// contains the query as a subsequence, best first; a title prefix match ranks highest.
    public static func rank(_ items: [QuickItem], query: String, limit: Int = 50) -> [QuickItem] {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return Array(items.prefix(limit)) }
        // Scattered matches (letters spread across a long name) are noise, not intent: total gap cost must stay ≤ query length.
        let worstAccepted = q.count
        let scored: [(QuickItem, Int)] = items.compactMap { item in
            let title = item.title.lowercased()
            var best: Int?
            if let s = FuzzyMatch.score(q, in: title), s <= worstAccepted { best = s + (title.hasPrefix(q) ? -25 : 0) + (title == q ? -25 : 0) }
            if let s = FuzzyMatch.score(q, in: item.subtitle), s <= worstAccepted { best = min(best ?? .max, s + 15) }
            return best.map { (item, $0) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.kind.priority != b.0.kind.priority { return a.0.kind.priority < b.0.kind.priority }
            return a.0.title.count < b.0.title.count
        }
        .prefix(limit).map(\.0)
    }
}
