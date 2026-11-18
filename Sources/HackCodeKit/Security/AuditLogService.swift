import Foundation

public struct AuditEvent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case aiRequestStarted, aiRequestFinished
        case proposalValidated, proposalRejected
        case approvalRequested, approvalGranted, approvalDenied
        case executionStarted, executionFinished, executionRejected
        case auditCheckCompleted, remediationVerified, remediationUnresolved, postureChanged, monitorAlert
        case settingsChanged, historyCleared
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let operation: String?
    public let risk: String?
    public let provenance: String?
    public let outcome: String
    public let detail: String

    public init(kind: Kind, operation: String? = nil, risk: RiskTier? = nil, provenance: Provenance? = nil,
                outcome: String, detail: String = "", timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.operation = operation
        self.risk = risk?.label
        self.provenance = provenance?.rawValue
        self.outcome = outcome
        self.detail = detail
    }
}

public protocol AuditLogging: Sendable {
    func record(_ event: AuditEvent) async
    func recent(limit: Int) async -> [AuditEvent]
    func history(limit: Int) async -> [AuditEvent]
    func clear() async
}

/// Append-only JSON-lines audit log with redaction, bounded detail and size-based rotation.
/// It records metadata about actions (what was proposed, approved, run and the outcome) — not full command output.
public actor AuditLogService: AuditLogging {
    public static let maxDetailCharacters = 400
    private let fileURL: URL?
    private let maxFileBytes: Int
    private let redactor = Redactor()
    private var memory: [AuditEvent] = []
    private let memoryLimit = 500
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Pass `nil` for an in-memory log (tests).
    public init(fileURL: URL? = AuditLogService.defaultURL(), maxFileBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxFileBytes = maxFileBytes
    }

    public static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("HackCode", isDirectory: true).appendingPathComponent("audit-log.jsonl")
    }

    public func record(_ event: AuditEvent) {
        let detail = Redactor.sanitizeForPrompt(redactor.redact(event.detail), maxCharacters: Self.maxDetailCharacters)
        let clean = AuditEvent(sanitizing: event, detail: detail)
        memory.append(clean)
        if memory.count > memoryLimit { memory.removeFirst(memory.count - memoryLimit) }
        guard let fileURL, var line = try? encoder.encode(clean) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int), size > maxFileBytes {
                let rotated = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: rotated)
                try fm.moveItem(at: fileURL, to: rotated)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Logging must never break the operation being logged; the in-memory copy remains.
        }
    }

    public func recent(limit: Int = 200) -> [AuditEvent] {
        Array(memory.suffix(limit))
    }

    /// Events persisted on disk across sessions (rotated file first, then the current one), newest last.
    /// Unreadable lines are skipped; falls back to this session's events when there is no file.
    public func history(limit: Int = 5000) -> [AuditEvent] {
        guard let fileURL else { return recent(limit: limit) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [AuditEvent] = []
        for url in [fileURL.appendingPathExtension("1"), fileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let e = try? decoder.decode(AuditEvent.self, from: Data(line)) { out.append(e) }
            }
        }
        if out.isEmpty { return recent(limit: limit) }
        return Array(out.suffix(limit))
    }

    public func clear() {
        memory.removeAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("1"))
    }
}

extension AuditEvent {
    init(sanitizing e: AuditEvent, detail: String) {
        self.id = e.id
        self.timestamp = e.timestamp
        self.kind = e.kind
        self.operation = e.operation
        self.risk = e.risk
        self.provenance = e.provenance
        self.outcome = e.outcome
        self.detail = detail
    }
}
