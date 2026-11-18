import Foundation
import HackCodeKit

enum SlashCategory: String, CaseIterable, Identifiable {
    case all = "ALL", session = "SESSION", runbooks = "RUNBOOKS", system = "SYSTEM", processes = "PROCESSES"
    case files = "FILES", network = "NETWORK", security = "SECURITY", diagnostics = "DIAGNOSTICS", aliases = "ALIASES"
    var id: String { rawValue }
}

/// One entry in the `/` dropdown.
struct SlashCommand: Identifiable, Equatable {
    /// What is inserted / executed, e.g. "/help", "/runbook health", "/files.largest".
    let id: String
    let title: String
    let detail: String
    let category: SlashCategory
    /// Argument syntax shown in the dropdown and as a hint while typing, e.g. "path=<folder> limit? depth?".
    let syntax: String?
    let requiredArguments: [String]
    let risk: RiskTier?
    /// Short execution label: LOCAL, NATIVE, SANDBOXED, UNSANDBOXED, ADMIN.
    let mode: String
    /// Selecting inserts "<id> " for the user to complete instead of running it.
    var insertsOnly = false
}

enum SlashCommandCatalog {
    static let sessionCommands: [SlashCommand] = [
        session("/help", "Command reference", "Every local command, key binding and how approval works."),
        session("/clear", "Clear terminal", "Clears this session's transcript and AI conversation memory (⌘K)."),
        session("/ops", "List operations", "Table of every registered operation with its risk tier and parameters."),
        session("/runbooks", "List runbooks", "Curated read-only diagnostic sequences."),
        session("/runall", "Run all staged", "Runs every staged operation that needs no approval, in order."),
        SlashCommand(id: "/watch", title: "Watch an operation", detail: "Re-runs a read-only operation every N seconds and highlights what changed (like watch(1)). ⌃C stops.",
                     category: .session, syntax: "<operation> [key=value …] every=<2-300>", requiredArguments: [], risk: nil, mode: "LOCAL", insertsOnly: true),
        session("/explain", "Explain last result", "Sends the newest finished output (redacted, ≤ 6 KB) to the model for an explanation."),
        session("/cancel", "Cancel running", "Cancels the AI request or operation currently running (⌘.)."),
        session("/history", "Command history", "Shows recent commands; /history clear erases them (⌃R searches)."),
        SlashCommand(id: "/alias", title: "Define an alias", detail: "/alias dl /files.largest path=~/Downloads — then just type /dl. /alias alone lists them.",
                     category: .session, syntax: "<name> <command…>", requiredArguments: [], risk: nil, mode: "LOCAL", insertsOnly: true),
        SlashCommand(id: "/unalias", title: "Remove an alias", detail: "/unalias dl", category: .session, syntax: "<name>",
                     requiredArguments: [], risk: nil, mode: "LOCAL", insertsOnly: true),
        session("/export", "Export transcript", "Saves this session as Markdown, secrets redacted (⌘⇧E)."),
        session("/report", "System report", "Saves a Markdown health report (overview, load, memory, volumes, network, alerts, audit) from local data."),
        session("/keys", "Keyboard shortcuts", "Shows every shortcut (⌘/)."),
        session("/trends", "Long-term trends", "Disk free-space change and forecast, battery health/cycles and swap from hourly local samples."),
        session("/recap", "Since last session", "Re-shows what changed while HackCode was closed (disk, battery, crash reports, audit age)."),
        session("/audit", "Run security audit", "Runs all read-only security checks and opens SECURITY AUDIT (⌘⇧R)."),
        session("/monitor", "Open MONITOR", "Live CPU, memory, disk, network and processes (⌘2)."),
        session("/security", "Open SECURITY AUDIT", "Findings, evidence and remediation (⌘3)."),
        session("/storage", "Open STORAGE", "Disk usage explorer; optionally give a folder, e.g. /storage ~/Downloads (⌘4)."),
        session("/settings", "Open Settings", "API key, model, monitor, privacy and appearance (⌘,)."),
        SlashCommand(id: "/theme", title: "Terminal colour theme", detail: "green · amber · cyan · mono — recolours the interface and the rain.",
                     category: .session, syntax: "green|amber|cyan|mono", requiredArguments: [], risk: nil, mode: "LOCAL", insertsOnly: true),
    ]

    private static func session(_ id: String, _ title: String, _ detail: String) -> SlashCommand {
        SlashCommand(id: id, title: title, detail: detail, category: .session, syntax: nil, requiredArguments: [], risk: nil, mode: "LOCAL")
    }

    static func build(registry: OperationRegistry) -> [SlashCommand] {
        let runbooks = Runbook.all.map { book in
            SlashCommand(id: "/runbook \(book.id)", title: book.title, detail: book.summary, category: .runbooks,
                         syntax: nil, requiredArguments: [], risk: .informational, mode: "\(book.steps.count) STEPS")
        }
        let operations = registry.ordered.map { spec -> SlashCommand in
            let syntax = spec.parameters.isEmpty ? nil : spec.parameters.map { p in
                p.isRequired ? "\(p.name)=<\(placeholder(p))>" : "\(p.name)?"
            }.joined(separator: " ")
            let mode: String
            switch spec.action {
            case .native: mode = "NATIVE"
            case .privilegedFixedCommand: mode = "ADMIN"
            case .process(_, let sandbox, _): mode = sandbox.isSandboxed ? "SANDBOXED" : "UNSANDBOXED"
            }
            return SlashCommand(id: "/\(spec.id)", title: spec.title, detail: spec.summary, category: category(for: spec.id),
                                syntax: syntax, requiredArguments: spec.parameters.filter(\.isRequired).map(\.name),
                                risk: spec.baseRisk, mode: mode)
        }
        return sessionCommands + runbooks + operations
    }

    static func placeholder(_ p: ParameterSpec) -> String {
        switch p.kind {
        case .readablePath, .trashablePath: return "path"
        case .processID: return "pid"
        case .host: return "host"
        case .integer(let r): return "\(r.lowerBound)-\(r.upperBound)"
        case .choice(let options): return options.prefix(4).joined(separator: "|")
        case .token: return p.name
        }
    }

    static func category(for operationID: String) -> SlashCategory {
        let prefix = operationID.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "system", "memory", "disk", "launchd": return .system
        case "process", "app": return .processes
        case "files", "finder": return .files
        case "network": return .network
        case "security": return .security
        case "logs", "diagnostics": return .diagnostics
        default: return .system
        }
    }

    /// Prefix matches on the command first, then substring matches on command, title or description.
    /// With an empty query, recently used commands are listed first (most recent first).
    static func filter(_ all: [SlashCommand], query: String, category: SlashCategory, recent: [String] = []) -> [SlashCommand] {
        let inCategory = category == .all ? all : all.filter { $0.category == category }
        let q = query.lowercased()
        guard !q.isEmpty else {
            let recentCommands = recent.compactMap { id in inCategory.first { $0.id == id } }
            return recentCommands + inCategory.filter { c in !recentCommands.contains(c) }
        }
        let prefix = inCategory.filter { $0.id.dropFirst().lowercased().hasPrefix(q) }
        let contains = inCategory.filter { c in
            !prefix.contains(c) && (c.id.lowercased().contains(q) || c.title.lowercased().contains(q) || c.detail.lowercased().contains(q))
        }
        // Fuzzy: characters in order, e.g. "flg" → /files.largest; tighter matches first.
        let fuzzy = inCategory.filter { c in !prefix.contains(c) && !contains.contains(c) && FuzzyMatch.isSubsequence(q, of: String(c.id.dropFirst())) }
            .sorted { (FuzzyMatch.score(q, in: String($0.id.dropFirst())) ?? .max) < (FuzzyMatch.score(q, in: String($1.id.dropFirst())) ?? .max) }
        return prefix + contains + fuzzy
    }
}
