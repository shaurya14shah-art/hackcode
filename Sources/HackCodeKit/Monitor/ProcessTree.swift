import Foundation

/// Parent/child hierarchy of sampled processes (like pstree), flattened for display.
public enum ProcessTree {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: pid_t { sample.pid }
        public let sample: ProcessSample
        public let depth: Int
        public let hasChildren: Bool
        public let isLastSibling: Bool
        /// Ancestor columns that still have later siblings (for drawing │ guides).
        public let continuingAncestors: [Bool]
        public let subtreeCPU: Double
        public let subtreeRSS: UInt64
        public let subtreeCount: Int
    }

    /// Builds rows depth-first. Siblings are ordered by `order`; children of collapsed pids are hidden.
    /// Processes whose parent is not visible become roots. Cycles (pid reuse races) are broken defensively.
    public static func rows(_ samples: [ProcessSample], collapsed: Set<pid_t> = [],
                            order: (ProcessSample, ProcessSample) -> Bool) -> [Row] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [pid_t: [ProcessSample]] = [:]
        var roots: [ProcessSample] = []
        for s in samples {
            if let parent = s.ppid, parent != s.pid, byPID[parent] != nil {
                children[parent, default: []].append(s)
            } else {
                roots.append(s)
            }
        }
        // Subtree totals (memoised, cycle-safe).
        var totals: [pid_t: (Double, UInt64, Int)] = [:]
        var visiting = Set<pid_t>()
        func total(_ pid: pid_t) -> (Double, UInt64, Int) {
            if let t = totals[pid] { return t }
            guard visiting.insert(pid).inserted, let s = byPID[pid] else { return (0, 0, 0) }
            var t = (s.cpuPercent ?? 0, s.residentBytes ?? 0, 1)
            for c in children[pid] ?? [] {
                let ct = total(c.pid)
                t = (t.0 + ct.0, t.1 + ct.1, t.2 + ct.2)
            }
            visiting.remove(pid)
            totals[pid] = t
            return t
        }

        var out: [Row] = []
        var emitted = Set<pid_t>()
        /// Descendants of a collapsed node count as reached (hidden), so the cycle fallback never re-adds them.
        func markHidden(_ pid: pid_t) {
            for c in children[pid] ?? [] where emitted.insert(c.pid).inserted { markHidden(c.pid) }
        }
        func walk(_ s: ProcessSample, depth: Int, last: Bool, guides: [Bool]) {
            guard emitted.insert(s.pid).inserted else { return }
            let kids = (children[s.pid] ?? []).sorted(by: order)
            let t = total(s.pid)
            out.append(Row(sample: s, depth: depth, hasChildren: !kids.isEmpty, isLastSibling: last, continuingAncestors: guides,
                           subtreeCPU: t.0, subtreeRSS: t.1, subtreeCount: t.2))
            guard !collapsed.contains(s.pid) else { markHidden(s.pid); return }
            for (i, k) in kids.enumerated() {
                walk(k, depth: depth + 1, last: i == kids.count - 1, guides: guides + [!last])
            }
        }
        let sortedRoots = roots.sorted(by: order)
        for (i, r) in sortedRoots.enumerated() { walk(r, depth: 0, last: i == sortedRoots.count - 1, guides: []) }
        // Anything unreachable (only possible with a parent cycle) is appended as a root.
        for s in samples where !emitted.contains(s.pid) { walk(s, depth: 0, last: true, guides: []) }
        return out
    }
}
