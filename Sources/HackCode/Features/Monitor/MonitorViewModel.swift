import SwiftUI
import Observation
import HackCodeKit

@MainActor
@Observable
final class MonitorViewModel {
    enum SortKey: String, CaseIterable { case cpu = "CPU", memory = "MEM", pid = "PID", name = "NAME", threads = "THR", user = "USER" }
    enum Scope: String, CaseIterable { case all = "ALL", mine = "MINE", others = "OTHER USERS" }

    private(set) var snapshot: MonitorSnapshot?
    private(set) var lastUpdate: Date?
    private(set) var isRunning = true
    private(set) var isVisible = false
    var sortKey: SortKey = .cpu
    var ascending = false
    var search = ""
    var scope: Scope = .all
    var selectedPID: pid_t?
    private(set) var selectedHistory: [Double] = []

    enum Pane: String, CaseIterable { case processes = "PROCESSES", network = "NETWORK", trends = "TRENDS" }
    var trendDays: Double = 30
    var pane: Pane = .processes {
        didSet { if pane == .network && oldValue != .network { lastWiFiSample = nil } }
    }

    var question = ""
    private(set) var analysis = ""
    private(set) var isAnalyzing = false
    private(set) var analysisError: String?
    private(set) var analysisDisclosure: String?

    private(set) var alerts: [MonitorAlert] = []
    var unseenAlerts = 0
    var showAlertList = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var detector = AnomalyDetector()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    static let maxRows = 400

    func attach(_ app: AppModel) { self.app = app }

    var interval: Double { app?.settings.monitorIntervalSeconds ?? 2 }

    /// Data older than three intervals is flagged as stale in the UI.
    func isStale(at now: Date) -> Bool {
        guard let lastUpdate else { return false }
        return isRunning && now.timeIntervalSince(lastUpdate) > max(3 * interval, 4)
    }

    func applyThresholds(_ t: AlertThresholds) { detector.thresholds = t }

    // MARK: Pinned processes (by name)

    struct PinnedStat: Identifiable {
        var id: String { name }
        let name: String
        let instances: Int
        let cpu: Double
        let rss: UInt64
        let history: [Double?]
    }

    @ObservationIgnored private var pinnedHistory: [String: RingBuffer<Double?>] = [:]

    var pinned: [String] { app?.settings.pinnedProcesses ?? [] }

    func isPinned(_ name: String) -> Bool { pinned.contains(name) }

    func togglePin(_ name: String) {
        guard let app else { return }
        app.update { s in
            if let i = s.pinnedProcesses.firstIndex(of: name) { s.pinnedProcesses.remove(at: i) } else { s.pinnedProcesses.append(name) }
        }
        detector.watchedNames = Set(app.settings.pinnedProcesses)
    }

    var pinnedStats: [PinnedStat] {
        guard let snapshot else { return [] }
        return pinned.map { name in
            let matching = snapshot.processes.filter { $0.name == name }
            return PinnedStat(name: name, instances: matching.count,
                              cpu: matching.compactMap(\.cpuPercent).reduce(0, +),
                              rss: matching.compactMap(\.residentBytes).reduce(0, +),
                              history: pinnedHistory[name]?.elements ?? [])
        }
    }

    private func recordPinned(_ snap: MonitorSnapshot) {
        detector.watchedNames = Set(pinned)
        for name in pinned {
            let matching = snap.processes.filter { $0.name == name }
            var buffer = pinnedHistory[name] ?? RingBuffer(capacity: 60)
            buffer.append(matching.isEmpty ? nil : matching.compactMap(\.cpuPercent).reduce(0, +))
            pinnedHistory[name] = buffer
        }
        pinnedHistory = pinnedHistory.filter { pinned.contains($0.key) }
    }

    var isSamplingActive: Bool { isRunning && (isVisible || (app?.settings.backgroundMonitoring ?? false)) }

    /// Alerts from sources other than the sampler (e.g. the crash watcher).
    func addAlert(_ alert: MonitorAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > 100 { alerts.removeLast(alerts.count - 100) }
        if !isVisible { unseenAlerts += 1 }
    }

    func viewCrashReport(_ alert: MonitorAlert) {
        guard alert.key.hasPrefix("crash.") else { return }
        let name = String(alert.key.dropFirst("crash.".count))
        stage("diagnostics.crash_report", arguments: ["name": .string(name)], label: "Crash report \(name)")
    }

    func clearAlerts() {
        alerts.removeAll()
        unseenAlerts = 0
    }

    // MARK: Lifecycle — sample while visible (or always, with background monitoring) and not paused.

    func appeared() {
        isVisible = true
        restartLoop()
    }

    func disappeared() {
        isVisible = false
        restartLoop()
    }

    func toggleRunning() {
        isRunning.toggle()
        restartLoop()
    }

    func refreshNow() {
        guard let app else { return }
        Task { await self.apply(await app.monitorService.collect()) }
    }

    func restartLoop() {
        loop?.cancel()
        loop = nil
        guard isSamplingActive, let app else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let snap = await app.monitorService.collect()   // runs on the SystemMonitor actor, off the main thread
                guard let self, !Task.isCancelled else { return }
                await self.apply(snap)
                let wait = self.interval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Current Wi-Fi association (CoreWLAN, no network name) and its recent RSSI (nil = not associated).
    private(set) var wifi: WiFiStatus?
    private(set) var wifiRSSI: [Double?] = []

    @ObservationIgnored private var lastWiFiSample: Date?
    @ObservationIgnored private var wifiSampling = false

    /// CoreWLAN talks to the Wi-Fi daemon over XPC (several ms), so it runs off the main actor: every tick while
    /// NETWORK is visible, otherwise every 15 s (enough for the menu bar and /report).
    private func sampleWiFi(now: Date = Date()) {
        let every: TimeInterval = pane == .network ? 0 : 15
        if let last = lastWiFiSample, now.timeIntervalSince(last) < every { return }
        guard !wifiSampling else { return }
        lastWiFiSample = now
        wifiSampling = true
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { WiFiMetrics.current() }.value
            guard let self else { return }
            self.wifi = status
            self.wifiRSSI.append(status.flatMap { $0.associated ? Double($0.rssi) : nil })
            if self.wifiRSSI.count > 150 { self.wifiRSSI.removeFirst(self.wifiRSSI.count - 150) }
            self.wifiSampling = false
        }
    }

    @ObservationIgnored private var listenerWatch = ListenerWatch()
    @ObservationIgnored private var lastListenerCheck: Date?
    @ObservationIgnored private var listenerCheckRunning = false

    /// Every 60 s: alert on TCP listeners that appeared since HackCode started (sandboxed lsof, own processes only).
    func checkListeners(now: Date = Date()) {
        guard let app, !listenerCheckRunning else { return }
        if let last = lastListenerCheck, now.timeIntervalSince(last) < 60 { return }
        lastListenerCheck = now
        listenerCheckRunning = true
        Task { [weak self] in
            let rows = await ListenerWatch.sample(runner: app.runner)
            guard let self else { return }
            self.listenerCheckRunning = false
            guard let rows else { return }
            for l in self.listenerWatch.update(rows) {
                let alert = MonitorAlert(level: l.exposed ? .warning : .notice, key: "listen.\(l.key)",
                                         title: "New listening port \(l.port) — \(l.command)",
                                         detail: l.exposed ? "Accepting connections on all interfaces (reachable from the network unless the firewall blocks it). pid \(l.pid). Check it is expected; NETWORK › LISTENING SERVICES lists all."
                                                           : "Localhost only (not reachable from other machines). pid \(l.pid).",
                                         pid: pid_t(l.pid), time: Date())
                self.addAlert(alert)
                if l.exposed { app.notify("HackCode · new network listener", "\(l.command) is accepting connections on port \(l.port).") }
                await app.auditLog.record(AuditEvent(kind: .monitorAlert, operation: "monitor.listener", outcome: alert.level.rawValue.lowercased(),
                                                     detail: "\(l.command) listening on \(l.port)\(l.exposed ? " (all interfaces)" : " (localhost)")"))
            }
        }
    }

    #if DEBUG || SNAPSHOT_HARNESS
    @ObservationIgnored var debugTicks = 0

    func debugForceListenerCheck() async {
        while listenerCheckRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        lastListenerCheck = nil
        checkListeners()
        try? await Task.sleep(nanoseconds: 100_000_000)
        while listenerCheckRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    #endif

    private func apply(_ snap: MonitorSnapshot) async {
        snapshot = snap
        lastUpdate = snap.time
        #if DEBUG || SNAPSHOT_HARNESS
        debugTicks += 1
        #endif
        sampleWiFi()
        checkListeners()
        recordPinned(snap)
        let fresh = detector.evaluate(snap)
        if !fresh.isEmpty {
            alerts.insert(contentsOf: fresh.reversed(), at: 0)
            if alerts.count > 100 { alerts.removeLast(alerts.count - 100) }
            if !isVisible { unseenAlerts += fresh.count }
            for a in fresh where a.level != .notice { app?.notify("HackCode · \(a.title)", a.detail) }
            if let app {
                for a in fresh {
                    await app.auditLog.record(AuditEvent(kind: .monitorAlert, operation: "monitor.\(a.key)", outcome: a.level.rawValue, detail: a.title))
                }
            }
        }
        if let pid = selectedPID, let app {
            selectedHistory = await app.monitorService.cpuHistory(for: pid)
        }
    }

    func select(_ pid: pid_t?) {
        guard pid != selectedPID else { return }
        selectedPID = pid
        // Dependent state is updated asynchronously: changing it inside NSTableView's selection callback
        // would re-enter the table delegate.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let pid, let app = self.app else { self.selectedHistory = []; return }
            let history = await app.monitorService.cpuHistory(for: pid)
            if self.selectedPID == pid { self.selectedHistory = history }
        }
    }

    var selectedProcess: ProcessSample? {
        guard let pid = selectedPID else { return nil }
        return snapshot?.processes.first { $0.pid == pid }
    }

    private struct RowsKey: Equatable {
        let time: Date, search: String, scope: Scope, sortKey: SortKey, ascending: Bool
    }
    @ObservationIgnored private var rowsCache: (key: RowsKey, rows: [ProcessSample])?

    /// Filtered + sorted table rows, cached per sample/filter/sort (views re-render for selection and alerts too).
    var rows: [ProcessSample] {
        guard let snapshot else { return [] }
        let key = RowsKey(time: snapshot.time, search: search, scope: scope, sortKey: sortKey, ascending: ascending)
        if let c = rowsCache, c.key == key { return c.rows }
        let result = computeRows(snapshot)
        rowsCache = (key, result)
        return result
    }

    private func computeRows(_ snapshot: MonitorSnapshot) -> [ProcessSample] {
        let uid = getuid()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = snapshot.processes.filter { p in
            switch scope {
            case .all: break
            case .mine: if p.uid != uid { return false }
            case .others: if p.uid == uid { return false }
            }
            guard !q.isEmpty else { return true }
            return p.name.lowercased().contains(q) || String(p.pid) == q || (p.user?.lowercased().contains(q) ?? false)
        }
        let asc = ascending
        let sorted: [ProcessSample]
        switch sortKey {
        case .cpu: sorted = filtered.sorted { asc ? $0.cpuSortKey < $1.cpuSortKey : $0.cpuSortKey > $1.cpuSortKey }
        case .memory: sorted = filtered.sorted { asc ? $0.memorySortKey < $1.memorySortKey : $0.memorySortKey > $1.memorySortKey }
        case .pid: sorted = filtered.sorted { asc ? $0.pid < $1.pid : $0.pid > $1.pid }
        case .name: sorted = filtered.sorted { asc ? $0.nameSortKey < $1.nameSortKey : $0.nameSortKey > $1.nameSortKey }
        case .threads: sorted = filtered.sorted { asc ? $0.threadSortKey < $1.threadSortKey : $0.threadSortKey > $1.threadSortKey }
        case .user: sorted = filtered.sorted { asc ? $0.userSortKey < $1.userSortKey : $0.userSortKey > $1.userSortKey }
        }
        return Array(sorted.prefix(Self.maxRows))
    }


    // MARK: Cross-module actions

    func stage(_ id: String, pid: pid_t, label: String) {
        app?.sysAdmin.stage(OperationRequest(operationID: id, arguments: ["pid": .integer(Int(pid))], provenance: .user), note: label)
    }

    func stage(_ id: String, arguments: [String: ArgumentValue], label: String) {
        app?.sysAdmin.stage(OperationRequest(operationID: id, arguments: arguments, provenance: .user), note: label)
    }

    // MARK: Keyboard selection

    // MARK: Tree view

    var treeMode = false
    var collapsed: Set<pid_t> = []

    /// Tree rows (scope filter applies; the text filter switches the table back to a flat list).
    var treeRows: [ProcessTree.Row] {
        guard let snapshot else { return [] }
        let uid = getuid()
        let scoped = snapshot.processes.filter { p in
            switch scope {
            case .all: return true
            case .mine: return p.uid == uid
            case .others: return p.uid != uid
            }
        }
        let key = sortKey, asc = ascending
        return ProcessTree.rows(scoped, collapsed: collapsed) { a, b in
            let r: Bool
            switch key {
            case .cpu: r = a.cpuSortKey < b.cpuSortKey
            case .memory: r = a.memorySortKey < b.memorySortKey
            case .pid: r = a.pid < b.pid
            case .name: r = a.nameSortKey < b.nameSortKey
            case .threads: r = a.threadSortKey < b.threadSortKey
            case .user: r = a.userSortKey < b.userSortKey
            }
            return asc ? r : !r
        }
    }

    var showsTree: Bool { treeMode && search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// ← collapses the selected branch, or moves to its parent.
    func treeLeft() {
        guard showsTree, let pid = selectedPID, let row = treeRows.first(where: { $0.sample.pid == pid }) else { return }
        if row.hasChildren && !collapsed.contains(pid) {
            collapsed.insert(pid)
        } else if let parent = row.sample.ppid, treeRows.contains(where: { $0.sample.pid == parent }) {
            select(parent)
        }
    }

    /// → expands the selected branch, or moves to its first child.
    func treeRight() {
        guard showsTree, let pid = selectedPID else { return }
        let rows = treeRows
        guard let i = rows.firstIndex(where: { $0.sample.pid == pid }), rows[i].hasChildren else { return }
        if collapsed.contains(pid) {
            collapsed.remove(pid)
        } else if i + 1 < rows.count {
            select(rows[i + 1].sample.pid)
        }
    }

    func toggleCollapsed(_ pid: pid_t) {
        if collapsed.contains(pid) { collapsed.remove(pid) } else { collapsed.insert(pid) }
    }

    func moveSelection(_ delta: Int) {
        let list = showsTree ? treeRows.map(\.sample) : rows
        guard !list.isEmpty else { return }
        let index = selectedPID.flatMap { pid in list.firstIndex { $0.pid == pid } } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(index + delta, 0), list.count - 1)
        select(list[next].pid)
    }

    // MARK: Export

    func csv() -> String {
        var out = "pid,ppid,name,user,cpu_percent,rss_bytes,threads,cpu_time_s,source\n"
        for p in rows {
            let name = "\"" + p.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            out += "\(p.pid),\(p.ppid.map(String.init) ?? ""),\(name),\(p.user ?? ""),\(p.cpuPercent.map { String(format: "%.2f", $0) } ?? ""),\(p.residentBytes.map(String.init) ?? ""),\(p.threadCount.map(String.init) ?? ""),\(p.cpuTimeSeconds.map { String(format: "%.2f", $0) } ?? ""),\(p.source.rawValue)\n"
        }
        return out
    }

    // MARK: AI analysis (uses only locally measured, bounded observations)

    func analyze(_ q: String? = nil) {
        guard let app, let snapshot, !isAnalyzing else { return }
        let text = (q ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = text
        isAnalyzing = true
        analysis = ""
        analysisError = nil
        analysisDisclosure = "Sent to NVIDIA: your question and a summary of current measurements (top 8 processes by CPU and memory with names, pids and numbers; system CPU, memory, load)."
        analysisTask = Task {
            let top = snapshot.processes.filter { $0.cpuPercent != nil }.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(12)
            var trends: [MonitorObservations.ProcessTrend] = []
            for p in top {
                if let t = MonitorObservations.trend(pid: p.pid, name: p.name, history: await app.monitorService.cpuHistory(for: p.pid)) { trends.append(t) }
            }
            let summary = MonitorObservations.summary(snapshot, trends: trends)
            let stream = OrderedTextStream { [weak self] in self?.analysis += $0 }
            do {
                _ = try await app.llm.analyzeSystem(question: text, observations: summary, onDelta: stream.onDelta)
            } catch {
                analysisError = error.localizedDescription
            }
            await stream.finish()
            isAnalyzing = false
        }
    }

    func cancelAnalysis() { analysisTask?.cancel() }

    // MARK: Explain a process with AI (facts only)

    private(set) var processExplanations: [pid_t: String] = [:]
    private(set) var explainingPID: pid_t?
    private(set) var processExplainError: String?

    func explainProcess(_ p: ProcessSample) {
        guard let app, explainingPID == nil else { return }
        explainingPID = p.pid
        processExplainError = nil
        processExplanations[p.pid] = ""
        let parent = p.ppid.map { ProcessSampler.name(for: $0) } ?? ""
        let facts = """
        name: \(p.name)
        path: \(p.path.map { Redactor().redact($0) } ?? "not visible")
        user: \(p.user ?? "unknown")
        parent: \(parent.isEmpty ? "unknown" : parent)
        cpu: \(p.cpuPercent.map { String(format: "%.1f%% of one core", $0) } ?? "unknown")
        memory: \(p.residentBytes.map(MonitorObservations.bytes) ?? "unknown")
        threads: \(p.threadCount.map(String.init) ?? "unknown")
        running since: \(p.startTime?.formatted() ?? "unknown")
        """
        let pid = p.pid
        let stream = OrderedTextStream { [weak self] in self?.processExplanations[pid, default: ""] += $0 }
        Task {
            do {
                _ = try await app.llm.explainProcess(facts: facts, onDelta: stream.onDelta)
            } catch {
                processExplainError = error.localizedDescription
            }
            await stream.finish()
            explainingPID = nil
        }
    }

    func clearAnalysis() {
        analysisTask?.cancel()
        analysis = ""
        analysisError = nil
        question = ""
    }
}

extension ProcessSample {
    /// Non-optional keys for Table sorting (unknown values sort last in descending order).
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memorySortKey: UInt64 { residentBytes ?? 0 }
    var threadSortKey: Int { threadCount ?? -1 }
    var userSortKey: String { user ?? "" }
    var nameSortKey: String { name.lowercased() }
    var pidSortKey: Int32 { pid }
}
