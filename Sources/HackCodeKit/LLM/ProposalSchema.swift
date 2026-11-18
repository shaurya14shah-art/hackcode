import Foundation

/// Version 1 of the structured response HackCode requires from the model.
///
/// ```json
/// {
///   "schema_version": 1,
///   "intent": "what the user wants",
///   "approach": "short explanation of the plan",
///   "operations": [
///     {"id": "process.top_cpu", "arguments": {"limit": 10},
///      "purpose": "why this step", "expected_output": "what it will show", "risk": "INFO"}
///   ],
///   "requires_confirmation": false,
///   "limitations": ["…"],
///   "answer": "direct answer when no operation is needed"
/// }
/// ```
public struct ModelProposal: Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maxOperations = 3

    public let schemaVersion: Int
    public let intent: String
    public let approach: String
    public let operations: [ProposedOperation]
    /// The model's own opinion; HackCode decides confirmation locally and can only make it stricter.
    public let claimsConfirmationRequired: Bool
    public let limitations: [String]
    public let answer: String?
}

public struct ProposedOperation: Sendable, Equatable {
    public let id: String
    public let arguments: [String: ArgumentValue]
    public let purpose: String
    public let expectedOutput: String
    public let claimedRisk: String?
}

public enum ProposalDecoder {
    private struct Wire: Decodable {
        let schema_version: Int?
        let intent: String?
        let approach: String?
        let operations: [WireOp]?
        let requires_confirmation: Bool?
        let limitations: [String]?
        let answer: String?
    }

    private struct WireOp: Decodable {
        let id: String
        let arguments: [String: ArgumentValue]?
        let purpose: String?
        let expected_output: String?
        let risk: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case id, arguments, purpose, expected_output, risk }

        init(from decoder: Decoder) throws {
            // Reject unknown keys inside an operation: an unexpected field means the output is ambiguous.
            let any = try decoder.container(keyedBy: AnyKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            if let extra = any.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
                throw HackCodeError.malformedModelOutput("operation has unsupported field '\(extra.stringValue)'")
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            arguments = try c.decodeIfPresent([String: ArgumentValue].self, forKey: .arguments)
            purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
            expected_output = try c.decodeIfPresent(String.self, forKey: .expected_output)
            risk = try c.decodeIfPresent(String.self, forKey: .risk)
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Extracts exactly one JSON object from the model text. Code fences and surrounding whitespace are allowed;
    /// other prose around the object is rejected as ambiguous.
    public static func extractJSONObject(_ text: String) throws -> Data {
        var body = text
        if let thinkEnd = body.range(of: "</think>") { body = String(body[thinkEnd.upperBound...]) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.drop { $0 != "\n" }.dropFirst())
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.hasPrefix("{"), body.hasSuffix("}") else {
            throw HackCodeError.malformedModelOutput("the response is not a single JSON object")
        }
        guard let data = body.data(using: .utf8) else { throw HackCodeError.malformedModelOutput("not UTF-8") }
        return data
    }

    public static func decode(_ text: String) throws -> ModelProposal {
        let data = try extractJSONObject(text)
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch let e as HackCodeError {
            throw e
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            throw HackCodeError.malformedModelOutput("wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, _) {
            throw HackCodeError.malformedModelOutput("missing field '\(key.stringValue)'")
        } catch {
            throw HackCodeError.malformedModelOutput("invalid JSON")
        }
        guard let version = wire.schema_version else { throw HackCodeError.malformedModelOutput("missing schema_version") }
        guard version == ModelProposal.currentSchemaVersion else { throw HackCodeError.unsupportedSchemaVersion(version) }
        let intent = (wire.intent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { throw HackCodeError.malformedModelOutput("missing intent") }
        let ops = wire.operations ?? []
        guard ops.count <= ModelProposal.maxOperations else {
            throw HackCodeError.malformedModelOutput("more than \(ModelProposal.maxOperations) operations proposed")
        }
        let answer = wire.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        if ops.isEmpty && (answer ?? "").isEmpty && (wire.approach ?? "").isEmpty {
            throw HackCodeError.malformedModelOutput("no operations and no answer")
        }
        func clip(_ s: String?, _ n: Int) -> String { Redactor.sanitizeForPrompt(s ?? "", maxCharacters: n) }
        return ModelProposal(
            schemaVersion: version, intent: clip(intent, 300), approach: clip(wire.approach, 1500),
            operations: ops.map { ProposedOperation(id: clip($0.id, 80), arguments: $0.arguments ?? [:],
                                                    purpose: clip($0.purpose, 400), expectedOutput: clip($0.expected_output, 400),
                                                    claimedRisk: $0.risk.map { clip($0, 20) }) },
            claimsConfirmationRequired: wire.requires_confirmation ?? false,
            limitations: (wire.limitations ?? []).prefix(6).map { clip($0, 300) },
            answer: answer.flatMap { $0.isEmpty ? nil : clip($0, 3000) })
    }
}

/// Result of checking every proposed operation against the local policy.
public struct ValidatedProposal: Sendable {
    public let proposal: ModelProposal
    public let operations: [ValidatedOperation]
    public let rejections: [Rejection]

    public struct Rejection: Sendable {
        public let proposed: ProposedOperation
        public let reason: String
    }

    public static func validate(_ proposal: ModelProposal, policy: ExecutionPolicy) -> ValidatedProposal {
        var ok: [ValidatedOperation] = []
        var rejected: [Rejection] = []
        for op in proposal.operations {
            let request = OperationRequest(operationID: op.id, arguments: op.arguments, provenance: .model,
                                           claimedRisk: op.claimedRisk, rationale: op.purpose)
            do {
                ok.append(try policy.validate(request))
            } catch {
                rejected.append(Rejection(proposed: op, reason: error.localizedDescription))
            }
        }
        return ValidatedProposal(proposal: proposal, operations: ok, rejections: rejected)
    }
}
