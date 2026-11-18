import Foundation

/// Predefined sequences of registered operations. Each step still goes through validation and the normal
/// RUN / approval flow; runbooks never contain modifying operations.
public struct Runbook: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let steps: [(operation: String, arguments: [String: ArgumentValue])]

    public static let all: [Runbook] = [
        Runbook(id: "health", title: "Quick health check", summary: "Overview, memory, disks, top CPU and battery.",
                steps: [("system.overview", [:]), ("memory.overview", [:]), ("disk.volumes", [:]),
                        ("process.top_cpu", ["limit": .integer(8)]), ("system.battery", [:])]),
        Runbook(id: "slow", title: "Why is my Mac slow?", summary: "CPU and memory hogs, memory pressure, sleep blockers, recent errors.",
                steps: [("process.top_cpu", ["limit": .integer(10)]), ("process.top_memory", ["limit": .integer(10)]),
                        ("memory.overview", [:]), ("system.power_assertions", [:]), ("logs.system_errors", ["minutes": .integer(5)])]),
        Runbook(id: "network", title: "Network diagnostics", summary: "Interfaces, routes, DNS, connectivity to apple.com, listening services.",
                steps: [("network.interfaces", [:]), ("network.routes", [:]), ("network.dns_config", [:]),
                        ("network.reachability", ["host": .string("apple.com"), "count": .integer(3)]), ("network.listening", [:])]),
        Runbook(id: "storage", title: "Free up space", summary: "Volumes, largest and old files in Downloads, duplicates, caches.",
                steps: [("disk.volumes", [:]), ("files.largest", ["path": .string("~/Downloads"), "limit": .integer(15)]),
                        ("files.stale", ["path": .string("~/Downloads"), "days": .integer(90)]),
                        ("files.duplicates", ["path": .string("~/Downloads")]), ("files.cache_sizes", [:])]),
        Runbook(id: "security", title: "Security snapshot", summary: "Full audit, firewall rules, connections, admin accounts.",
                steps: [("security.audit", [:]), ("security.firewall_apps", [:]), ("network.connections", [:]), ("security.admin_accounts", [:])]),
        Runbook(id: "crashes", title: "Crash investigation", summary: "Recent crash reports and system errors.",
                steps: [("diagnostics.crash_reports", ["limit": .integer(15)]), ("logs.system_errors", ["minutes": .integer(10)]), ("system.reboots", [:])]),
    ]

    public static func named(_ id: String) -> Runbook? { all.first { $0.id == id.lowercased() } }

    public func requests() -> [OperationRequest] {
        steps.map { OperationRequest(operationID: $0.operation, arguments: $0.arguments, provenance: .user, rationale: "Runbook: \(title)") }
    }
}
