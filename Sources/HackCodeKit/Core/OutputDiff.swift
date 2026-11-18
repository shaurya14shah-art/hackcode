import Foundation

/// Line-level change detection between two command outputs (used by /watch).
public enum OutputDiff {
    /// Indices of lines in `new` that do not appear in `old` (multiset-aware: a line duplicated more often than
    /// before counts as changed). Whitespace-only differences at line ends are ignored.
    public static func changedLines(old: String, new: String) -> Set<Int> {
        var remaining: [String: Int] = [:]
        for line in lines(old) { remaining[line, default: 0] += 1 }
        var changed = Set<Int>()
        for (i, line) in lines(new).enumerated() {
            if let n = remaining[line], n > 0 {
                remaining[line] = n - 1
            } else if !line.isEmpty {
                changed.insert(i)
            }
        }
        return changed
    }

    /// Number of lines present in `old` but no longer in `new`.
    public static func removedLineCount(old: String, new: String) -> Int {
        var remaining: [String: Int] = [:]
        for line in lines(new) { remaining[line, default: 0] += 1 }
        var removed = 0
        for line in lines(old) where !line.isEmpty {
            if let n = remaining[line], n > 0 { remaining[line] = n - 1 } else { removed += 1 }
        }
        return removed
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
    }
}
