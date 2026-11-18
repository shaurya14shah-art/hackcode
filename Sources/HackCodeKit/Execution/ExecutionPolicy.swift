import Foundation

/// Converts untrusted `OperationRequest`s into `ValidatedOperation`s. This is the only place where
/// risk and confirmation requirements are decided.
public struct ExecutionPolicy: Sendable {
    public let registry: OperationRegistry
    public let paths: PathPolicy
    public let context: OperationContext
    public static let maxStringArgumentLength = 1024

    public init(registry: OperationRegistry, paths: PathPolicy, context: OperationContext? = nil) {
        self.registry = registry
        self.paths = paths
        let base = context ?? OperationContext()
        self.context = OperationContext(currentUID: base.currentUID, ownPID: base.ownPID, homeDirectory: base.homeDirectory,
                                        excludedPrefixes: base.excludedPrefixes + paths.deniedPrefixes)
    }

    public func validate(_ request: OperationRequest) throws -> ValidatedOperation {
        guard let spec = registry.spec(for: request.operationID) else {
            throw HackCodeError.unknownOperation(Redactor.sanitizeForPrompt(request.operationID, maxCharacters: 80))
        }
        let arguments = try validateArguments(request.arguments, for: spec)
        var risk = RiskAssessment(spec.baseRisk, [Self.baseReason(spec)])
        if let evaluator = spec.riskEvaluator {
            let assessed = evaluator(arguments, context)
            if assessed.tier >= risk.tier { risk = RiskAssessment(assessed.tier, risk.reasons + assessed.reasons) }
        }
        if spec.isPrivileged {
            risk = RiskAssessment(.critical, risk.reasons + ["Runs with administrator privileges after macOS asks for your password."])
        } else if risk.tier == .critical {
            // Critical without a dedicated scoped flow is denied outright.
            throw HackCodeError.operationDenied(operation: spec.title, reason: risk.reasons.dropFirst().joined(separator: " "))
        }
        let display = try displayCommand(spec: spec, arguments: arguments)
        return ValidatedOperation(spec: spec, arguments: arguments, risk: risk,
                                  requiresConfirmation: risk.tier >= .elevated,
                                  displayCommand: display, provenance: request.provenance,
                                  claimedRisk: request.claimedRisk, rationale: request.rationale)
    }

    /// Re-checks a previously validated operation immediately before execution (paths may have changed).
    public func revalidate(_ operation: ValidatedOperation) throws {
        let declared = Set(operation.spec.parameters.map(\.name))
        let raw = operation.arguments.values.filter { declared.contains($0.key) }
        let fresh = try validateArguments(raw, for: operation.spec)
        guard fresh == operation.arguments else {
            let pidChanged = operation.spec.parameters.contains { if case .processID = $0.kind { return true }; return false }
            throw HackCodeError.operationDenied(operation: operation.spec.title,
                                                reason: pidChanged ? "the target process changed since it was approved (it exited or its pid was reused)"
                                                    : "a path now resolves to a different location than when it was approved")
        }
        if let evaluator = operation.spec.riskEvaluator {
            let now = evaluator(fresh, context)
            if now.tier > operation.risk.tier || (now.tier == .critical && !operation.spec.isPrivileged) {
                throw HackCodeError.operationDenied(operation: operation.spec.title,
                                                    reason: "its risk increased since it was approved: " + now.reasons.joined(separator: " "))
            }
        }
    }

    func validateArguments(_ raw: [String: ArgumentValue], for spec: OperationSpec) throws -> ValidatedArguments {
        let known = Set(spec.parameters.map(\.name))
        if let unexpected = raw.keys.sorted().first(where: { !known.contains($0) }) {
            throw HackCodeError.invalidArgument(operation: spec.id, argument: unexpected, reason: "this operation does not accept it")
        }
        var out: [String: ArgumentValue] = [:]
        for param in spec.parameters {
            guard let value = raw[param.name] ?? param.defaultValue else {
                if param.isRequired {
                    throw HackCodeError.invalidArgument(operation: spec.id, argument: param.name, reason: "it is required")
                }
                continue
            }
            out[param.name] = try validate(value, param: param, operation: spec.id)
            if case .processID = param.kind, case .integer(let pid)? = out[param.name] {
                guard let start = ProcessSampler.startTime(of: pid_t(pid)) else {
                    throw HackCodeError.invalidArgument(operation: spec.id, argument: param.name, reason: "no process with pid \(pid) is running")
                }
                out[param.name + ".start"] = .string(start)
            }
        }
        return ValidatedArguments(out)
    }

    private func validate(_ value: ArgumentValue, param: ParameterSpec, operation: String) throws -> ArgumentValue {
        func fail(_ reason: String) -> HackCodeError {
            .invalidArgument(operation: operation, argument: param.name, reason: reason)
        }
        switch param.kind {
        case .integer(let range):
            guard case .integer(let i) = value else { throw fail("expected an integer") }
            guard range.contains(i) else { throw fail("must be between \(range.lowerBound) and \(range.upperBound)") }
            return value
        case .readablePath, .trashablePath:
            guard case .string(let s) = value else { throw fail("expected a path string") }
            let resolved = try { () throws -> String in
                if case .readablePath = param.kind { return try paths.resolveReadable(s) }
                return try paths.resolveTrashable(s)
            }()
            return .string(resolved)
        case .token(let pattern, let maxLength):
            guard case .string(let s) = value else { throw fail("expected a string") }
            guard s.count <= maxLength else { throw fail("is longer than \(maxLength) characters") }
            guard s.range(of: pattern, options: .regularExpression) != nil else { throw fail("contains characters that are not allowed") }
            return value
        case .processID:
            guard case .integer(let i) = value else { throw fail("expected an integer pid") }
            guard (1...9_999_999).contains(i) else { throw fail("is not a valid pid") }
            return value
        case .host:
            guard case .string(let s) = value else { throw fail("expected a hostname") }
            guard Self.isValidHost(s) else { throw fail("is not a valid hostname or IPv4 address") }
            return .string(s.lowercased())
        case .choice(let options):
            let s: String
            switch value {
            case .string(let v): s = v
            case .integer(let v): s = String(v)
            }
            guard options.contains(s) else { throw fail("must be one of \(options.joined(separator: ", "))") }
            return .string(s)
        }
    }

    static func isValidHost(_ s: String) -> Bool {
        guard s.count <= 253, !s.hasPrefix("-"), !s.hasSuffix(".") else { return false }
        let label = "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
        return s.range(of: "^\(label)(\\.\(label))*$", options: .regularExpression) != nil
    }

    private func displayCommand(spec: OperationSpec, arguments: ValidatedArguments) throws -> String {
        switch spec.action {
        case .process(let executable, _, let build):
            return ArgvFormatter.display([executable] + (try build(arguments, context)))
        case .native:
            let args = arguments.values.filter { !$0.key.hasSuffix(".start") }.sorted { $0.key < $1.key }.map { "\($0.key)=\(ArgvFormatter.quote($0.value.description))" }
            return "[native] \(spec.id)" + (args.isEmpty ? "" : " " + args.joined(separator: " "))
        case .privilegedFixedCommand(let command):
            return "[administrator] \(command)"
        }
    }

    private static func baseReason(_ spec: OperationSpec) -> String {
        if spec.isReadOnly { return "Read-only (\(spec.sideEffects))." }
        return "Modifies state: \(spec.sideEffects)" + (spec.isReversible ? " (reversible)." : " (not reversible).")
    }
}
