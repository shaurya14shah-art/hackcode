import Foundation

/// Fixed-capacity ring buffer used for all monitoring history.
public struct RingBuffer<Element: Sendable>: Sendable {
    public private(set) var capacity: Int
    private var storage: [Element] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public mutating func resize(_ newCapacity: Int) {
        capacity = max(1, newCapacity)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public var elements: [Element] { storage }
    public var count: Int { storage.count }
    public var last: Element? { storage.last }
}

public struct MetricPoint: Sendable, Equatable {
    public let time: Date
    public let cpuBusy: Double?
    public let memoryUsedFraction: Double?
    public let netInBytesPerSecond: Double?
    public let netOutBytesPerSecond: Double?
}

public struct RatePoint: Sendable, Equatable {
    public let inBytesPerSecond: Double
    public let outBytesPerSecond: Double
}

public struct MonitorSnapshot: Sendable {
    public let time: Date
    public let cpu: Measured<CPUUsage>
    public let memory: Measured<MemoryStats>
    public let loadAverages: [Double]?
    public let volumes: [VolumeStats]
    public let interfaces: [InterfaceRate]
    public let processes: [ProcessSample]
    public let restrictedProcessCount: Int
    public let unavailableProcessCount: Int
    public let collectionDuration: TimeInterval
    public let history: [MetricPoint]
    public let bootTime: Date?
    public var battery: BatteryStatus? = nil
    public var thermalState: String = "NOMINAL"
    /// Bounded per-interface throughput history (oldest first).
    public var interfaceHistory: [String: [RatePoint]] = [:]
    public var interfaceAddresses: [String: [String]] = [:]
}

/// Collects system and process metrics off the main actor and keeps bounded history.
public actor SystemMonitor {
    private let sampler: ProcessSampler
    private var lastTicks: CPUTicks?
    private var lastCounters: [String: InterfaceCounters] = [:]
    private var lastCounterTime: Date?
    private var history: RingBuffer<MetricPoint>
    /// Per-process CPU history, only for processes that recently ranked in the top 40.
    private var processCPUHistory: [pid_t: RingBuffer<Double>] = [:]
    private let processHistoryLength = 30
    private var rateHistory: [String: RingBuffer<RatePoint>] = [:]
    // Slow, slowly-changing readings are cached between ticks (the purgeable-space volume key alone costs several ms).
    public static let volumeRefresh: TimeInterval = 30
    public static let batteryRefresh: TimeInterval = 10
    private var cachedVolumes: [VolumeStats] = []
    private var volumesAt: Date?
    private var cachedBattery: BatteryStatus?
    private var batteryAt: Date?

    private func volumes(now: Date) -> [VolumeStats] {
        if let at = volumesAt, now.timeIntervalSince(at) < Self.volumeRefresh { return cachedVolumes }
        cachedVolumes = SystemMetrics.volumes()
        volumesAt = now
        return cachedVolumes
    }

    private func battery(now: Date) -> BatteryStatus? {
        if let at = batteryAt, now.timeIntervalSince(at) < Self.batteryRefresh { return cachedBattery }
        cachedBattery = PowerMetrics.battery()
        batteryAt = now
        return cachedBattery
    }

    /// Forces fresh volume and battery readings on the next tick (e.g. after files were moved to the Trash).
    public func invalidateSlowReadings() {
        volumesAt = nil
        batteryAt = nil
    }
    public private(set) var latest: MonitorSnapshot?

    public init(sampler: ProcessSampler = ProcessSampler(), historyLength: Int = 120) {
        self.sampler = sampler
        self.history = RingBuffer(capacity: historyLength)
        self.lastTicks = SystemMetrics.cpuTicks()
    }

    public func setHistoryLength(_ length: Int) { history.resize(length) }

    @discardableResult
    public func collect() async -> MonitorSnapshot {
        let start = Date()
        let ticks = SystemMetrics.cpuTicks()
        let cpu: Measured<CPUUsage>
        if let ticks, let last = lastTicks, let usage = SystemMetrics.cpuUsage(from: last, to: ticks) {
            cpu = .value(usage)
        } else {
            cpu = .unavailable(ticks == nil ? "host_statistics failed" : "warming up — needs a second sample")
        }
        if let ticks { lastTicks = ticks }

        let memory: Measured<MemoryStats> = SystemMetrics.memory().map { .value($0) } ?? .unavailable("host_statistics64 failed")
        let interfaces = interfaceRates(now: start)
        let processes = await sampler.sample()
        updateProcessHistory(processes)

        let netIn = interfaces.isEmpty ? nil : interfaces.reduce(0) { $0 + $1.bytesInPerSecond }
        let netOut = interfaces.isEmpty ? nil : interfaces.reduce(0) { $0 + $1.bytesOutPerSecond }
        history.append(MetricPoint(time: start, cpuBusy: cpu.value?.busy,
                                   memoryUsedFraction: memory.value.map { Double($0.usedBytes) / Double(max($0.physicalBytes, 1)) },
                                   netInBytesPerSecond: lastCounterTime == nil ? nil : netIn,
                                   netOutBytesPerSecond: lastCounterTime == nil ? nil : netOut))

        let snapshot = MonitorSnapshot(time: start, cpu: cpu, memory: memory, loadAverages: SystemMetrics.loadAverages(),
                                       volumes: volumes(now: start), interfaces: interfaces, processes: processes,
                                       restrictedProcessCount: processes.filter { $0.source == .ps }.count,
                                       unavailableProcessCount: processes.filter { $0.source == .unavailable }.count,
                                       collectionDuration: Date().timeIntervalSince(start), history: history.elements,
                                       bootTime: SystemMetrics.bootTime(), battery: battery(now: start),
                                       thermalState: PowerMetrics.thermalState,
                                       interfaceHistory: recordRates(interfaces),
                                       interfaceAddresses: SystemMetrics.interfaceAddresses())
        latest = snapshot
        return snapshot
    }

    private func recordRates(_ rates: [InterfaceRate]) -> [String: [RatePoint]] {
        let capacity = history.capacity
        for r in rates {
            var buffer = rateHistory[r.name] ?? RingBuffer(capacity: capacity)
            if buffer.capacity != capacity { buffer.resize(capacity) }
            buffer.append(RatePoint(inBytesPerSecond: r.bytesInPerSecond, outBytesPerSecond: r.bytesOutPerSecond))
            rateHistory[r.name] = buffer
        }
        let live = Set(rates.map(\.name))
        rateHistory = rateHistory.filter { live.contains($0.key) }
        return rateHistory.mapValues(\.elements)
    }

    public func cpuHistory(for pid: pid_t) -> [Double] {
        processCPUHistory[pid]?.elements ?? []
    }

    private func interfaceRates(now: Date) -> [InterfaceRate] {
        let counters = SystemMetrics.interfaceCounters()
        let elapsed = lastCounterTime.map { now.timeIntervalSince($0) } ?? 0
        var rates: [InterfaceRate] = []
        var seen = Set<String>()
        for c in counters where !seen.contains(c.name) {
            seen.insert(c.name)
            // Skip loopback and interfaces that have never carried traffic.
            guard c.name != "lo0", c.bytesIn + c.bytesOut > 0 else { continue }
            var inRate = 0.0, outRate = 0.0
            if elapsed > 0, let prev = lastCounters[c.name] {
                inRate = c.bytesIn >= prev.bytesIn ? Double(c.bytesIn - prev.bytesIn) / elapsed : 0
                outRate = c.bytesOut >= prev.bytesOut ? Double(c.bytesOut - prev.bytesOut) / elapsed : 0
            }
            rates.append(InterfaceRate(name: c.name, bytesInPerSecond: inRate, bytesOutPerSecond: outRate,
                                       totalIn: c.bytesIn, totalOut: c.bytesOut, isUp: c.isUp))
        }
        lastCounters = Dictionary(counters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        lastCounterTime = now
        return rates.sorted { ($0.totalIn + $0.totalOut) > ($1.totalIn + $1.totalOut) }
    }

    private func updateProcessHistory(_ processes: [ProcessSample]) {
        let top = processes.filter { $0.cpuPercent != nil }.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(40)
        let topPIDs = Set(top.map(\.pid))
        for p in top {
            var buffer = processCPUHistory[p.pid] ?? RingBuffer(capacity: processHistoryLength)
            buffer.append(p.cpuPercent ?? 0)
            processCPUHistory[p.pid] = buffer
        }
        // Keep tracking previously-hot processes while alive, but drop dead ones and bound total size.
        let alive = Set(processes.map(\.pid))
        processCPUHistory = processCPUHistory.filter { alive.contains($0.key) }
        for p in processes where !topPIDs.contains(p.pid) {
            if var buffer = processCPUHistory[p.pid] {
                buffer.append(p.cpuPercent ?? 0)
                processCPUHistory[p.pid] = buffer
            }
        }
        if processCPUHistory.count > 120 {
            let keep = Set(processCPUHistory.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(120).map(\.key))
            processCPUHistory = processCPUHistory.filter { keep.contains($0.key) }
        }
    }
}

/// Deterministic, evidence-only observations computed locally. These are what the model is asked to interpret;
/// the model never sees raw process inventories beyond the bounded summary built here.
public enum MonitorObservations {
    public struct ProcessTrend: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let current: Double
        public let baselineMedian: Double
        public let samples: Int
        public let sustainedAboveBaseline: Bool
    }

    public static func trend(pid: pid_t, name: String, history: [Double]) -> ProcessTrend? {
        guard history.count >= 6, let current = history.last else { return nil }
        let earlier = Array(history.dropLast(3))
        let recent = Array(history.suffix(3))
        let median = earlier.sorted()[earlier.count / 2]
        let threshold = max(median * 2, median + 15)
        let sustained = recent.allSatisfy { $0 > threshold }
        return ProcessTrend(pid: pid, name: name, current: current, baselineMedian: median, samples: history.count,
                            sustainedAboveBaseline: sustained)
    }

    /// Builds a compact, bounded text summary of measured facts (no inference).
    public static func summary(_ s: MonitorSnapshot, trends: [ProcessTrend], topN: Int = 8, redactor: Redactor = Redactor()) -> String {
        var lines: [String] = []
        let f = ISO8601DateFormatter()
        lines.append("Sample time: \(f.string(from: s.time)); history points: \(s.history.count)")
        switch s.cpu {
        case .value(let c):
            lines.append(String(format: "System CPU: %.0f%% busy (user %.0f%%, system %.0f%%)", c.busy * 100, c.user * 100, c.system * 100))
        case .unavailable(let why): lines.append("System CPU: unavailable (\(why))")
        }
        let cpuHist = s.history.compactMap(\.cpuBusy)
        if cpuHist.count >= 3 {
            let avg = cpuHist.reduce(0, +) / Double(cpuHist.count)
            lines.append(String(format: "CPU busy average over last %d samples: %.0f%%, max %.0f%%", cpuHist.count, avg * 100, (cpuHist.max() ?? 0) * 100))
        }
        if let l = s.loadAverages { lines.append(String(format: "Load averages: %.2f %.2f %.2f; logical CPUs: %d", l[0], l[1], l[2], ProcessInfo.processInfo.activeProcessorCount)) }
        switch s.memory {
        case .value(let m):
            lines.append("Memory: used \(bytes(m.usedBytes)) of \(bytes(m.physicalBytes)) (app \(bytes(m.appBytes)), wired \(bytes(m.wiredBytes)), compressed \(bytes(m.compressedBytes))); pressure \(m.pressureLabel); swap used \(m.swapUsedBytes.map(bytes) ?? "unknown")")
        case .unavailable(let why): lines.append("Memory: unavailable (\(why))")
        }
        let byCPU = s.processes.filter { $0.cpuPercent != nil }.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(topN)
        lines.append("Top processes by CPU (percent of one core, measured over the last interval):")
        for p in byCPU {
            lines.append(String(format: "  pid %d %@ — %.1f%% CPU, %@ RSS, user %@, source %@", p.pid, redactor.redact(p.name), p.cpuPercent ?? 0,
                                p.residentBytes.map(bytes) ?? "?", p.user ?? "?", p.source.rawValue))
        }
        let byMem = s.processes.filter { $0.residentBytes != nil }.sorted { ($0.residentBytes ?? 0) > ($1.residentBytes ?? 0) }.prefix(topN)
        let totalRSS = s.processes.compactMap(\.residentBytes).reduce(0, +)
        lines.append("Top processes by resident memory (RSS overstates shared memory; total RSS of all visible processes \(bytes(totalRSS))):")
        for p in byMem {
            let share = totalRSS > 0 ? Double(p.residentBytes ?? 0) / Double(totalRSS) * 100 : 0
            lines.append(String(format: "  pid %d %@ — %@ (%.1f%% of summed RSS)", p.pid, redactor.redact(p.name), bytes(p.residentBytes ?? 0), share))
        }
        let notable = trends.filter(\.sustainedAboveBaseline)
        if notable.isEmpty {
            lines.append("No process has stayed well above its own recent CPU baseline for the last 3 samples.")
        } else {
            for t in notable {
                lines.append(String(format: "Trend: pid %d %@ above its baseline for the last 3 samples (now %.0f%%, earlier median %.0f%%, %d samples)",
                                    t.pid, redactor.redact(t.name), t.current, t.baselineMedian, t.samples))
            }
        }
        lines.append("Thermal state: \(s.thermalState)" + (s.battery.map { "; battery \($0.percent)% \($0.onAC ? "on AC" : "on battery")" } ?? ""))
        if s.restrictedProcessCount > 0 {
            lines.append("\(s.restrictedProcessCount) processes belong to other users; their figures come from ps with lower precision.")
        }
        return lines.joined(separator: "\n")
    }

    public static func bytes(_ b: UInt64) -> String {
        ByteFormat.string(Int64(clamping: b), .memory)
    }
}
