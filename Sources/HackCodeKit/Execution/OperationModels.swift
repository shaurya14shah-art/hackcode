import Foundation

/// Risk tiers are assigned locally from the operation and its arguments — never from the model's label.
public enum RiskTier: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Passive inspection.
    case informational = 0
    /// Bounded, reversible local actions.
    case low = 1
    /// Modifications that require explicit confirmation.
    case elevated = 2
    /// Destructive, privileged or irreversible. Denied unless the operation defines a scoped privileged flow.
    case critical = 3

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .informational: return "INFO"
        case .low: return "LOW"
        case .elevated: return "ELEVATED"
        case .critical: return "CRITICAL"
        }
    }
}

/// A single typed argument value. Only integers and strings are accepted from the model.
public enum ArgumentValue: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // JSONDecoder will not decode booleans, arrays or objects as Int/Double/String, so those are rejected.
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) {
            guard d.rounded() == d, abs(d) < 1e9 else {
                throw DecodingError.typeMismatch(ArgumentValue.self, .init(codingPath: decoder.codingPath, debugDescription: "non-integer number"))
            }
            self = .integer(Int(d)); return
        }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(ArgumentValue.self, .init(codingPath: decoder.codingPath, debugDescription: "expected integer or string"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .integer(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .integer(let i): return String(i)
        case .string(let s): return s
        }
    }
}

public enum ParameterKind: Sendable {
    case integer(ClosedRange<Int>)
    /// A path the user may read (validated against `PathPolicy.readRoots`, symlinks resolved).
    case readablePath
    /// A path that may be moved to the Trash (validated against `PathPolicy.writeRoots`).
    case trashablePath
    /// A token constrained by an anchored regular expression.
    case token(pattern: String, maxLength: Int)
    case choice([String])
    /// A running process. Validation pins the process's start time so a reused pid is detected at execution.
    case processID
    /// A DNS hostname or IPv4 address (never starts with '-', so it cannot be read as an option).
    case host

    public var schemaDescription: String {
        switch self {
        case .integer(let r): return "integer \(r.lowerBound)...\(r.upperBound)"
        case .readablePath: return "absolute path or ~/path inside the user's home, /Applications or /Volumes"
        case .trashablePath: return "path inside ~/Downloads, ~/Desktop, ~/Documents, ~/Movies, ~/Music, ~/Pictures or ~/Library/Caches"
        case .token(let p, let max): return "string matching \(p) (max \(max) chars)"
        case .choice(let options): return "one of: " + options.joined(separator: ", ")
        case .processID: return "pid of a running process (integer)"
        case .host: return "hostname or IPv4 address, e.g. apple.com"
        }
    }
}

public struct ParameterSpec: Sendable {
    public let name: String
    public let kind: ParameterKind
    public let isRequired: Bool
    public let defaultValue: ArgumentValue?
    public let help: String

    public init(_ name: String, _ kind: ParameterKind, required: Bool = false, default defaultValue: ArgumentValue? = nil, help: String) {
        self.name = name
        self.kind = kind
        self.isRequired = required
        self.defaultValue = defaultValue
        self.help = help
    }
}

/// OS-enforced restriction applied to child processes via the Seatbelt `sandbox-exec` profile.
public enum SandboxProfile: Sendable, Equatable {
    /// Denies all file writes (except /dev/null) and all network access.
    case readOnlyNoNetwork
    /// Denies file writes; network allowed (for tools that must contact Apple services).
    case readOnlyWithNetwork
    /// Runs unsandboxed. The reason is shown to the user.
    case none(reason: String)

    public var isSandboxed: Bool {
        if case .none = self { return false }
        return true
    }

    public var displayLabel: String {
        switch self {
        case .readOnlyNoNetwork: return "SANDBOX: read-only, no network"
        case .readOnlyWithNetwork: return "SANDBOX: read-only, network allowed"
        case .none(let reason): return "UNSANDBOXED: \(reason)"
        }
    }

    /// Seatbelt profile text. Built from constants only.
    var profileText: String? {
        switch self {
        case .readOnlyNoNetwork:
            return "(version 1)(allow default)(deny file-write*)(allow file-write-data (literal \"/dev/null\"))(deny network*)(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))"
        case .readOnlyWithNetwork:
            return "(version 1)(allow default)(deny file-write*)(allow file-write-data (literal \"/dev/null\"))"
        case .none:
            return nil
        }
    }
}

/// Validated arguments, keyed by parameter name. Paths are already resolved.
public struct ValidatedArguments: Sendable, Equatable {
    public let values: [String: ArgumentValue]
    public init(_ values: [String: ArgumentValue]) { self.values = values }

    public func int(_ name: String) -> Int? {
        if case .integer(let i)? = values[name] { return i }
        return nil
    }

    public func string(_ name: String) -> String? {
        if case .string(let s)? = values[name] { return s }
        return nil
    }

    /// Start time captured for a `.processID` parameter at validation time.
    public func pinnedStart(_ name: String) -> String? { string(name + ".start") }
}

/// Facts about the local environment used for validation and risk assessment.
public struct OperationContext: Sendable {
    public let currentUID: uid_t
    public let ownPID: pid_t
    public let homeDirectory: String
    /// Resolved locations that recursive operations must never descend into (credentials, private data).
    public let excludedPrefixes: [String]

    public init(currentUID: uid_t = getuid(), ownPID: pid_t = getpid(), homeDirectory: String = NSHomeDirectory(),
                excludedPrefixes: [String] = []) {
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.homeDirectory = homeDirectory
        self.excludedPrefixes = excludedPrefixes
    }
}

public struct RiskAssessment: Sendable, Equatable {
    public let tier: RiskTier
    public let reasons: [String]
    public init(_ tier: RiskTier, _ reasons: [String]) {
        self.tier = tier
        self.reasons = reasons
    }
}

/// Streams output to the UI while an operation runs.
public struct OutputSink: Sendable {
    public enum Stream: String, Sendable { case stdout, stderr, info }
    private let handler: @Sendable (Stream, String) -> Void
    public init(_ handler: @escaping @Sendable (Stream, String) -> Void) { self.handler = handler }
    public func emit(_ stream: Stream, _ text: String) { handler(stream, text) }
    public static let discard = OutputSink { _, _ in }
}

/// What an operation does when executed. There is no case that accepts free-form shell text.
public enum OperationAction: Sendable {
    /// Runs a fixed absolute executable with an argument array derived from validated arguments.
    case process(executable: String, sandbox: SandboxProfile,
                 arguments: @Sendable (ValidatedArguments, OperationContext) throws -> [String])
    /// Implemented natively with Foundation / Darwin APIs. Returns the textual result.
    case native(@Sendable (ValidatedArguments, OperationContext, OutputSink) async throws -> String)
    /// A fixed, parameterless privileged command run through the macOS administrator prompt.
    case privilegedFixedCommand(String)
}

public struct OperationSpec: Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let parameters: [ParameterSpec]
    public let baseRisk: RiskTier
    public let isReadOnly: Bool
    public let isReversible: Bool
    public let sideEffects: String
    public let requiredPermissions: [String]
    public let timeoutSeconds: TimeInterval
    public let maxOutputBytes: Int
    public let action: OperationAction
    /// Optional argument-dependent risk assessment. The result can only raise risk above `baseRisk`.
    public let riskEvaluator: (@Sendable (ValidatedArguments, OperationContext) -> RiskAssessment)?
    /// Applied to output before it is shown or stored (e.g. hides hardware serial numbers). Disables live streaming.
    public let outputFilter: (@Sendable (String) -> String)?

    public init(id: String, title: String, summary: String, parameters: [ParameterSpec] = [],
                baseRisk: RiskTier, isReadOnly: Bool, isReversible: Bool = true, sideEffects: String,
                requiredPermissions: [String] = [], timeoutSeconds: TimeInterval = 30, maxOutputBytes: Int = 256 * 1024,
                action: OperationAction,
                riskEvaluator: (@Sendable (ValidatedArguments, OperationContext) -> RiskAssessment)? = nil,
                outputFilter: (@Sendable (String) -> String)? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.parameters = parameters
        self.baseRisk = baseRisk
        self.isReadOnly = isReadOnly
        self.isReversible = isReversible
        self.sideEffects = sideEffects
        self.requiredPermissions = requiredPermissions
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
        self.action = action
        self.riskEvaluator = riskEvaluator
        self.outputFilter = outputFilter
    }

    public var isPrivileged: Bool {
        if case .privilegedFixedCommand = action { return true }
        return false
    }

    public var sandbox: SandboxProfile? {
        switch action {
        case .process(_, let sandbox, _): return sandbox
        case .native: return nil
        case .privilegedFixedCommand: return SandboxProfile.none(reason: "runs as administrator after macOS authentication")
        }
    }
}

public enum Provenance: String, Codable, Sendable {
    case model = "AI PROPOSAL"
    case user = "USER"
    case securityAudit = "SECURITY AUDIT"
}

/// An unvalidated request to run an operation, e.g. decoded from model output.
public struct OperationRequest: Sendable, Equatable {
    public let operationID: String
    public let arguments: [String: ArgumentValue]
    public let provenance: Provenance
    /// The model's own risk label — recorded for transparency, never trusted.
    public let claimedRisk: String?
    public let rationale: String?

    public init(operationID: String, arguments: [String: ArgumentValue] = [:], provenance: Provenance,
                claimedRisk: String? = nil, rationale: String? = nil) {
        self.operationID = operationID
        self.arguments = arguments
        self.provenance = provenance
        self.claimedRisk = claimedRisk
        self.rationale = rationale
    }
}

/// An operation that passed local validation. Only `ExecutionPolicy` creates these.
public struct ValidatedOperation: Sendable, Identifiable {
    public let id: UUID
    public let spec: OperationSpec
    public let arguments: ValidatedArguments
    public let risk: RiskAssessment
    public let requiresConfirmation: Bool
    /// Exactly what will run, for display. For process operations this is the real argv.
    public let displayCommand: String
    public let provenance: Provenance
    public let claimedRisk: String?
    public let rationale: String?
    public let createdAt: Date

    init(spec: OperationSpec, arguments: ValidatedArguments, risk: RiskAssessment, requiresConfirmation: Bool,
         displayCommand: String, provenance: Provenance, claimedRisk: String?, rationale: String?) {
        self.id = UUID()
        self.spec = spec
        self.arguments = arguments
        self.risk = risk
        self.requiresConfirmation = requiresConfirmation
        self.displayCommand = displayCommand
        self.provenance = provenance
        self.claimedRisk = claimedRisk
        self.rationale = rationale
        self.createdAt = Date()
    }
}

/// Proof that the user approved one specific validated operation.
/// Created only by `ApprovalGate.approve(_:)`, which the UI calls from an explicit user action.
public struct Approval: Sendable, Equatable {
    public let operationID: UUID
    public let approvedAt: Date
    init(operationID: UUID) {
        self.operationID = operationID
        self.approvedAt = Date()
    }
}

public enum ApprovalGate {
    /// Call only in response to an explicit user action (button press / confirmed dialog).
    public static func approve(_ operation: ValidatedOperation) -> Approval {
        Approval(operationID: operation.id)
    }
}

public enum ExecutionStatus: String, Sendable, Codable {
    case succeeded = "SUCCEEDED"
    case partial = "PARTIAL"
    case failed = "FAILED"
    case timedOut = "TIMED OUT"
    case cancelled = "CANCELLED"
    case rejected = "REJECTED"
}

public struct ExecutionRecord: Sendable, Identifiable {
    public let id: UUID
    public let operationID: String
    public let displayCommand: String
    public let status: ExecutionStatus
    public let exitCode: Int32?
    public let output: String
    public let errorOutput: String
    public let truncated: Bool
    public let sandboxed: Bool
    public let startedAt: Date
    public let duration: TimeInterval
    public let note: String?

    public init(id: UUID, operationID: String, displayCommand: String, status: ExecutionStatus, exitCode: Int32?,
                output: String, errorOutput: String, truncated: Bool, sandboxed: Bool, startedAt: Date,
                duration: TimeInterval, note: String? = nil) {
        self.id = id
        self.operationID = operationID
        self.displayCommand = displayCommand
        self.status = status
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
        self.truncated = truncated
        self.sandboxed = sandboxed
        self.startedAt = startedAt
        self.duration = duration
        self.note = note
    }
}

/// Quotes an argv for display only. HackCode never passes this string to a shell.
public enum ArgvFormatter {
    public static func display(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    static func quote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
