import Foundation

/// Terminal command history: bounded, secret-redacted, with reverse search and `/` command usage ranking.
public struct CommandHistory: Codable, Sendable, Equatable {
    public private(set) var entries: [String] = []
    /// Most recently used slash commands (e.g. "/files.largest", "/runbook health"), newest first.
    public private(set) var recentSlash: [String] = []
    public static let maxEntries = 500
    public static let maxRecentSlash = 8

    public init() {}

    /// Records a submitted line. Secrets are redacted before storage; an immediate repeat is not stored twice.
    public mutating func record(_ line: String, redactor: Redactor = Redactor()) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clean = Redactor.sanitizeForPrompt(redactor.redact(trimmed, abbreviateHome: false), maxCharacters: 2000)
        if entries.last != clean { entries.append(clean) }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if let id = Self.slashID(clean) {
            recentSlash.removeAll { $0 == id }
            recentSlash.insert(id, at: 0)
            if recentSlash.count > Self.maxRecentSlash { recentSlash.removeLast(recentSlash.count - Self.maxRecentSlash) }
        }
    }

    /// The command identity used for ranking: "/runbook <id>", "/run <op>" → "/<op>", otherwise the first word.
    static func slashID(_ line: String) -> String? {
        guard line.hasPrefix("/") else { return nil }
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if first == "/runbook", words.count > 1 { return "/runbook \(words[1])" }
        if first == "/run", words.count > 1 { return "/\(words[1])" }
        return first
    }

    /// Reverse incremental search: newest entry containing `query` (case-insensitive) strictly older than `before`.
    public func search(_ query: String, before: Int? = nil) -> (index: Int, line: String)? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        var i = min(before ?? entries.count, entries.count) - 1
        while i >= 0 {
            if entries[i].lowercased().contains(q) { return (i, entries[i]) }
            i -= 1
        }
        return nil
    }

    public mutating func clear() {
        entries.removeAll()
        recentSlash.removeAll()
    }
}

/// Persists `CommandHistory` as owner-only JSON in Application Support.
public actor CommandHistoryStore {
    private let url: URL?

    public init(url: URL? = CommandHistoryStore.defaultURL()) { self.url = url }

    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HackCode", isDirectory: true).appendingPathComponent("command-history.json")
    }

    public func load() -> CommandHistory {
        guard let url, let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(CommandHistory.self, from: data) else { return CommandHistory() }
        return history
    }

    public func save(_ history: CommandHistory) {
        guard let url, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
