import Foundation

/// Check × run matrix built from audit history, for spotting drift (a check that flips between runs).
public struct AuditTimeline: Sendable, Equatable {
    public enum Cell: String, Sendable {
        case pass, issue, observed, couldNotRun

        init(status: String) {
            switch status {
            case FindingStatus.pass.rawValue, FindingStatus.remediated.rawValue: self = .pass
            case FindingStatus.issue.rawValue, FindingStatus.unresolved.rawValue: self = .issue
            case FindingStatus.observed.rawValue: self = .observed
            default: self = .couldNotRun
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// One entry per run (oldest → newest); nil when the check did not exist in that run.
        public let cells: [Cell?]
        /// Number of times the result changed between consecutive runs where it was present.
        public let flips: Int
    }

    /// Oldest → newest.
    public let runs: [AuditSummary]
    public let rows: [Row]

    public static func make(_ history: [AuditSummary], lastRuns: Int = 20) -> AuditTimeline {
        let runs = Array(history.sorted { $0.date < $1.date }.suffix(lastRuns))
        var titles: [String: String] = [:]
        for r in runs { for (id, e) in r.checks { titles[id] = e.title } }
        let rows = titles.keys.map { id -> Row in
            let cells = runs.map { $0.checks[id].map { Cell(status: $0.status) } }
            let present = cells.compactMap { $0 }
            let flips = zip(present, present.dropFirst()).filter { $0 != $1 }.count
            return Row(id: id, title: titles[id] ?? id, cells: cells, flips: flips)
        }
        let sorted = rows.sorted { a, b in
            let ai = a.cells.last.flatMap { $0 } == .issue, bi = b.cells.last.flatMap { $0 } == .issue
            if ai != bi { return ai }
            if a.flips != b.flips { return a.flips > b.flips }
            return a.title < b.title
        }
        return AuditTimeline(runs: runs, rows: sorted)
    }

    public static func issueCount(_ s: AuditSummary) -> Int {
        s.checks.values.filter { Cell(status: $0.status) == .issue }.count
    }
}
