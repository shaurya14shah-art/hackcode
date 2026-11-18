import Foundation

public struct MonitorAlert: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable { case notice = "NOTICE", warning = "WARNING", critical = "CRITICAL" }
    public let id: UUID
    public let time: Date
    public let level: Level
    public let title: String
    public let detail: String
    public let pid: pid_t?
    public let key: String

    public init(level: Level, key: String, title: String, detail: String, pid: pid_t? = nil, time: Date) {
        self.id = UUID()
        self.time = time
        self.level = level
        self.key = key
        self.title = title
        self.detail = detail
        self.pid = pid
    }
}

public struct AlertThresholds: Sendable, Equatable, Codable {
    /// Percent of one core a process must exceed…
    public var processCPUPercent: Double = 85
    /// …for this many consecutive samples.
    public var sustainedSamples: Int = 5
    /// Boot-volume free-space warning, percent.
    public var diskFreePercent: Double = 10
    /// Resident-memory growth that triggers a notice (bytes).
    public var memoryGrowthBytes: UInt64 = 750 * 1024 * 1024
    public var lowBatteryPercent: Int = 10
    public init() {}

    private enum CodingKeys: String, CodingKey { case processCPUPercent, sustainedSamples, diskFreePercent, memoryGrowthBytes, lowBatteryPercent }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processCPUPercent = try c.decodeIfPresent(Double.self, forKey: .processCPUPercent) ?? processCPUPercent
        sustainedSamples = try c.decodeIfPresent(Int.self, forKey: .sustainedSamples) ?? sustainedSamples
        diskFreePercent = try c.decodeIfPresent(Double.self, forKey: .diskFreePercent) ?? diskFreePercent
        memoryGrowthBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryGrowthBytes) ?? memoryGrowthBytes
        lowBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .lowBatteryPercent) ?? lowBatteryPercent
    }
}

/// Turns consecutive monitor snapshots into factual alerts. It reports observations only — it never labels a
/// process as malicious. Each condition alerts once and re-arms after it clears.
public struct AnomalyDetector: Sendable {
    public var thresholds: AlertThresholds
    private var hotStreak: [pid_t: Int] = [:]
    private var firstRSS: [pid_t: UInt64] = [:]
    private var active: Set<String> = []
    private var baselineSwap: UInt64?
    /// Process names the user pinned; their start / stop is reported as a notice.
    public var watchedNames: Set<String> = []
    private var watchedSeen: [String: Bool] = [:]

    public init(thresholds: AlertThresholds = AlertThresholds()) { self.thresholds = thresholds }

    public mutating func evaluate(_ s: MonitorSnapshot) -> [MonitorAlert] {
        var alerts: [MonitorAlert] = []
        var stillTrue: Set<String> = []
        func raise(_ key: String, _ level: MonitorAlert.Level, _ title: String, _ detail: String, pid: pid_t? = nil) {
            stillTrue.insert(key)
            if !active.contains(key) { alerts.append(MonitorAlert(level: level, key: key, title: title, detail: detail, pid: pid, time: s.time)) }
        }

        // Sustained per-process CPU.
        let alive = Set(s.processes.map(\.pid))
        hotStreak = hotStreak.filter { alive.contains($0.key) }
        // Only libproc readings count: ps-sourced rows are refreshed every few samples and reused in between,
        // so one stale high value must not look like several consecutive samples.
        for p in s.processes where p.source == .libproc {
            if let cpu = p.cpuPercent, cpu >= thresholds.processCPUPercent {
                hotStreak[p.pid, default: 0] += 1
                if hotStreak[p.pid]! >= thresholds.sustainedSamples {
                    raise("cpu.\(p.pid)", .warning, "\(p.name) sustained high CPU",
                          String(format: "pid %d has used ≥ %.0f%% of a core for %d consecutive samples (now %.0f%%). Inspect what it is doing before drawing conclusions.",
                                 p.pid, thresholds.processCPUPercent, hotStreak[p.pid]!, cpu), pid: p.pid)
                }
            } else {
                hotStreak[p.pid] = nil
            }
        }

        // Memory growth per process since first seen.
        firstRSS = firstRSS.filter { alive.contains($0.key) }
        for p in s.processes {
            guard let rss = p.residentBytes else { continue }
            guard let first = firstRSS[p.pid] else { firstRSS[p.pid] = rss; continue }
            if rss > first, rss - first >= thresholds.memoryGrowthBytes, Double(rss) > Double(first) * 1.5 {
                raise("mem.\(p.pid)", .notice, "\(p.name) memory grew",
                      "pid \(p.pid) grew from \(MonitorObservations.bytes(first)) to \(MonitorObservations.bytes(rss)) while monitored. Growth can be normal (caches, large documents) or a leak.", pid: p.pid)
            }
        }

        if let m = s.memory.value {
            if m.pressureLevel == 4 { raise("pressure", .critical, "Memory pressure CRITICAL", "macOS reports critical memory pressure; apps may be terminated or swapping heavily.") }
            else if m.pressureLevel == 2 { raise("pressure", .warning, "Memory pressure WARNING", "macOS reports elevated memory pressure.") }
            if let swap = m.swapUsedBytes {
                if baselineSwap == nil { baselineSwap = swap }
                if let base = baselineSwap, swap > base, swap - base > 1024 * 1024 * 1024 {
                    raise("swap", .notice, "Swap usage increased", "Swap grew by \(MonitorObservations.bytes(swap - base)) since monitoring began (now \(MonitorObservations.bytes(swap))).")
                }
            }
        }

        if let boot = s.volumes.first(where: { $0.mountPoint == "/" }) ?? s.volumes.first {
            let freePct = Double(boot.availableBytes) / Double(max(boot.totalBytes, 1)) * 100
            if freePct < thresholds.diskFreePercent {
                raise("disk", .warning, "Low disk space on \(boot.name)", String(format: "%.1f%% free (%@).", freePct, ByteFormat.string(boot.availableBytes, .file)))
            }
        }

        if s.thermalState == "SERIOUS" || s.thermalState == "CRITICAL" {
            raise("thermal", s.thermalState == "CRITICAL" ? .critical : .warning, "Thermal state \(s.thermalState)", "macOS is throttling performance to manage heat.")
        }

        if let b = s.battery, !b.onAC, b.percent <= thresholds.lowBatteryPercent {
            raise("battery", .warning, "Battery low", "\(b.percent)% remaining on battery power.")
        }

        // Pinned processes: report transitions only (seen → gone, gone → back), never the initial state.
        let running = Set(s.processes.map(\.name))
        for name in watchedNames {
            let isRunning = running.contains(name)
            if let was = watchedSeen[name], was != isRunning {
                alerts.append(MonitorAlert(level: isRunning ? .notice : .warning, key: "pin.\(name).\(isRunning ? "start" : "stop")",
                                           title: isRunning ? "\(name) started" : "\(name) stopped",
                                           detail: isRunning ? "A pinned process is running again." : "A pinned process is no longer running.",
                                           time: s.time))
            }
            watchedSeen[name] = isRunning
        }
        watchedSeen = watchedSeen.filter { watchedNames.contains($0.key) }

        active = stillTrue
        return alerts
    }
}
