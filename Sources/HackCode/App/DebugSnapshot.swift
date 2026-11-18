#if DEBUG || SNAPSHOT_HARNESS
import SwiftUI
import AppKit
import HackCodeKit

/// Debug-only visual verification: drives real workflows and renders the app's own windows to PNG.
/// Enabled with HACKCODE_SNAPSHOT_DIR=/path ; never compiled into release builds.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ app: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["HACKCODE_SNAPSHOT_DIR"] else { return }
        let live = ProcessInfo.processInfo.environment["HACKCODE_SNAPSHOT_LIVE_AI"] == "1"
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so progress is visible when redirected to a file
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func shot(_ name: String) async { await capture(name, dir: dir) }
            func waitUntil(_ timeout: Double, _ cond: @MainActor () -> Bool) async { await wait(timeout, cond) }
            func log(_ s: String) { print("SNAP: \(s)") }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApp.windows.first?.setContentSize(NSSize(width: 1320, height: 840))
            if ProcessInfo.processInfo.environment["HACKCODE_PERF"] == "1" {
                await perf(app, log: log)
                NSApp.terminate(nil)
                return
            }
            await shot("01-sysadmin-empty")
            // "/" dropdown: full list, then filtered, with keyboard selection moved.
            // Scripted input: drop first responder so the field editor does not write its old text back.
            NSApp.windows.forEach { $0.makeFirstResponder(nil) }
            app.sysAdmin.input = "/"
            app.sysAdmin.inputChanged()
            await shot("01b-slash-all")
            app.sysAdmin.input = "/net"
            app.sysAdmin.inputChanged()
            app.sysAdmin.moveSlashSelection(1)
            await shot("01c-slash-filter")
            log("slash: \(app.sysAdmin.slashCatalog.count) commands, '/net' → \(app.sysAdmin.slashMatches.map(\.id).joined(separator: " "))")
            app.sysAdmin.input = "/files.largest path="
            app.sysAdmin.inputChanged()
            await shot("01d-arg-hint")
            // Shorthand execution through the dropdown path: "/system.overview".
            app.sysAdmin.input = "/system.overview"
            app.sysAdmin.submit()
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(15) { app.sysAdmin.newestPending == nil && !runningAny(app) }
            app.sysAdmin.input = ""

            // Offline path: /run works without the model.
            app.sysAdmin.input = "/run process.top_cpu limit=8"
            app.sysAdmin.submit()
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(15) { app.sysAdmin.newestPending == nil && !runningAny(app) }
            app.sysAdmin.input = "/run files.move_to_trash path=~/Documents"
            app.sysAdmin.submit()
            await shot("02-sysadmin-offline-run")

            // Runbook + RUN ALL (offline, read-only).
            app.sysAdmin.clear()
            app.sysAdmin.input = "/runbook health"
            app.sysAdmin.submit()
            app.sysAdmin.runAllPending()
            await waitUntil(60) { app.sysAdmin.pendingWithoutApproval.isEmpty && !runningAny(app) }
            await shot("02b-runbook-health")
            app.sysAdmin.clear()
            app.sysAdmin.input = "/run security.quarantine_info path=~/Downloads/Claude.dmg"
            app.sysAdmin.submit()
            app.sysAdmin.input = "/run network.reachability host=apple.com count=2"
            app.sysAdmin.submit()
            app.sysAdmin.input = "/run system.hardware"
            app.sysAdmin.submit()
            app.sysAdmin.runAllPending()
            await waitUntil(60) { app.sysAdmin.pendingWithoutApproval.isEmpty && !runningAny(app) }
            await shot("02c-new-operations")
            app.sysAdmin.showPalette = true
            await shot("02d-palette")
            app.sysAdmin.showPalette = false
            // Reverse history search + recent commands in the dropdown.
            NSApp.windows.forEach { $0.makeFirstResponder(nil) }
            app.sysAdmin.beginHistorySearch()
            app.sysAdmin.input = "runbook"
            app.sysAdmin.historySearchChanged()
            await shot("02e-reverse-search")
            log("reverse-search match: \(app.sysAdmin.searchMatch?.line ?? "none")")
            app.sysAdmin.cancelHistorySearch()
            app.sysAdmin.input = "/"
            app.sysAdmin.inputChanged()
            await shot("02f-slash-recent")
            log("recent: \(app.sysAdmin.recentSlashCommands.joined(separator: ", ")) | top of list: \(app.sysAdmin.slashMatches.prefix(4).map(\.id).joined(separator: ", "))")
            app.sysAdmin.input = ""
            // /watch: live re-run with change highlighting; modifying operations are refused.
            app.sysAdmin.clear()
            app.sysAdmin.input = "/watch process.top_cpu limit=6 every=2"
            app.sysAdmin.submit()
            app.sysAdmin.input = "/watch files.move_to_trash path=~/Downloads/x every=5"
            app.sysAdmin.submit()
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await shot("02g-watch")
            if let w = app.sysAdmin.entries.compactMap({ if case .watch(let w) = $0.kind { return w }; return nil }).first {
                log("watch: runs=\(w.runs) changed=\(w.changed.count) running=\(w.isRunning)")
            }
            app.sysAdmin.interrupt()
            log("after ^C: active watches=\(app.sysAdmin.activeWatches.count)")
            // Colour themes.
            app.sysAdmin.input = "/watch files.move_to_trash path=~/Downloads/x"
            app.sysAdmin.submit()
            for theme in ["amber", "cyan", "mono"] {
                app.sysAdmin.input = "/theme \(theme)"
                app.sysAdmin.submit()
                await shot("02h-theme-\(theme)")
            }
            app.update { $0.terminalTheme = "green" }
            // STORAGE explorer.
            app.destination = .storage
            app.storage.open("~/Library/Caches")
            try? await Task.sleep(nanoseconds: 600_000_000)
            await shot("02i-storage-scanning")
            await waitUntil(90) { !app.storage.isScanning }
            app.storage.selectedPath = app.storage.entries.first?.path
            await shot("02j-storage")
            log("storage: \(app.storage.entries.count) entries, total \(ByteFormat.string(app.storage.totalBytes, .file)), largest \(app.storage.entries.first?.name ?? "-")")
            app.storage.viewMode = .map
            await shot("02j2-storage-map")
            app.storage.viewMode = .apps
            await waitUntil(60) { !app.storage.appsScanning && !app.storage.apps.isEmpty }
            let byArch = Dictionary(grouping: app.storage.apps, by: \.architecture).mapValues(\.count)
            log("apps: \(app.storage.apps.count) · \(byArch.map { "\($0.key.rawValue)=\($0.value)" }.sorted()) · intel: \(app.storage.apps.filter { $0.architecture.needsRosetta }.map(\.name).prefix(8))")
            await shot("02j3-storage-apps")
            app.storage.viewMode = .list
            app.storage.open("~/.ssh")
            log("storage protected: \(app.storage.error ?? "opened")")
            app.destination = .sysAdmin
            // Live AI: process explanation + security briefing.
            if live {
                app.destination = .monitor
                await waitUntil(10) { app.monitor.snapshot != nil }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let finder = app.monitor.snapshot?.processes.first(where: { $0.name == "Finder" }) {
                    app.monitor.select(finder.pid)
                    app.monitor.explainProcess(finder)
                    await waitUntil(60) { app.monitor.explainingPID == nil }
                    log("process explain: \((app.monitor.processExplanations[finder.pid] ?? "").prefix(160).replacingOccurrences(of: "\n", with: " ")) error=\(app.monitor.processExplainError ?? "none")")
                    await shot("02u-process-explain")
                }
                app.destination = .securityAudit
                app.security.runAudit()
                await waitUntil(240) { !app.security.isRunning }
                app.security.generateBriefing()
                await waitUntil(90) { !app.security.isBriefing }
                log("briefing: \(app.security.briefing.prefix(200).replacingOccurrences(of: "\n", with: " ")) error=\(app.security.briefingError ?? "none")")
                await shot("02v-briefing")
                app.destination = .sysAdmin
            }
            // Crash alert → VIEW REPORT on a real, existing report (nothing is written to DiagnosticReports).
            let diag = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
            if let name = (try? FileManager.default.contentsOfDirectory(atPath: diag))?.filter({ $0.hasSuffix(".ips") }).sorted().last {
                app.sysAdmin.clear()
                app.monitor.addAlert(MonitorAlert(level: .warning, key: "crash.\(name)", title: "test crash alert", detail: name, time: Date()))
                app.monitor.viewCrashReport(app.monitor.alerts[0])
                if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
                await waitUntil(15) { !runningAny(app) }
                let out = app.sysAdmin.entries.compactMap { if case .operation(let b) = $0.kind { return b.record?.output }; return nil }.first ?? ""
                log("crash report view: \(out.split(separator: "\n").prefix(3).joined(separator: " | "))")
                await shot("02t-crash-report")
                app.monitor.clearAlerts()
            } else {
                log("crash report view: no .ips reports on this Mac")
            }
            // System report, shortcut sheet, sidebar toggle.
            let report = await app.systemReport()
            try? report.write(toFile: "\(dir)/system-report.md", atomically: true, encoding: .utf8)
            log("report: \(report.count) chars, sections: \(report.split(separator: "\n").filter { $0.hasPrefix("## ") }.joined(separator: ", "))")
            app.showShortcuts = true
            await shot("02r-shortcuts")
            app.showShortcuts = false
            app.showSidebar = false
            await shot("02s-no-sidebar")
            app.showSidebar = true
            // Local pipes.
            app.sysAdmin.clear()
            for line in ["/process.top_cpu limit=40 | grep -i -v helper | sort -rn | head 4", "/ops | grep network", "/ops | sh -c id"] {
                app.sysAdmin.input = line
                app.sysAdmin.submit()
            }
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(20) { !runningAny(app) }
            await shot("02p-pipes")
            // Terminal tabs: independent transcripts.
            app.newTerminal()
            app.sysAdmin.input = "/system.overview"
            app.sysAdmin.submit()
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(15) { !runningAny(app) }
            app.newTerminal()
            app.sysAdmin.input = "/network.port_owner port=5000"
            app.sysAdmin.submit()
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(15) { !runningAny(app) }
            app.selectTerminal(1)
            await shot("02o-tabs")
            log("tabs: \(app.terminals.map { "\($0.tabNumber):\($0.tabTitle):\($0.entries.count)" }.joined(separator: " | ")) active=\(app.activeTerminal)")
            app.closeTerminal(2)
            app.closeTerminal(1)
            log("after close: \(app.terminals.count) tab(s)")
            // Aliases + pinned processes.
            app.sysAdmin.clear()
            for line in ["/alias dl /files.largest path=~/Downloads limit=5", "/alias help /ops", "/dl", "/alias"] {
                app.sysAdmin.input = line
                app.sysAdmin.submit()
            }
            if let op = app.sysAdmin.newestPending { app.sysAdmin.requestRun(op) }
            await waitUntil(30) { !runningAny(app) }
            await shot("02l-alias")
            app.sysAdmin.beginFind()
            NSApp.windows.forEach { $0.makeFirstResponder(nil) }
            app.sysAdmin.findQuery = "jdk-26"
            await shot("02n-find")
            log("find 'jdk-26': \(app.sysAdmin.findMatches.count) matching entries")
            app.sysAdmin.endFind()
            app.update { $0.aliases = [:] }
            app.monitor.togglePin("WindowServer")
            app.monitor.togglePin("Finder")
            app.monitor.togglePin("not-a-real-process")
            app.destination = .monitor
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await shot("02m-pinned")
            app.monitor.treeMode = true
            if let chrome = app.monitor.treeRows.first(where: { $0.hasChildren && $0.depth > 0 && $0.subtreeCount > 3 }) {
                app.monitor.toggleCollapsed(chrome.sample.pid)
                app.monitor.select(chrome.sample.pid)
                log("tree: collapsed \(chrome.sample.name) Σ\(String(format: "%.1f", chrome.subtreeCPU))% over \(chrome.subtreeCount) procs; rows=\(app.monitor.treeRows.count)")
            }
            await shot("02w-tree")
            if let branch = app.monitor.selectedPID {
                var steps: [String] = []
                app.monitor.treeRight(); steps.append("→ expanded=\(!app.monitor.collapsed.contains(branch))")
                app.monitor.treeRight(); try? await Task.sleep(nanoseconds: 100_000_000)
                let child = app.monitor.selectedPID
                steps.append("→ child=\(child.map(String.init) ?? "nil") parentOK=\(app.monitor.snapshot?.processes.first { $0.pid == child }?.ppid == branch)")
                app.monitor.treeLeft(); try? await Task.sleep(nanoseconds: 100_000_000)
                steps.append("← back-to-branch=\(app.monitor.selectedPID == branch)")
                app.monitor.treeLeft(); steps.append("← collapsed=\(app.monitor.collapsed.contains(branch))")
                log("tree keys: " + steps.joined(separator: "; "))
            }
            app.monitor.treeMode = false
            app.monitor.pane = .network
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await shot("02q-network")
            log("network: \(app.monitor.snapshot?.interfaces.map { "\($0.name)(\($0.isUp ? "up" : "down"))" }.joined(separator: ", ") ?? "-")")
            // TRENDS with 30 days of synthetic samples — only ever written into an isolated data dir.
            if ProcessInfo.processInfo.environment["HACKCODE_DATA_DIR"] != nil {
                let now = Date()
                var seeded = TrendLog()
                for h in stride(from: 30 * 24, through: 0, by: -3) {
                    let day = Double(h) / 24
                    let wobble = sin(Double(h) / 7) * 0.4e9
                    seeded.add(TrendSample(time: now.addingTimeInterval(-Double(h) * 3600),
                                           diskFreeBytes: Int64(160e9 + day * 0.9e9 + wobble), diskTotalBytes: Int64(494e9),
                                           swapUsedBytes: UInt64(max(0, 2.2e9 + sin(Double(h) / 20) * 1.1e9)),
                                           memoryUsedFraction: 0.78 + sin(Double(h) / 11) * 0.06,
                                           batteryHealth: 0.925 - (30 - day) * 0.0003, batteryCycles: 140 + Int((30 - day) / 3.4)))
                }
                await app.trendStore.save(seeded)
                await app.reloadTrends()
                app.monitor.trendDays = 30
                app.monitor.pane = .trends
                log("trends: \(app.trends.samples.count) samples; \(TrendForecast.diskSummary(app.trends.within(days: 30)))")
                await shot("02y-trends")
                app.destination = .sysAdmin
                app.sysAdmin.clear()
                NSApp.windows.forEach { $0.makeFirstResponder(nil) }
                app.sysAdmin.input = "/trends"
                app.sysAdmin.submit()
                app.sysAdmin.input = "/recap"
                app.sysAdmin.submit()
                await shot("02zc-trends-cmd")
                app.destination = .monitor
                // A steep decline (20 GB free, −2 GB/day) must raise the forecast alert.
                var steep = TrendLog()
                for h in stride(from: 10 * 24, through: 0, by: -6) {
                    steep.add(TrendSample(time: now.addingTimeInterval(-Double(h) * 3600), diskFreeBytes: Int64(20e9 + Double(h) / 24 * 2e9)))
                }
                await app.trendStore.save(steep)
                await app.reloadTrends()
                app.checkDiskForecast()
                log("forecast alert: \(app.monitor.alerts.first { $0.key == "trend.disk" }.map { "\($0.level.rawValue) \($0.title) — \($0.detail)" } ?? "none")")
                app.checkDiskForecast()
                log("forecast alerts after 2nd check (daily limit): \(app.monitor.alerts.filter { $0.key == "trend.disk" }.count)")
                app.clearTrends()
            }
            // Listener watch: a localhost-only socket opened by this debug process must raise a NOTICE.
            await app.monitor.debugForceListenerCheck()          // prime (no-op if already primed)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            _ = listen(fd, 1)
            await app.monitor.debugForceListenerCheck()
            log("listener watch: bound=\(bound == 0) alerts=\(app.monitor.alerts.filter { $0.key.hasPrefix("listen.") }.map { "\($0.level.rawValue) \($0.title) — \($0.detail)" })")
            close(fd)
            app.monitor.pane = .processes
            log("pinned: \(app.monitor.pinnedStats.map { "\($0.name)=\($0.instances)" }.joined(separator: ", "))")
            app.update { $0.pinnedProcesses = [] }
            // Audit HISTORY with 12 synthetic runs (isolated data dir only).
            if ProcessInfo.processInfo.environment["HACKCODE_DATA_DIR"] != nil {
                let checks = [("firewall", "Application Firewall"), ("filevault", "FileVault Disk Encryption"), ("gatekeeper", "Gatekeeper"),
                              ("sip", "System Integrity Protection"), ("screenlock", "Screen Lock"), ("remote-login", "Remote Login (SSH)"),
                              ("updates", "Automatic Updates"), ("launch-items", "Third-Party Launch Items"), ("sharing", "Sharing Services")]
                for k in 0..<12 {
                    var entries: [String: AuditSummary.Entry] = [:]
                    for (id, title) in checks {
                        var status = "PASS"
                        if id == "firewall" { status = (k < 4 || k >= 9) ? "ISSUE" : "REMEDIATED" }
                        if id == "updates" && (k == 3 || k == 7 || k == 8) { status = "ISSUE" }
                        if id == "launch-items" { status = "OBSERVED" }
                        if id == "sharing" && k == 5 { status = "COULD NOT RUN" }
                        if id == "remote-login" && k < 2 { continue }
                        entries[id] = AuditSummary.Entry(status: status, severity: "MEDIUM", title: title)
                    }
                    let issues = entries.values.filter { $0.status == "ISSUE" }.count
                    await app.historyStore.record(AuditSummary(date: Date().addingTimeInterval(Double(k - 12) * 2 * 86_400), score: 100 - issues * 10, checks: entries))
                }
                app.destination = .securityAudit
                app.security.pane = .history
                await app.security.loadHistory()
                log("audit history: \(app.security.historyRuns.count) runs; matrix top rows \(AuditTimeline.make(app.security.historyRuns).rows.prefix(3).map { "\($0.id)(\($0.flips))" })")
                await shot("02zb-audit-history")
                app.security.clearHistory()
            }
            app.destination = .securityAudit
            app.security.pane = .log
            await app.security.loadLog()
            app.security.logFilter = AuditLogFilter(category: .all, window: .day, query: "-monitor")
            log("audit log: \(app.security.logEvents.count) events, filtered \(app.security.filteredLog.count); counts \(app.security.logCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))")
            await shot("02x-audit-log-filter")
            app.security.logFilter = AuditLogFilter()
            app.security.pane = .findings
            app.destination = .sysAdmin
            NSApp.windows.forEach { $0.makeFirstResponder(nil) }
            app.sysAdmin.input = "/flg"
            app.sysAdmin.inputChanged()
            await shot("02k-fuzzy")
            log("fuzzy '/flg': \(app.sysAdmin.slashMatches.prefix(3).map(\.id).joined(separator: ", "))")
            app.sysAdmin.input = ""
            // Open Quickly: rank, capture, then open the best process match.
            app.showQuickOpen = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            let ranked = QuickOpen.rank(app.quickOpenItems(), query: "windowserver", limit: 5)
            log("quick open 'windowserver': \(ranked.map { "\($0.kind.rawValue):\($0.title)" })")
            await shot("02zd-quick-open")
            if let first = ranked.first {
                app.openQuickItem(first)
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("quick open → destination=\(app.destination.rawValue) selected=\(app.monitor.selectedProcess?.name ?? "nil") sheet=\(app.showQuickOpen)")
            }
            let fw = QuickOpen.rank(app.quickOpenItems(), query: "trends", limit: 3)
            log("quick open 'trends': \(fw.map { "\($0.kind.rawValue):\($0.title)" })")
            app.destination = .sysAdmin
            // Menu bar extra (rendered in its own window) and the Markdown system report.
            do {
                let host = NSHostingView(rootView: MenuBarView().environment(app))
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: host.fittingSize.width, height: host.fittingSize.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: .darkAqua)
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/02ze-menubar.png"))
                }
                window.orderOut(nil)
                let report = await app.systemReport()
                log("report sections: \(report.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) })")
            }
            // Settings backup: export, then import a crafted file (isolated data dir only) and log the confirmation text.
            if let dataDir = ProcessInfo.processInfo.environment["HACKCODE_DATA_DIR"] {
                let before = app.settings
                let crafted: [String: Any] = ["format": "hackcode-settings", "version": 1, "settings": [
                    "baseURL": "https://attacker.example/v1", "terminalTheme": "amber", "shareProcessSnapshotWithModel": true,
                    "aliases": ["dl": "/files.largest path=~/Downloads", "run": "/x"]]]
                let url = URL(fileURLWithPath: dataDir).appendingPathComponent("crafted-settings.json")
                try? JSONSerialization.data(withJSONObject: crafted).write(to: url)
                let exported = (try? SettingsTransfer.export(app.settings)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                log("settings export: \(exported.count) bytes, endpoint included=\(exported.contains("baseURL"))")
                do {
                    let r = try app.prepareImport(from: url)
                    log("settings import summary: \(PrivacySettings.importSummary(r).replacingOccurrences(of: "\n\n", with: " | "))")
                    app.applyImport(r)
                    log("after import: theme=\(app.settings.terminalTheme) baseURL=\(app.settings.baseURL) aliases=\(app.settings.aliases.keys.sorted())")
                } catch { log("settings import failed: \(error.localizedDescription)") }
                let host = NSHostingView(rootView: PrivacySettings().environment(app).preferredColorScheme(.dark).frame(width: 640, height: 900))
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: .darkAqua)
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/02z-settings-backup.png"))
                }
                window.orderOut(nil)
                app.update { $0 = before }
            }
            if ProcessInfo.processInfo.environment["HACKCODE_SNAPSHOT_QUICK"] == "1" {
                log("done")
                NSApp.terminate(nil)
                return
            }

            if live {
                app.sysAdmin.clear()
                app.sysAdmin.input = "Find the largest files in my Downloads folder"
                app.sysAdmin.submit()
                await waitUntil(90) { !app.sysAdmin.isThinking }
                await shot("03-sysadmin-ai-plan")
                if let op = app.sysAdmin.newestPending, !op.operation.requiresConfirmation {
                    app.sysAdmin.requestRun(op)
                    await waitUntil(90) { op.phase == .finished }
                    app.sysAdmin.explain(op)
                    await waitUntil(90) { !op.isExplaining }
                    log("explanation chars \(op.explanation.count) error \(op.explainError ?? "none")")
                }
                await shot("04-sysadmin-ai-explained")

                app.sysAdmin.clear()
                app.sysAdmin.input = "Kill the process using the most memory and delete my Downloads folder"
                app.sysAdmin.submit()
                await waitUntil(90) { !app.sysAdmin.isThinking }
                await shot("05-sysadmin-ai-risky")
            }

            app.destination = .monitor
            await waitUntil(10) { app.monitor.snapshot != nil }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            app.monitor.select(app.monitor.rows.first?.pid)
            await shot("06-monitor")
            // Self-cost measurement (CPU time of this process / wall time) in three states.
            func cpuSeconds() -> Double {
                var r = rusage(); getrusage(RUSAGE_SELF, &r)
                return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
            }
            func measure(_ label: String, seconds: Double = 12) async {
                let c0 = cpuSeconds(), t0 = Date()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                log(String(format: "self-cost %@: %.1f%% of one core", label, (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100))
            }
            await measure("MONITOR sampling every \(Int(app.settings.monitorIntervalSeconds)) s")
            app.monitor.toggleRunning()
            await measure("MONITOR paused")
            app.monitor.toggleRunning()
            app.destination = .sysAdmin
            await measure("SYS.ADMIN idle, matrix rain on")
            app.update { $0.matrixRain = false }
            await measure("SYS.ADMIN idle, matrix rain off")
            app.update { $0.matrixRain = true }
            app.update { $0.backgroundMonitoring = true }
            await measure("background sampling, MONITOR hidden")
            app.update { $0.backgroundMonitoring = false }
            app.destination = .monitor
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if live {
                app.monitor.analyze("Why is CPU usage high?")
                await waitUntil(90) { !app.monitor.isAnalyzing }
                log("analysis chars \(app.monitor.analysis.count) error \(app.monitor.analysisError ?? "none")")
                await shot("07-monitor-analysis")
            }

            app.destination = .securityAudit
            app.security.runAudit()
            await waitUntil(240) { !app.security.isRunning }
            app.security.runAudit()
            await waitUntil(240) { !app.security.isRunning }
            for f in app.security.findings { log("finding \(f.checkID) \(f.status.rawValue) \(f.severity.label) — \(f.statusNote ?? "")") }
            if let fw = app.security.findings.first(where: { $0.checkID == "firewall" }) { app.security.selectedID = fw.id }
            await shot("08-security-audit")
            if live, let f = app.security.selected {
                app.security.explain(f)
                await waitUntil(90) { !app.security.explaining.contains(f.id) }
                await shot("09-security-explained")
            }
            if let f = app.security.selected, f.remediation != nil {
                app.security.previewRemediation(f)
                await shot("10-remediation-preview")
                app.security.dismissPreview(approved: false)
            }
            app.security.pane = .log
            await app.security.loadLog()
            await shot("11-audit-log")
            app.security.pane = .findings
            // Settings: render each tab in its own window (the Settings scene can't be opened from a bare binary).
            let tabs: [(String, AnyView)] = [("model", AnyView(ModelSettings())), ("monitor", AnyView(MonitorSettings())),
                                             ("privacy", AnyView(PrivacySettings())), ("permissions", AnyView(PermissionsGuide()))]
            for (name, view) in tabs {
                let host = NSHostingView(rootView: view.environment(app).preferredColorScheme(.dark).frame(width: 640, height: 720))
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: .darkAqua)
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/12-settings-\(name).png"))
                }
                window.orderOut(nil)
            }
            print("SNAPSHOT 12-settings")
            log("done")
            NSApp.terminate(nil)
        }
    }

    /// CPU cost per screen: this process's user+system time over a window, as % of one core.
    static func cpuPercent(over seconds: Double) async -> Double {
        func used() -> Double {
            var r = rusage()
            getrusage(RUSAGE_SELF, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        let a = used(), t = Date()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        lastPerfWall = Date().timeIntervalSince(t)
        return (used() - a) / lastPerfWall * 100
    }
    static var lastPerfWall: Double = 0

    static func perf(_ app: AppModel, log: (String) -> Void) async {
        let window = Double(ProcessInfo.processInfo.environment["HACKCODE_PERF_SECONDS"] ?? "15") ?? 15
        func measure(_ label: String, settle: Double = 4, _ setup: () -> Void) async {
            setup()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
            let ticksBefore = app.monitor.debugTicks
            let cpu = await cpuPercent(over: window)
            log(String(format: "perf %-22@ %5.1f%%  wall %.1fs  monitor ticks %d", label as NSString, cpu, lastPerfWall, app.monitor.debugTicks - ticksBefore))
        }
        if let hold = ProcessInfo.processInfo.environment["HACKCODE_PERF_HOLD"] {
            app.destination = .monitor
            app.monitor.pane = hold == "trends" ? .trends : .processes
            app.monitor.treeMode = hold == "tree"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            log("hold start pid=\(getpid())")
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            log("done")
            return
        }
        await measure("sysadmin (rain)") { app.destination = .sysAdmin }
        await measure("sysadmin (no rain)") { app.update { $0.matrixRain = false } }
        app.update { $0.matrixRain = true }
        await measure("monitor processes", settle: 6) { app.destination = .monitor; app.monitor.pane = .processes; app.monitor.treeMode = false }
        await measure("monitor tree") { app.monitor.treeMode = true }
        app.monitor.treeMode = false
        await measure("monitor network") { app.monitor.pane = .network }
        await measure("monitor trends") { app.monitor.pane = .trends }
        app.monitor.pane = .processes
        await measure("security audit") { app.destination = .securityAudit }
        await measure("storage list", settle: 20) { app.destination = .storage; app.storage.open("~/Library/Caches") }
        await measure("storage map") { app.storage.viewMode = .map }
        app.storage.viewMode = .list
        log("done")
    }

    static func wait(_ timeout: Double, _ cond: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    static func capture(_ name: String, dir: String) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        let rain = NSApp.windows.compactMap(\.contentView).flatMap { MatrixRainNSView.all(in: $0) }
        rain.forEach { $0.debugFreeze() }
        defer { rain.forEach { $0.debugResume() } }
        for (i, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
            guard let view = window.contentView, view.bounds.width > 50 else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let suffix = i == 0 ? "" : "-w\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)\(suffix).png"))
        }
        print("SNAPSHOT \(name)")
    }

    private static func runningAny(_ app: AppModel) -> Bool {
        app.sysAdmin.entries.contains { if case .operation(let b) = $0.kind { return b.phase == .running }; return false }
    }
}
#endif
