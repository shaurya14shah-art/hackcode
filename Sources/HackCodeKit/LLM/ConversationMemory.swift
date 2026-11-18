import Foundation

/// Bounded conversation context. Older turns are folded into a short local summary instead of growing forever.
public struct ConversationMemory: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public let role: String   // "user" or "assistant"
        public let content: String
    }

    public private(set) var turns: [Turn] = []
    public private(set) var summary: [String] = []
    public var maxTurns: Int
    public static let maxSummaryLines = 12
    public static let maxTurnCharacters = 2000

    public init(maxTurns: Int = 12) { self.maxTurns = max(2, maxTurns) }

    public mutating func append(role: String, content: String) {
        turns.append(Turn(role: role, content: Redactor.sanitizeForPrompt(content, maxCharacters: Self.maxTurnCharacters)))
        while turns.count > maxTurns {
            let old = turns.removeFirst()
            if old.role == "user" {
                summary.append("Earlier the user asked: " + String(old.content.prefix(160)))
            } else {
                summary.append("Earlier HackCode responded: " + String(old.content.prefix(160)))
            }
            if summary.count > Self.maxSummaryLines { summary.removeFirst(summary.count - Self.maxSummaryLines) }
        }
    }

    public mutating func clear() {
        turns.removeAll()
        summary.removeAll()
    }

    public var summaryText: String? {
        summary.isEmpty ? nil : "Summary of earlier conversation (older turns were dropped):\n" + summary.joined(separator: "\n")
    }
}
