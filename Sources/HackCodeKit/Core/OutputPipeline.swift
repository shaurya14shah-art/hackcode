import Foundation

/// Shell-style `| grep …` stages applied locally to captured output. Nothing is executed: each stage is a pure
/// text transformation implemented here, so pipes can never reach a shell or another program.
public struct OutputPipeline: Sendable, Equatable, CustomStringConvertible {
    public enum Stage: Sendable, Equatable {
        case grep(pattern: String, invert: Bool, caseInsensitive: Bool)
        case head(Int)
        case tail(Int)
        case sort(reverse: Bool, numeric: Bool)
        case uniq
        case countLines
    }

    public let stages: [Stage]
    public static let maxStages = 8
    public static let supported = "grep [-i] [-v] <text>, head [-n] N, tail [-n] N, sort [-r] [-n], uniq, wc -l"

    public enum ParseError: Error, Equatable, LocalizedError {
        case unknownStage(String), missingArgument(String), badNumber(String), tooManyStages
        public var errorDescription: String? {
            switch self {
            case .unknownStage(let s): return "'\(s)' is not a supported pipe filter. Supported: \(OutputPipeline.supported)."
            case .missingArgument(let s): return "\(s) needs an argument."
            case .badNumber(let s): return "'\(s)' is not a valid line count (1–100000)."
            case .tooManyStages: return "At most \(OutputPipeline.maxStages) pipe stages."
            }
        }
    }

    /// Splits "cmd args | grep x | head 5" on unquoted pipes. Returns the command part and the raw stage strings.
    public static func split(_ line: String) -> (command: String, stages: [String]) {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            if ch == "|" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        return (trimmed.first ?? "", Array(trimmed.dropFirst()))
    }

    public static func parse(_ rawStages: [String]) throws -> OutputPipeline {
        guard rawStages.count <= maxStages else { throw ParseError.tooManyStages }
        var stages: [Stage] = []
        for raw in rawStages {
            let words = tokenize(raw)
            guard let name = words.first else { throw ParseError.unknownStage("(empty)") }
            var args = Array(words.dropFirst())
            switch name {
            case "grep":
                var invert = false, insensitive = false
                while let flag = args.first, flag.hasPrefix("-"), flag.count > 1 {
                    for c in flag.dropFirst() {
                        switch c {
                        case "v": invert = true
                        case "i": insensitive = true
                        default: throw ParseError.unknownStage("grep -\(c)")
                        }
                    }
                    args.removeFirst()
                }
                guard !args.isEmpty else { throw ParseError.missingArgument("grep") }
                stages.append(.grep(pattern: args.joined(separator: " "), invert: invert, caseInsensitive: insensitive))
            case "head", "tail":
                if args.first == "-n" { args.removeFirst() }
                var countText = args.first ?? "10"
                if countText.hasPrefix("-") { countText.removeFirst() }      // head -5
                guard let n = Int(countText), (1...100_000).contains(n) else { throw ParseError.badNumber(countText) }
                stages.append(name == "head" ? .head(n) : .tail(n))
            case "sort":
                var reverse = false, numeric = false
                for flag in args {
                    guard flag.hasPrefix("-") else { throw ParseError.unknownStage("sort \(flag)") }
                    for c in flag.dropFirst() {
                        switch c {
                        case "r": reverse = true
                        case "n": numeric = true
                        default: throw ParseError.unknownStage("sort -\(c)")
                        }
                    }
                }
                stages.append(.sort(reverse: reverse, numeric: numeric))
            case "uniq":
                stages.append(.uniq)
            case "wc":
                guard args == ["-l"] else { throw ParseError.unknownStage("wc " + args.joined(separator: " ")) }
                stages.append(.countLines)
            default:
                throw ParseError.unknownStage(name)
            }
        }
        return OutputPipeline(stages: stages)
    }

    public func apply(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        for stage in stages {
            switch stage {
            case .grep(let pattern, let invert, let ci):
                lines = lines.filter { line in
                    let hit = ci ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
                    return hit != invert
                }
            case .head(let n): lines = Array(lines.prefix(n))
            case .tail(let n): lines = Array(lines.suffix(n))
            case .sort(let reverse, let numeric):
                if numeric {
                    // Like sort(1) -n: lines without a leading number compare as 0.
                    lines.sort { (Self.leadingNumber($0) ?? 0) < (Self.leadingNumber($1) ?? 0) }
                } else {
                    lines.sort()
                }
                if reverse { lines.reverse() }
            case .uniq:
                var out: [String] = []
                for line in lines where out.last != line { out.append(line) }
                lines = out
            case .countLines:
                lines = [String(lines.count)]
            }
        }
        return lines.joined(separator: "\n")
    }

    public var description: String {
        stages.map { stage -> String in
            switch stage {
            case .grep(let p, let v, let i): return "grep\(i ? " -i" : "")\(v ? " -v" : "") \(p.contains(" ") ? "\"\(p)\"" : p)"
            case .head(let n): return "head \(n)"
            case .tail(let n): return "tail \(n)"
            case .sort(let r, let n): return "sort" + (r || n ? " -" + (r ? "r" : "") + (n ? "n" : "") : "")
            case .uniq: return "uniq"
            case .countLines: return "wc -l"
            }
        }.map { "| \($0)" }.joined(separator: " ")
    }

    static func leadingNumber(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(number)
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
