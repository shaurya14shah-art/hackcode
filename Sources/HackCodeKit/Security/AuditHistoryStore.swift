import Foundation

/// Compact, evidence-free summary of an audit run, persisted to detect posture drift between runs.
public struct AuditSummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let status: String
        public let severity: String
        public let title: String

        public init(status: String, severity: String, title: String) {
            self.status = status
            self.severity = severity
            self.title = title
        }
    }
    public let date: Date
    public let score: Int?
    public let checks: [String: Entry]

    public init(date: Date, score: Int?, checks: [String: Entry] = [:]) {
        self.date = date
        self.score = score
        self.checks = checks
    }

    public init(run: AuditRun) {
        date = run.finishedAt ?? Date()
        score = run.score
        checks = Dictionary(uniqueKeysWithValues: run.findings.map { ($0.checkID, Entry(status: $0.status.rawValue, severity: $0.severity.label, title: $0.title)) })
    }
}

public struct PostureChange: Sendable, Equatable, Identifiable {
    public var id: String { checkID }
    public let checkID: String
    public let title: String
    public let from: String
    public let to: String
    public var isRegression: Bool {
        (to == FindingStatus.issue.rawValue || to == FindingStatus.unresolved.rawValue) && from != to
    }

    /// Only a move to PASS is an improvement; changes to/from COULD NOT RUN or OBSERVED are neutral.
    public var isImprovement: Bool {
        (to == FindingStatus.pass.rawValue || to == FindingStatus.remediated.rawValue)
            && (from == FindingStatus.issue.rawValue || from == FindingStatus.unresolved.rawValue)
    }

    /// "▼" regression, "▲" improvement, "•" neutral.
    public var marker: String { isRegression ? "▼" : (isImprovement ? "▲" : "•") }
}

public actor AuditHistoryStore {
    private let url: URL?
    private var cache: [AuditSummary]?
    public static let maxEntries = 30

    public init(url: URL? = AuditHistoryStore.defaultURL()) { self.url = url }

    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HackCode", isDirectory: true).appendingPathComponent("audit-history.json")
    }

    public func all() -> [AuditSummary] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([AuditSummary].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    /// Records a summary and returns the changes relative to the previous run.
    @discardableResult
    public func record(_ summary: AuditSummary) -> [PostureChange] {
        var list = all()
        let previous = list.last
        list.append(summary)
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        cache = list
        if let url {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? encoder.encode(list) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        return previous.map { Self.diff(from: $0, to: summary) } ?? []
    }

    public func clear() {
        cache = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    public static func diff(from old: AuditSummary, to new: AuditSummary) -> [PostureChange] {
        new.checks.compactMap { id, entry in
            guard let before = old.checks[id] else { return nil }
            // Treat REMEDIATED as PASS for drift purposes.
            let a = before.status == "REMEDIATED" ? "PASS" : before.status
            let b = entry.status == "REMEDIATED" ? "PASS" : entry.status
            return a == b ? nil : PostureChange(checkID: id, title: entry.title, from: a, to: b)
        }.sorted { ($0.isRegression ? 0 : 1, $0.title) < ($1.isRegression ? 0 : 1, $1.title) }
    }
}
