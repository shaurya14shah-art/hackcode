import Foundation

public enum Severity: Int, Codable, Sendable, Comparable, CaseIterable {
    case info = 0, low, medium, high, critical
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .info: return "INFO"
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        case .critical: return "CRITICAL"
        }
    }
}

public enum Confidence: String, Codable, Sendable {
    case high = "HIGH", medium = "MEDIUM", low = "LOW"
}

public enum FindingStatus: String, Codable, Sendable {
    /// The check ran and the setting meets the baseline.
    case pass = "PASS"
    /// The check ran and found a weakness.
    case issue = "ISSUE"
    /// Informational inventory (no pass/fail judgement).
    case observed = "OBSERVED"
    /// The check could not collect reliable evidence (permission, missing tool, unrecognised output).
    case couldNotRun = "COULD NOT RUN"
    /// Re-check after remediation confirmed the fix.
    case remediated = "REMEDIATED"
    /// Re-check after remediation still shows the issue.
    case unresolved = "UNRESOLVED"
}

public struct EvidenceItem: Codable, Sendable, Equatable {
    /// Exact command (argv) or API used.
    public let source: String
    /// Redacted, bounded output.
    public let output: String
    public let exitCode: Int32?
    public let sandboxed: Bool

    public init(source: String, output: String, exitCode: Int32? = nil, sandboxed: Bool = false) {
        self.source = source
        self.output = output
        self.exitCode = exitCode
        self.sandboxed = sandboxed
    }
}

public struct Remediation: Codable, Sendable, Equatable {
    /// Human description of the corrective action.
    public let summary: String
    /// The exact intended change (command or setting), shown before authorization.
    public let exactChange: String
    /// Registered operation that applies the change, when HackCode can apply it.
    public let operationID: String?
    /// Manual steps when HackCode cannot (or should not) apply the change itself.
    public let manualSteps: [String]
    /// System Settings deep link, if any.
    public let settingsURL: String?
    public let reversible: Bool
    public let requiresConfirmation: Bool
}

public struct Finding: Identifiable, Codable, Sendable, Equatable {
    /// Stable identifier (the check id plus an optional item suffix).
    public let id: String
    public let checkID: String
    public let title: String
    public var severity: Severity
    public var confidence: Confidence
    public let component: String
    public var evidence: [EvidenceItem]
    public var collectedAt: Date
    public let whyItMatters: String
    public let limitations: [String]
    public let remediation: Remediation?
    public let verificationSteps: [String]
    public var status: FindingStatus
    public var statusNote: String?

    public var isActionable: Bool { status == .issue || status == .unresolved }
}

public struct AuditRun: Sendable, Identifiable {
    public let id = UUID()
    public let startedAt: Date
    public var finishedAt: Date?
    public var findings: [Finding]
    public var cancelled: Bool

    public init(startedAt: Date, finishedAt: Date? = nil, findings: [Finding], cancelled: Bool) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.findings = findings
        self.cancelled = cancelled
    }

    public var issues: [Finding] { findings.filter(\.isActionable) }
    public var failedChecks: [Finding] { findings.filter { $0.status == .couldNotRun } }

    /// Evidence-weighted posture score; checks that could not run are excluded rather than assumed to pass.
    public var score: Int? {
        let judged = findings.filter { [.pass, .issue, .remediated, .unresolved].contains($0.status) }
        guard !judged.isEmpty else { return nil }
        let penalty = judged.filter(\.isActionable).reduce(0) { total, f in
            total + [0, 4, 10, 20, 35][f.severity.rawValue]
        }
        return max(0, 100 - penalty)
    }
}
