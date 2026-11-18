import SwiftUI
import Observation
import UserNotifications
import HackCodeKit

enum Destination: String, CaseIterable, Identifiable {
    case sysAdmin = "SYS.ADMIN"
    case monitor = "MONITOR"
    case securityAudit = "SECURITY AUDIT"
    case storage = "STORAGE"

    var id: String { rawValue }
    var index: String {
        switch self {
        case .sysAdmin: return "01"
        case .monitor: return "02"
        case .securityAudit: return "03"
        case .storage: return "04"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .sysAdmin: return "1"
        case .monitor: return "2"
        case .securityAudit: return "3"
        case .storage: return "4"
        }
    }
    var subtitle: String {
        switch self {
        case .sysAdmin: return "AI administration terminal"
        case .monitor: return "Live activity & resources"
        case .securityAudit: return "Defensive local audit"
        case .storage: return "Disk usage explorer"
        }
    }
}

/// Composition root: owns every service and the per-module view models, so state survives navigation.
@MainActor
@Observable
final class AppModel {
    var destination: Destination = .sysAdmin
    var showSidebar = true
    var showShortcuts = false
    var showQuickOpen = false
    private(set) var settings: HackCodeSettings
    private(set) var hasAPIKey: Bool
    var modelStatus: ModelStatus = .unknown

    enum ModelStatus: Equatable {
        case unknown, missingKey, ok(String), failed(String)
    }

    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let credentials: CredentialStore
    @ObservationIgnored let auditLog: AuditLogService
    @ObservationIgnored let runner: ProcessRunning
    @ObservationIgnored let sampler: ProcessSampler
    @ObservationIgnored let monitorService: SystemMonitor
    @ObservationIgnored let auditService: SecurityAuditService
    @ObservationIgnored let registry: OperationRegistry
    @ObservationIgnored let policy: ExecutionPolicy
    @ObservationIgnored let executor: CommandExecutor
    @ObservationIgnored let llm: LLMService
    @ObservationIgnored let historyStore: AuditHistoryStore
    @ObservationIgnored let commandHistoryStore: CommandHistoryStore
    @ObservationIgnored let trendStore: TrendStore
    @ObservationIgnored private var trendTask: Task<Void, Never>?
    /// Long-term disk / battery / memory samples (hourly, 180 days) for MONITOR › TRENDS.
    private(set) var trends = TrendLog()
    /// "Since last session" summary for the SYS.ADMIN banner (nil when the gap is short or there is no history).
    var sessionRecap: SessionRecap?
    /// The recap computed at launch; kept after DISMISS so /recap can show it again.
    private(set) var lastRecap: SessionRecap?
    @ObservationIgnored private let settingsBox: SettingsBox
    @ObservationIgnored private var autoAuditTask: Task<Void, Never>?
    @ObservationIgnored private var crashWatchTask: Task<Void, Never>?

    /// Terminal tabs; `sysAdmin` is the active one (everything that stages work targets the visible tab).
    private(set) var terminals: [SysAdminViewModel] = []
    var activeTerminal = 0
    var sysAdmin: SysAdminViewModel { terminals[min(activeTerminal, terminals.count - 1)] }
    @ObservationIgnored private var nextTabNumber = 2
    let sharedHistory: SharedHistory
    let monitor: MonitorViewModel
    let security: SecurityAuditViewModel
    let storage: StorageViewModel
    let pulse: SystemPulse

    init(settingsStore: SettingsStore = UserDefaultsSettingsStore(), credentials: CredentialStore = KeychainCredentialStore()) {
        self.settingsStore = settingsStore
        self.credentials = credentials
        let loaded = settingsStore.load()
        self.settings = loaded
        Theme.palette = TerminalPalette(rawValue: loaded.terminalTheme) ?? .green
        self.hasAPIKey = credentials.hasAPIKey
        let box = SettingsBox(loaded)
        self.settingsBox = box

        // Snapshot/debug runs can redirect on-disk data (audit log, history) so tests never touch real records.
        let dataDir = Self.overrideDataDirectory()
        auditLog = AuditLogService(fileURL: dataDir.map { $0.appendingPathComponent("audit-log.jsonl") } ?? AuditLogService.defaultURL())
        runner = SystemProcessRunner()
        sampler = ProcessSampler(runner: runner)
        monitorService = SystemMonitor(sampler: ProcessSampler(runner: runner), historyLength: loaded.monitorHistoryLength)
        auditService = SecurityAuditService(registry: .standard(), runner: runner, auditLog: auditLog)
        registry = .standard(OperationDependencies(sampler: sampler, audit: auditService))
        policy = ExecutionPolicy(registry: registry, paths: .standard())
        executor = CommandExecutor(policy: policy, runner: runner, auditLog: auditLog)
        llm = LLMService(credentials: credentials, settings: { box.value }, auditLog: auditLog)
        historyStore = AuditHistoryStore(url: dataDir.map { $0.appendingPathComponent("audit-history.json") } ?? AuditHistoryStore.defaultURL())
        commandHistoryStore = CommandHistoryStore(url: dataDir.map { $0.appendingPathComponent("command-history.json") } ?? CommandHistoryStore.defaultURL())
        trendStore = TrendStore(url: dataDir.map { $0.appendingPathComponent("trends.json") } ?? TrendStore.defaultURL())

        sharedHistory = SharedHistory(store: commandHistoryStore, shouldPersist: { box.value.persistHistory })
        monitor = MonitorViewModel()
        security = SecurityAuditViewModel()
        storage = StorageViewModel()
        pulse = SystemPulse()
        let first = SysAdminViewModel()
        first.attach(self)
        terminals = [first]
        monitor.attach(self)
        security.attach(self)
        storage.attach(self)
        if !hasAPIKey { modelStatus = .missingKey }
        monitor.applyThresholds(loaded.alertThresholds)
        scheduleAutoAudit()
        monitor.restartLoop()
        Task { await sharedHistory.load() }
        startCrashWatcher()
        startTrendRecorder()
        Task { await security.loadHistory() }
    }

    /// Takes a trend sample at launch and then at most hourly while the app runs (statfs/host_statistics/IOKit only).
    func startTrendRecorder() {
        guard trendTask == nil else { return }
        trendTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let sample = TrendSample.current()
                if first {
                    first = false
                    let previous = await self.trendStore.load().samples
                    let lastAudit = await self.historyStore.all().last
                    let since = previous.last?.time ?? Date()
                    let crashes = await Task.detached { CrashReportWatcher.standard().reports(since: since) }.value
                    self.sessionRecap = SessionRecap.make(previous: previous, current: sample, crashes: crashes, lastAudit: lastAudit)
                    self.lastRecap = self.sessionRecap
                }
                self.trends = await self.trendStore.record(sample)
                self.checkDiskForecast()
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            }
        }
    }

    func reloadTrends() async { trends = await trendStore.load() }

    @ObservationIgnored private var lastForecastAlert: Date?

    /// Alerts (at most daily) when the 14-day trend projects the boot disk full within 14 days.
    func checkDiskForecast(now: Date = Date()) {
        guard let days = TrendForecast.diskFullWithin(trends.samples, now: now) else { return }
        if let last = lastForecastAlert, now.timeIntervalSince(last) < 86_400 { return }
        lastForecastAlert = now
        let n = max(1, Int(days.rounded()))
        let title = "Disk projected full in ~\(n) day\(n == 1 ? "" : "s")"
        let detail = TrendForecast.diskSummary(trends.within(days: 14, now: now)) + " See MONITOR › TRENDS; STORAGE shows what is large."
        monitor.addAlert(MonitorAlert(level: days < 3 ? .critical : .warning, key: "trend.disk", title: title, detail: detail, time: now))
        notify(title, "Based on the last two weeks of free-space samples.")
        Task { await auditLog.record(AuditEvent(kind: .monitorAlert, operation: "monitor.trend.disk", outcome: days < 3 ? "critical" : "warning", detail: title)) }
    }

    // MARK: Settings backup

    func exportSettings() -> Bool {
        guard let data = try? SettingsTransfer.export(settings) else { return false }
        return saveTextFile(String(decoding: data, as: UTF8.self), suggestedName: "hackcode-settings-\(timestampForFile()).json")
    }

    /// Reads and validates a settings file; nothing is applied until `applyImport`.
    func prepareImport(from url: URL) throws -> SettingsTransfer.ImportResult {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SettingsTransfer.maxBytes else { throw SettingsTransfer.ImportError.tooLarge }
        return try SettingsTransfer.importSettings(Data(contentsOf: url), into: settings, reservedAliasNames: sysAdmin.reservedAliasNames)
    }

    func applyImport(_ r: SettingsTransfer.ImportResult) {
        update { $0 = r.settings }
        Task { await auditLog.record(AuditEvent(kind: .settingsChanged, outcome: "imported",
                                                detail: "imported from file: \(r.changedKeys.count) setting(s); skipped aliases: \(r.skippedAliases.count)")) }
    }

    func clearTrends() {
        Task {
            await trendStore.clear()
            trends = TrendLog()
            await auditLog.record(AuditEvent(kind: .historyCleared, outcome: "cleared", detail: "trend samples cleared by user"))
        }
    }

    /// Every 30 s, list the DiagnosticReports folders (metadata only) and alert on new crash / hang / panic reports.
    func startCrashWatcher() {
        guard crashWatchTask == nil else { return }
        crashWatchTask = Task { [weak self] in
            var watcher = CrashReportWatcher.standard()
            _ = watcher.check()     // prime: existing reports are not news
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                let fresh = watcher.check()
                guard let self, !fresh.isEmpty else { continue }
                for r in fresh {
                    let alert = MonitorAlert(level: r.kind == "kernel panic" ? .critical : .warning, key: "crash.\(r.name)",
                                             title: "\(r.app) \(r.kind)", detail: "New \(r.systemWide ? "system" : "user") report \(r.name).",
                                             time: r.date)
                    self.monitor.addAlert(alert)
                    self.notify("HackCode · \(r.app) \(r.kind)", "A new diagnostic report was written. Open MONITOR to read it.")
                    await self.auditLog.record(AuditEvent(kind: .monitorAlert, operation: "monitor.crash", outcome: r.kind, detail: r.app))
                }
            }
        }
    }

    // MARK: System report

    /// Markdown health report from data HackCode has already collected locally (no extra commands run).
    func systemReport() async -> String {
        let snap: MonitorSnapshot
        if let latest = monitor.snapshot { snap = latest } else {
            _ = await monitorService.collect()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            snap = await monitorService.collect()
        }
        let pi = ProcessInfo.processInfo
        var md = "# HackCode system report\n\nGenerated \(Date().formatted(date: .complete, time: .standard)) on this Mac.\n\n"
        md += "## Overview\n\n| | |\n|---|---|\n"
        md += "| macOS | \(pi.operatingSystemVersionString) |\n"
        md += "| Model | \(SystemMetrics.sysctlString("hw.model") ?? "?") |\n"
        md += "| CPU | \(SystemMetrics.sysctlString("machdep.cpu.brand_string") ?? "?") · \(pi.activeProcessorCount) cores |\n"
        md += "| Memory | \(MonitorObservations.bytes(pi.physicalMemory)) |\n"
        if let boot = snap.bootTime { md += "| Booted | \(boot.formatted()) |\n" }
        md += "| Thermal | \(snap.thermalState) |\n"
        if let b = snap.battery {
            md += "| Battery | \(b.percent)% \(b.isCharging ? "charging" : (b.onAC ? "on AC" : "on battery"))\(b.cycleCount.map { " · \($0) cycles" } ?? "") |\n"
        }
        md += "\n## Now\n\n"
        md += MonitorObservations.summary(snap, trends: []).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n\n"
        md += "## Volumes\n\n| Volume | Free | Total |\n|---|---|---|\n"
        for v in snap.volumes { md += "| \(v.name) | \(ByteFormat.string(v.availableBytes)) | \(ByteFormat.string(v.totalBytes)) |\n" }
        md += "\n## Network interfaces\n\n| Interface | State | Addresses | Received | Sent |\n|---|---|---|---|---|\n"
        for i in snap.interfaces {
            md += "| \(i.name) | \(i.isUp ? "up" : "down") | \((snap.interfaceAddresses[i.name] ?? []).first ?? "") | \(MonitorObservations.bytes(i.totalIn)) | \(MonitorObservations.bytes(i.totalOut)) |\n"
        }
        if let w = monitor.wifi ?? WiFiMetrics.current() {
            md += "\n## Wi-Fi\n\n"
            if !w.poweredOn { md += "Wi-Fi is off.\n" } else if !w.associated { md += "Not connected.\n" } else {
                md += "| | |\n|---|---|\n"
                md += "| Signal | \(w.rssi) dBm (\(w.quality.rawValue.lowercased())) · noise \(w.noise) dBm · SNR \(w.snr) dB |\n"
                md += "| Link | \(Int(w.transmitRateMbps)) Mbps · \(w.phyMode) |\n"
                md += "| Channel | \([w.channel.map(String.init), w.band, w.channelWidthMHz.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · ")) |\n"
                md += "| Encryption | \(w.security.rawValue) (\(w.security.strength.rawValue.lowercased())) |\n"
            }
        }
        md += "\n## Long-term trends\n\n"
        md += TrendForecast.textReport(trends).split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n"
        md += "\n## Monitor alerts\n\n"
        md += monitor.alerts.isEmpty ? "None in this session.\n" : monitor.alerts.prefix(20).map { "- \($0.time.formatted(date: .omitted, time: .shortened)) **\($0.title)** — \($0.detail)" }.joined(separator: "\n") + "\n"
        md += "\n## Security posture\n\n"
        if security.findings.isEmpty {
            md += "No audit in this session (run /audit).\n"
        } else {
            md += "Score \(security.score.map { "\($0)/100" } ?? "n/a"). Issues:\n\n"
            md += security.allFindingsSorted.filter(\.isActionable).map { "- [\($0.severity.label)] \($0.title): \($0.statusNote ?? "")" }.joined(separator: "\n") + "\n"
        }
        let history = await historyStore.all()
        if history.count > 1 {
            md += "\n## Audit history\n\n| Run | Score | Issues |\n|---|---|---|\n"
            for run in history.suffix(10).reversed() {
                md += "| \(run.date.formatted(date: .abbreviated, time: .shortened)) | \(run.score.map { "\($0)/100" } ?? "—") | \(AuditTimeline.issueCount(run)) |\n"
            }
            let flapping = AuditTimeline.make(history).rows.filter { $0.flips > 0 }.prefix(5)
            if !flapping.isEmpty {
                md += "\nChecks whose result changed between runs: " + flapping.map { "\($0.title) (\($0.flips)×)" }.joined(separator: ", ") + ".\n"
            }
        }
        md += "\n---\nCollected locally by HackCode; nothing in this report was sent anywhere.\n"
        return Redactor().redact(md)
    }

    // MARK: Terminal tabs

    func newTerminal() {
        let tab = SysAdminViewModel(tabNumber: nextTabNumber, conversationID: UUID().uuidString)
        nextTabNumber += 1
        tab.attach(self)
        terminals.append(tab)
        activeTerminal = terminals.count - 1
        destination = .sysAdmin
        tab.focusRequest += 1
    }

    /// Closes a tab: stops its work and forgets its AI conversation. The last tab cannot be closed.
    func closeTerminal(_ index: Int? = nil) {
        let i = index ?? activeTerminal
        guard terminals.count > 1, terminals.indices.contains(i) else { return }
        let tab = terminals[i]
        tab.cancelActive()
        let conversation = tab.conversationID
        Task { await llm.forget(conversation: conversation) }
        terminals.remove(at: i)
        activeTerminal = min(activeTerminal > i ? activeTerminal - 1 : activeTerminal, terminals.count - 1)
    }

    func selectTerminal(_ index: Int) {
        guard terminals.indices.contains(index) else { return }
        activeTerminal = index
        destination = .sysAdmin
        sysAdmin.focusRequest += 1
    }

    func cycleTerminal(_ delta: Int) {
        guard terminals.count > 1 else { return }
        selectTerminal((activeTerminal + delta + terminals.count) % terminals.count)
    }

    private static func overrideDataDirectory() -> URL? {
        #if DEBUG || SNAPSHOT_HARNESS
        if let dir = ProcessInfo.processInfo.environment["HACKCODE_DATA_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        return nil
    }

    /// True while something is working (AI request, operation, audit, analysis) — speeds up the rain.
    var isBusy: Bool {
        terminals.contains { $0.isBusy } || security.isRunning || monitor.isAnalyzing
    }

    // MARK: Background services

    /// Re-runs the read-only audit every N hours while the app is open (setting; off by default).
    func scheduleAutoAudit() {
        autoAuditTask?.cancel()
        let hours = settings.autoAuditHours
        guard hours > 0 else { return }
        autoAuditTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(hours) * 3_600_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.security.runAudit(trigger: .scheduled)
            }
        }
    }

    /// Posts a local notification if the user enabled them. Never includes secrets or command output.
    func notify(_ title: String, _ body: String) {
        // UNUserNotificationCenter requires a real app bundle (bare `swift run` binaries would crash).
        guard settings.notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func requestNotificationPermission() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // MARK: Settings & credentials

    func update(_ change: (inout HackCodeSettings) -> Void) {
        var s = settings
        change(&s)
        s.clamp()
        guard s != settings else { return }
        let old = settings
        Theme.palette = TerminalPalette(rawValue: s.terminalTheme) ?? .green
        settings = s
        settingsBox.value = s
        settingsStore.save(s)
        monitor.applyThresholds(s.alertThresholds)
        if old.autoAuditHours != s.autoAuditHours { scheduleAutoAudit() }
        if old.backgroundMonitoring != s.backgroundMonitoring || old.monitorIntervalSeconds != s.monitorIntervalSeconds { monitor.restartLoop() }
        Task { await monitorService.setHistoryLength(s.monitorHistoryLength) }
        let changed = s.changedKeys(from: old)
        let modelChanged = changed.contains("modelID") || changed.contains("enableModelReasoning")
        let detail = "changed: \(changed.joined(separator: ", "))" + (modelChanged ? " · model=\(s.modelID) reasoning=\(s.enableModelReasoning)" : "")
        Task { await auditLog.record(AuditEvent(kind: .settingsChanged, outcome: "saved", detail: detail)) }
    }

    func saveAPIKey(_ key: String) throws {
        try credentials.saveAPIKey(key)
        hasAPIKey = credentials.hasAPIKey
        modelStatus = .unknown
    }

    func deleteAPIKey() throws {
        try credentials.deleteAPIKey()
        hasAPIKey = credentials.hasAPIKey
        modelStatus = .missingKey
    }

    func refreshKeyState() {
        hasAPIKey = credentials.hasAPIKey
        if !hasAPIKey { modelStatus = .missingKey }
    }

    func clearAllSessionData() async {
        terminals.forEach { $0.clear() }
        monitor.clearAnalysis()
        monitor.clearAlerts()
        security.clearSession()
        await sharedHistory.clear()
        await llm.clearAllHistory()
        await llm.clearHistory()
        await auditLog.record(AuditEvent(kind: .historyCleared, outcome: "cleared", detail: "session history cleared by user"))
    }
}

/// Thread-safe holder so non-main services can read the current settings.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HackCodeSettings
    init(_ v: HackCodeSettings) { _value = v }
    var value: HackCodeSettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Cheap system-wide CPU / memory readout for the header (no process sampling).
@MainActor
@Observable
final class SystemPulse {
    private(set) var cpu: Double?
    private(set) var memory: Double?
    private(set) var pressure: String = "—"
    private(set) var battery: BatteryStatus?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var last = SystemMetrics.cpuTicks()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let now = SystemMetrics.cpuTicks()
                let mem = SystemMetrics.memory()
                guard let self else { return }
                if let a = last, let b = now { self.cpu = SystemMetrics.cpuUsage(from: a, to: b)?.busy }
                last = now
                if let mem {
                    self.memory = Double(mem.usedBytes) / Double(max(mem.physicalBytes, 1))
                    self.pressure = mem.pressureLabel
                }
                let battery = PowerMetrics.battery()
                if battery != self.battery { self.battery = battery }
            }
        }
    }
}
