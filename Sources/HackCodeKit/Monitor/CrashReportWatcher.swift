import Foundation

/// Detects crash / hang / panic reports that appear after monitoring starts (directory listing only).
public struct CrashReportWatcher: Sendable {
    public struct Report: Sendable, Equatable {
        public let name: String
        public let app: String
        public let kind: String
        public let date: Date
        public let systemWide: Bool

        public init(name: String, app: String, kind: String, date: Date, systemWide: Bool) {
            self.name = name
            self.app = app
            self.kind = kind
            self.date = date
            self.systemWide = systemWide
        }
    }

    public let directories: [String]
    private var seen: Set<String> = []
    private var primed = false
    static let suffixes = [".ips", ".crash", ".hang", ".panic", ".diag", ".spin"]

    public init(directories: [String]) { self.directories = directories }

    public static func standard(home: String = NSHomeDirectory()) -> CrashReportWatcher {
        CrashReportWatcher(directories: [(home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"),
                                         "/Library/Logs/DiagnosticReports"])
    }

    /// Returns reports that are new since the previous call. The first call only records what already exists.
    public mutating func check() -> [Report] {
        let current = listing()
        defer { seen = Set(current.keys); primed = true }
        guard primed else { return [] }
        return current.filter { !seen.contains($0.key) }.map(\.value).sorted { $0.date < $1.date }
    }

    /// Reports modified after `date`, oldest first (directory listing + modification dates only).
    public func reports(since date: Date) -> [Report] {
        listing().values.filter { $0.date > date }.sorted { $0.date < $1.date }
    }

    private func listing() -> [String: Report] {
        var current: [String: Report] = [:]
        for dir in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where Self.suffixes.contains(where: n.hasSuffix) {
                let path = (dir as NSString).appendingPathComponent(n)
                let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
                current[path] = Report(name: n, app: Self.appName(from: n), kind: Self.kind(from: n), date: date,
                                       systemWide: dir.hasPrefix("/Library"))
            }
        }
        return current
    }

    /// "Safari-2026-10-21-101010.ips" → "Safari"; "ExcUserFault_Foo-2026-…" → "Foo".
    static func appName(from file: String) -> String {
        var base = (file as NSString).deletingPathExtension
        for prefix in ["ExcUserFault_", "JetsamEvent", "Stackshot_"] where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        }
        if let r = base.range(of: "[-_]\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) { base = String(base[..<r.lowerBound]) }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return trimmed.isEmpty ? file : trimmed
    }

    static func kind(from file: String) -> String {
        switch (file as NSString).pathExtension {
        case "hang", "spin": return "hang"
        case "panic": return "kernel panic"
        case "diag": return "diagnostic"
        default: return file.hasPrefix("JetsamEvent") ? "memory-pressure kill" : "crash"
        }
    }
}
