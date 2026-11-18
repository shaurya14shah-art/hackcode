import Foundation

/// Search/filter/export for the audit log viewer. Pure functions so the UI stays thin and the rules are tested.
public struct AuditLogFilter: Sendable, Equatable {
    public enum Category: String, CaseIterable, Sendable {
        case all = "ALL", ai = "AI", approvals = "APPROVALS", execution = "EXECUTION", audit = "AUDIT", monitor = "MONITOR", settings = "SETTINGS"

        public func contains(_ kind: AuditEvent.Kind) -> Bool {
            switch self {
            case .all: return true
            case .ai: return [.aiRequestStarted, .aiRequestFinished, .proposalValidated, .proposalRejected].contains(kind)
            case .approvals: return [.approvalRequested, .approvalGranted, .approvalDenied].contains(kind)
            case .execution: return [.executionStarted, .executionFinished, .executionRejected].contains(kind)
            case .audit: return [.auditCheckCompleted, .remediationVerified, .remediationUnresolved, .postureChanged].contains(kind)
            case .monitor: return kind == .monitorAlert
            case .settings: return [.settingsChanged, .historyCleared].contains(kind)
            }
        }
    }

    public enum Window: String, CaseIterable, Sendable {
        case hour = "1H", day = "24H", week = "7D", all = "ALL TIME"

        public var seconds: TimeInterval? {
            switch self {
            case .hour: return 3600
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .all: return nil
            }
        }
    }

    public var category: Category
    public var window: Window
    /// Space-separated terms; every term must appear (case-insensitive) in kind, operation, risk, provenance, outcome or detail.
    /// A leading "-" excludes a term (e.g. `-monitor`).
    public var query: String

    public init(category: Category = .all, window: Window = .all, query: String = "") {
        self.category = category
        self.window = window
        self.query = query
    }

    public var isActive: Bool { category != .all || window != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ e: AuditEvent, now: Date = Date()) -> Bool {
        guard category.contains(e.kind) else { return false }
        if let s = window.seconds, now.timeIntervalSince(e.timestamp) > s { return false }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = Self.haystack(e)
        for t in terms {
            if t.hasPrefix("-") {
                let term = t.dropFirst()
                if !term.isEmpty, haystack.contains(term) { return false }
            } else if !haystack.contains(t) {
                return false
            }
        }
        return true
    }

    public func apply(_ events: [AuditEvent], now: Date = Date()) -> [AuditEvent] {
        events.filter { matches($0, now: now) }
    }

    /// Event counts per category (ignoring the category filter itself) for the filter chips.
    public func counts(_ events: [AuditEvent], now: Date = Date()) -> [Category: Int] {
        var other = self
        other.category = .all
        let pool = other.apply(events, now: now)
        var out: [Category: Int] = [:]
        for c in Category.allCases { out[c] = pool.filter { c.contains($0.kind) }.count }
        return out
    }

    static func haystack(_ e: AuditEvent) -> String {
        [e.kind.rawValue, e.operation ?? "", e.risk ?? "", e.provenance ?? "", e.outcome, e.detail].joined(separator: " ").lowercased()
    }

    // MARK: Export

    /// RFC 4180 CSV. Cells that a spreadsheet would treat as formulas are prefixed with `'` (CSV injection guard).
    public static func csv(_ events: [AuditEvent]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["timestamp,kind,operation,risk,provenance,outcome,detail"]
        for e in events {
            let cells = [iso.string(from: e.timestamp), e.kind.rawValue, e.operation ?? "", e.risk ?? "", e.provenance ?? "", e.outcome, e.detail]
            lines.append(cells.map(csvCell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvCell(_ raw: String) -> String {
        var s = raw
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
