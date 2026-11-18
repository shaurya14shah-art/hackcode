import Foundation

public enum FuzzyMatch {
    /// True when every character of `query` appears in `text` in order (case-insensitive), e.g. "flg" ⊂ "files.largest".
    public static func isSubsequence(_ query: String, of text: String) -> Bool {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return true }
        var i = 0
        for ch in text.lowercased() where ch == q[i] {
            i += 1
            if i == q.count { return true }
        }
        return false
    }

    /// Lower is better. Best alignment (dynamic programming): each query character that lands at the start of a
    /// word ("files.largest" → f, l) earns a bonus; gaps between matched characters cost one point each.
    /// nil when `query` is not a subsequence of `text`.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        guard q.count <= t.count else { return nil }
        let inf = Int.max / 4
        func boundary(_ j: Int) -> Bool { j == 0 || "._- /".contains(t[j - 1]) }
        var previous = [Int](repeating: inf, count: t.count)
        for j in t.indices where t[j] == q[0] { previous[j] = boundary(j) ? -10 : 0 }
        for i in 1..<q.count {
            var current = [Int](repeating: inf, count: t.count)
            var bestBefore = inf, bestK = -1
            for j in t.indices {
                // best over k < j of previous[k] - k  (so gap j-k-1 can be added as j-1 + (previous[k]-k))
                if j > 0, previous[j - 1] < inf, bestK < 0 || previous[j - 1] - (j - 1) < bestBefore {
                    bestBefore = previous[j - 1] - (j - 1)
                    bestK = j - 1
                }
                if t[j] == q[i], bestK >= 0 {
                    current[j] = bestBefore + (j - 1) + (boundary(j) ? -10 : 0)
                }
            }
            previous = current
        }
        let best = previous.min() ?? inf
        return best >= inf / 2 ? nil : best
    }

    /// Lower is better: how spread out the matched characters are (0 = contiguous).
    public static func spread(_ query: String, in text: String) -> Int {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var i = 0, first = -1, last = -1
        for (j, ch) in t.enumerated() where i < q.count && ch == q[i] {
            if first < 0 { first = j }
            last = j
            i += 1
        }
        return i == q.count ? (last - first + 1) - q.count : Int.max
    }
}
