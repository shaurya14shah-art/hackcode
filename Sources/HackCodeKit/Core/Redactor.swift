import Foundation

/// Removes secrets and reduces personally identifying detail before text is logged or sent to the model.
public struct Redactor: Sendable {
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // PEM private keys
            ("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)", "[REDACTED PRIVATE KEY]"),
            // Provider-style tokens
            ("nvapi-[A-Za-z0-9_\\-]{10,}", "[REDACTED NVIDIA KEY]"),
            ("sk-(ant-|proj-)?[A-Za-z0-9_\\-]{16,}", "[REDACTED API KEY]"),
            ("gh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED GITHUB TOKEN]"),
            ("xox[abprs]-[A-Za-z0-9\\-]{10,}", "[REDACTED SLACK TOKEN]"),
            ("AKIA[0-9A-Z]{16}", "[REDACTED AWS KEY]"),
            ("AIza[0-9A-Za-z_\\-]{30,}", "[REDACTED GOOGLE KEY]"),
            ("eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}", "[REDACTED JWT]"),
            // Authorization headers
            ("(?i)(bearer|basic)\\s+[A-Za-z0-9._~+/=\\-]{12,}", "$1 [REDACTED]"),
            // key=value / key: value secrets
            ("(?i)\\b([A-Za-z0-9_]*(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_]*)\\s*([=:])\\s*(\"[^\"]*\"|'[^']*'|[^\\s,;]+)", "$1$3[REDACTED]"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// Redacts secrets. When `abbreviateHome` is set, the user's home path is replaced with `~`.
    public func redact(_ text: String, abbreviateHome: Bool = true) -> String {
        var output = text
        for (regex, template) in Self.patterns {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: template)
        }
        if abbreviateHome, homeDirectory.count > 1 {
            output = output.replacingOccurrences(of: homeDirectory, with: "~")
        }
        return output
    }

    /// Removes control characters (except newline/tab) and bounds length, for untrusted text placed in prompts.
    public static func sanitizeForPrompt(_ text: String, maxCharacters: Int) -> String {
        let scalars = text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
        var cleaned = String(String.UnicodeScalarView(scalars))
        if cleaned.count > maxCharacters {
            cleaned = String(cleaned.prefix(maxCharacters)) + "\n[TRUNCATED \(cleaned.count - maxCharacters) characters]"
        }
        return cleaned
    }
}

/// Decodes a NUL-terminated C character buffer.
func stringFromCBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}
