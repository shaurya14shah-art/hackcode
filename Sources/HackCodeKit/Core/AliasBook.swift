import Foundation

/// User-defined command aliases ("/cpu" → "/process.top_cpu limit=5"). Expansion is single-level: the expanded
/// text is submitted exactly as if typed, so it passes through the normal validation and approval flow.
public enum AliasBook {
    public static let maxAliases = 50
    public static let namePattern = "^[a-z][a-z0-9_-]{0,23}$"

    public enum AliasError: Error, Equatable, LocalizedError {
        case invalidName, reservedName(String), emptyExpansion, tooMany, selfReference

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Alias names use lowercase letters, digits, - or _ (max 24, starting with a letter)."
            case .reservedName(let n): return "/\(n) is a built-in command or operation; choose another name."
            case .emptyExpansion: return "An alias needs a command to expand to."
            case .tooMany: return "At most \(maxAliases) aliases."
            case .selfReference: return "An alias cannot expand to itself."
            }
        }
    }

    public static func validate(name: String, expansion: String, reserved: Set<String>, existing: [String: String]) throws {
        guard name.range(of: namePattern, options: .regularExpression) != nil else { throw AliasError.invalidName }
        guard !reserved.contains(name) else { throw AliasError.reservedName(name) }
        let trimmed = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AliasError.emptyExpansion }
        if trimmed == "/\(name)" || trimmed.hasPrefix("/\(name) ") { throw AliasError.selfReference }
        if existing[name] == nil && existing.count >= maxAliases { throw AliasError.tooMany }
    }

    /// Expands "/name rest…" when `name` is an alias; returns nil otherwise. Never expands the result again.
    public static func expand(_ line: String, aliases: [String: String]) -> String? {
        guard line.hasPrefix("/") else { return nil }
        let body = line.dropFirst()
        let name = String(body.prefix { $0 != " " })
        guard let expansion = aliases[name] else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? expansion : expansion + " " + rest
    }
}
