import Foundation

/// Notices TCP listeners that appear while HackCode runs (lsof, sandboxed, current user's processes only).
public struct ListenerWatch: Sendable {
    public struct Listener: Sendable, Equatable {
        public let command: String
        public let port: String
        public let pid: String
        /// Bound to all interfaces (reachable from the network unless the firewall blocks it).
        public let exposed: Bool
        public var key: String { "\(command):\(port)" }
    }

    private var known: Set<String> = []
    private var primed = false

    public init() {}

    /// Listeners not seen before in this session. The first call only records what already exists.
    /// A listener that stops and restarts is not reported again.
    public mutating func update(_ rows: [SecurityToolRegistry.ListenRow]) -> [Listener] {
        var current: [String: Listener] = [:]
        for r in rows {
            let key = "\(r.command):\(r.port)"
            let previous = current[key]
            current[key] = Listener(command: r.command, port: r.port, pid: previous?.pid ?? r.pid,
                                    exposed: (previous?.exposed ?? false) || r.allInterfaces)
        }
        defer { known.formUnion(current.keys); primed = true }
        guard primed else { return [] }
        return current.values.filter { !known.contains($0.key) }.sorted { $0.key < $1.key }
    }

    /// One sandboxed `lsof -nP -iTCP -sTCP:LISTEN`; nil when it could not run.
    public static func sample(runner: ProcessRunning) async -> [SecurityToolRegistry.ListenRow]? {
        let ev = await SecurityToolRegistry.run(runner, "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"], timeout: 15)
        guard ev.failure == nil else { return nil }
        return SecurityToolRegistry.parseLsofListen(ev.raw)
    }
}
