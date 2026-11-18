import Foundation

/// One long-term health sample (taken at most hourly). Metadata only: no paths, names or process data.
public struct TrendSample: Codable, Sendable, Equatable {
    public var time: Date
    public var diskFreeBytes: Int64?
    public var diskTotalBytes: Int64?
    public var swapUsedBytes: UInt64?
    /// Used / physical memory, 0…1.
    public var memoryUsedFraction: Double?
    /// Full-charge capacity as a fraction of design capacity, 0…1.
    public var batteryHealth: Double?
    public var batteryCycles: Int?

    public init(time: Date = Date(), diskFreeBytes: Int64? = nil, diskTotalBytes: Int64? = nil, swapUsedBytes: UInt64? = nil,
                memoryUsedFraction: Double? = nil, batteryHealth: Double? = nil, batteryCycles: Int? = nil) {
        self.time = time
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.memoryUsedFraction = memoryUsedFraction
        self.batteryHealth = batteryHealth
        self.batteryCycles = batteryCycles
    }

    /// Samples the boot volume, memory and battery now (cheap: statfs, host_statistics, IOKit).
    public static func current(now: Date = Date()) -> TrendSample {
        let boot = SystemMetrics.volumes().first { $0.mountPoint == "/" }
        let mem = SystemMetrics.memory()
        let battery = PowerMetrics.battery()
        return TrendSample(time: now, diskFreeBytes: boot?.availableBytes, diskTotalBytes: boot?.totalBytes,
                           swapUsedBytes: mem?.swapUsedBytes,
                           memoryUsedFraction: mem.map { $0.physicalBytes > 0 ? Double($0.usedBytes) / Double($0.physicalBytes) : 0 },
                           batteryHealth: battery?.health, batteryCycles: battery?.cycleCount)
    }
}

/// Bounded, time-ordered sample log: one sample per `spacing`, nothing older than `retention`.
public struct TrendLog: Codable, Sendable, Equatable {
    public static let spacing: TimeInterval = 3600
    public static let retention: TimeInterval = 180 * 86_400
    public private(set) var samples: [TrendSample] = []

    public init(samples: [TrendSample] = []) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    /// Adds `s` unless the previous sample is less than `spacing` old; prunes expired samples. Returns whether it was added.
    @discardableResult
    public mutating func add(_ s: TrendSample) -> Bool {
        if let last = samples.last, s.time.timeIntervalSince(last.time) < Self.spacing { return false }
        samples.append(s)
        samples.sort { $0.time < $1.time }
        let cutoff = s.time.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.time < cutoff }
        return true
    }

    public func within(days: Double, now: Date = Date()) -> [TrendSample] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        return samples.filter { $0.time >= cutoff }
    }
}

public enum TrendForecast {
    /// Least-squares slope in units per day. nil with fewer than 3 points or a time span shorter than `minSpanDays`.
    public static func slopePerDay(_ points: [(Date, Double)], minSpanDays: Double = 2) -> Double? {
        guard points.count >= 3, let first = points.map(\.0).min(), let last = points.map(\.0).max(),
              last.timeIntervalSince(first) >= minSpanDays * 86_400 else { return nil }
        let xs = points.map { $0.0.timeIntervalSince(first) / 86_400 }
        let ys = points.map(\.1)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Days from the latest point until the trend line reaches `threshold`; nil when the trend is flat or moving away.
    public static func daysUntil(_ threshold: Double, points: [(Date, Double)], minSpanDays: Double = 2) -> Double? {
        guard let slope = slopePerDay(points, minSpanDays: minSpanDays), slope != 0,
              let latest = points.max(by: { $0.0 < $1.0 }) else { return nil }
        let days = (threshold - latest.1) / slope
        return days > 0 ? days : nil
    }

    /// Days until the boot disk is full when that is within `horizonDays`, judged on the last `windowDays` of samples.
    public static func diskFullWithin(_ samples: [TrendSample], horizonDays: Double = 14, windowDays: Double = 14,
                                      now: Date = Date()) -> Double? {
        let cutoff = now.addingTimeInterval(-windowDays * 86_400)
        let pts = samples.filter { $0.time >= cutoff }.compactMap { s in s.diskFreeBytes.map { (s.time, Double($0)) } }
        guard let days = daysUntil(0, points: pts), days <= horizonDays else { return nil }
        return days
    }

    /// Plain-text summary for the terminal (`/trends`).
    public static func textReport(_ log: TrendLog, now: Date = Date()) -> String {
        guard let latest = log.samples.last else {
            return "No trend samples yet — HackCode records one per hour while it is open (MONITOR › TRENDS)."
        }
        func change(_ days: Double) -> String? {
            let cutoff = now.addingTimeInterval(-days * 86_400)
            guard let then = log.samples.first(where: { $0.time >= cutoff })?.diskFreeBytes, let free = latest.diskFreeBytes,
                  log.samples.first.map({ now.timeIntervalSince($0.time) >= days * 86_400 * 0.5 }) == true else { return nil }
            let d = free - then
            return (d >= 0 ? "+" : "−") + ByteFormat.string(abs(d))
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd-MMM"
        var rows: [(String, String)] = []
        rows.append(("samples", "\(log.samples.count) · \(f.string(from: log.samples.first!.time)) → \(f.string(from: latest.time))"))
        if let free = latest.diskFreeBytes {
            let total = latest.diskTotalBytes.map { " of " + ByteFormat.string($0) } ?? ""
            let changes = [("7 d", change(7)), ("30 d", change(30))].compactMap { k, v in v.map { "\(k) \($0)" } }
            rows.append(("disk", ByteFormat.string(free) + " free" + total + (changes.isEmpty ? "" : " · " + changes.joined(separator: " · "))))
        }
        rows.append(("forecast", diskSummary(log.within(days: 30, now: now))))
        if latest.batteryHealth != nil || latest.batteryCycles != nil {
            let h = latest.batteryHealth.map { String(format: "health %.1f%%", $0 * 100) }
            let c = latest.batteryCycles.map { "\($0) cycles" }
            rows.append(("battery", [h, c].compactMap { $0 }.joined(separator: " · ")))
        }
        if let swap = latest.swapUsedBytes { rows.append(("swap", ByteFormat.string(Int64(swap)) + " used")) }
        return rows.map { $0.0.padding(toLength: 10, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
            + "\n\nCharts: MONITOR › TRENDS (⌘2)"
    }

    /// Human summary of a disk-full forecast.
    public static func diskSummary(_ samples: [TrendSample]) -> String {
        let pts = samples.compactMap { s in s.diskFreeBytes.map { (s.time, Double($0)) } }
        guard let slope = slopePerDay(pts) else { return "Collecting data — a forecast needs at least 2 days of samples." }
        let perDay = ByteFormat.string(Int64(abs(slope)))
        if slope >= 0 { return "Free space is stable or growing (+\(perDay)/day)." }
        guard let days = daysUntil(0, points: pts) else { return "Free space is shrinking by \(perDay)/day." }
        if days > 365 { return "Shrinking by \(perDay)/day — more than a year until full at this rate." }
        return "Shrinking by \(perDay)/day — full in about \(Int(days.rounded())) day\(Int(days.rounded()) == 1 ? "" : "s") at this rate."
    }
}

/// Persists the trend log as owner-only JSON in Application Support.
public actor TrendStore {
    private let url: URL?

    public init(url: URL? = TrendStore.defaultURL()) { self.url = url }

    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HackCode", isDirectory: true).appendingPathComponent("trends.json")
    }

    public func load() -> TrendLog {
        guard let url, let data = try? Data(contentsOf: url) else { return TrendLog() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(TrendLog.self, from: data)) ?? TrendLog()
    }

    /// Loads, adds (respecting spacing/retention), saves. Returns the updated log.
    @discardableResult
    public func record(_ sample: TrendSample) -> TrendLog {
        var log = load()
        if log.add(sample) { save(log) }
        return log
    }

    public func save(_ log: TrendLog) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let url, let data = try? e.encode(log) else { return }
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
