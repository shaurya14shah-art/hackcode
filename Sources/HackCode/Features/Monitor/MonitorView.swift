import SwiftUI
import HackCodeKit

struct MonitorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.monitor
        VStack(spacing: 0) {
            MonitorToolbar()
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if let snap = vm.snapshot {
                VStack(spacing: Theme.Space.m) {
                    if !vm.alerts.isEmpty { AlertStrip() }
                    MetricStrip(snapshot: snap)
                    if !vm.pinned.isEmpty && vm.pane == .processes { PinnedStrip() }
                    if vm.pane == .processes {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            ProcessTable()
                            ProcessDetail()
                                .frame(width: 320)
                        }
                    } else if vm.pane == .network {
                        NetworkPane(snapshot: snap)
                    } else {
                        TrendsPane()
                    }
                    if vm.pane != .trends { AnalysisPanel() }
                }
                .padding(Theme.Space.m)
            } else {
                InlineState(kind: .loading, title: "Collecting first sample…",
                            detail: "CPU percentages need two samples, so the first values appear after one interval.")
                Spacer()
            }
        }
        .onAppear { vm.appeared() }
        .onDisappear { vm.disappeared() }
    }
}

private struct MonitorToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.monitor
        HStack(spacing: Theme.Space.m) {
            Button(vm.isRunning ? "❚❚ PAUSE" : "▶ RESUME") { vm.toggleRunning() }
                .buttonStyle(.term(vm.isRunning ? .quiet : .primary))
                .help("⌘⇧P")
            Button("↻ REFRESH") { vm.refreshNow() }.buttonStyle(.term(.quiet))
            Picker("", selection: Binding(get: { vm.pane }, set: { vm.pane = $0 })) {
                ForEach(MonitorViewModel.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Picker("", selection: Binding(get: { app.settings.monitorIntervalSeconds }, set: { v in app.update { $0.monitorIntervalSeconds = v }; vm.restartLoop() })) {
                ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text("every \(Int($0)) s").tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("Refresh interval")
            Spacer()
            if !vm.alerts.isEmpty {
                Button("⚠ \(vm.alerts.count) ALERT\(vm.alerts.count == 1 ? "" : "S")") { vm.showAlertList.toggle() }
                    .buttonStyle(.term(.warning))
            }
            Menu("EXPORT") {
                Button("Copy process list as CSV") { copyToPasteboard(vm.csv()) }
                Button("Save process list as CSV…") { saveTextFile(vm.csv(), suggestedName: "hackcode-processes-\(timestampForFile()).csv") }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(Theme.Font.label)
            if app.settings.backgroundMonitoring { Tag(text: "BACKGROUND", color: Theme.info).help("Sampling continues while MONITOR is hidden (Settings › Monitor)") }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: Theme.Space.s) {
                    if !vm.isRunning {
                        Tag(text: "PAUSED", color: Theme.amber)
                    } else if vm.isStale(at: ctx.date) {
                        Tag(text: "STALE", color: Theme.red)
                    } else {
                        StatusDot(color: Theme.accent, pulsing: true)
                    }
                    if let s = vm.snapshot, let last = vm.lastUpdate {
                        Text("updated \(Int(ctx.date.timeIntervalSince(last)))s ago · sample \(s.collectionDuration.elapsedString) · \(s.processes.count) processes"
                             + (s.restrictedProcessCount > 0 ? " (\(s.restrictedProcessCount) via ps)" : ""))
                            .font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface.opacity(0.75))
    }
}

// MARK: - Metric tiles

private struct MetricStrip: View {
    let snapshot: MonitorSnapshot

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            cpuTile
            memoryTile
            networkTile
            powerTile
            diskTile
        }
        .frame(height: 104)
    }

    private var cpuTile: some View {
        MetricTile(title: "CPU", value: snapshot.cpu.value.map { String(format: "%.0f%%", $0.busy * 100) } ?? "—",
                   subtitle: {
                       switch snapshot.cpu {
                       case .value(let c): return String(format: "user %.0f%% · sys %.0f%%", c.user * 100, c.system * 100)
                       case .unavailable(let why): return why
                       }
                   }(),
                   footer: snapshot.loadAverages.map { String(format: "load %.2f %.2f %.2f", $0[0], $0[1], $0[2]) },
                   history: snapshot.history.map(\.cpuBusy), maxValue: 1)
    }

    private var memoryTile: some View {
        let m = snapshot.memory.value
        let fraction = m.map { Double($0.usedBytes) / Double(max($0.physicalBytes, 1)) }
        return MetricTile(title: "MEMORY", value: m.map { MonitorObservations.bytes($0.usedBytes) } ?? "—",
                          subtitle: m.map { "of \(MonitorObservations.bytes($0.physicalBytes)) · compressed \(MonitorObservations.bytes($0.compressedBytes))" } ?? "unavailable",
                          footer: m.map { "pressure \($0.pressureLabel) · swap \($0.swapUsedBytes.map(MonitorObservations.bytes) ?? "?")" },
                          history: snapshot.history.map(\.memoryUsedFraction), maxValue: 1,
                          accent: fraction.map(Theme.pressureColor) ?? Theme.accent,
                          alert: m?.pressureLevel ?? 1 > 1)
    }

    private var networkTile: some View {
        let inRate = snapshot.interfaces.reduce(0) { $0 + $1.bytesInPerSecond }
        let outRate = snapshot.interfaces.reduce(0) { $0 + $1.bytesOutPerSecond }
        let fmt = { (v: Double) in ByteFormat.string(Int64(v), .binary) + "/s" }
        return MetricTile(title: "NETWORK", value: "↓ \(fmt(inRate))", subtitle: "↑ \(fmt(outRate))",
                          footer: snapshot.interfaces.prefix(3).map(\.name).joined(separator: " · ") + " · per-process attribution not available",
                          history: snapshot.history.map(\.netInBytesPerSecond), maxValue: nil, accent: Theme.info)
    }

    private var powerTile: some View {
        let b = snapshot.battery
        let thermalHot = snapshot.thermalState == "SERIOUS" || snapshot.thermalState == "CRITICAL"
        return Panel(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text("POWER").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                if let b {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(b.percent)%").font(Theme.Font.metric).monospacedDigit().foregroundStyle(b.percent <= 15 && !b.onAC ? Theme.red : Theme.textPrimary)
                        Text(b.isCharging ? "charging" : (b.onAC ? "on AC" : "battery")).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    }
                    Meter(fraction: Double(b.percent) / 100, color: b.percent <= 15 ? Theme.red : Theme.accent)
                    Text([b.minutesRemaining.map { "\($0 / 60)h\($0 % 60)m left" }, b.health.map { String(format: "health %.0f%%", $0 * 100) }, b.cycleCount.map { "\($0) cycles" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).lineLimit(1)
                } else {
                    Text("AC power").font(Theme.Font.metric).foregroundStyle(Theme.textPrimary)
                    Text("no internal battery").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                }
                Text("thermal \(snapshot.thermalState.lowercased())").font(Theme.Font.micro).foregroundStyle(thermalHot ? Theme.amber : Theme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var diskTile: some View {
        Panel(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 5) {
                Text("STORAGE").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                if snapshot.volumes.isEmpty {
                    Text("unavailable").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                ForEach(snapshot.volumes.prefix(3)) { v in
                    let used = Double(v.totalBytes - v.availableBytes) / Double(max(v.totalBytes, 1))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(v.name).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                            Text("\(ByteFormat.string(v.availableBytes, .file)) free")
                                .font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                        }
                        Meter(fraction: used)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    var footer: String?
    let history: [Double?]
    let maxValue: Double?
    var accent: Color = Theme.accent
    var alert = false

    var body: some View {
        Panel(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    if alert { Tag(text: "PRESSURE", color: Theme.amber) }
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(value).font(Theme.Font.metric).monospacedDigit().foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                    Text(subtitle).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                if let footer { Text(footer).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                Sparkline(values: history, maxValue: maxValue, color: accent)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value), \(subtitle)")
    }
}

// MARK: - Process table

private struct ProcessTable: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.monitor
        let rows = vm.rows
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("⌕").foregroundStyle(Theme.textTertiary)
                TextField("", text: $vm.search, prompt: Text("filter by name, pid or user").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(Theme.Font.caption)
                Picker("", selection: $vm.treeMode) {
                    Text("LIST").tag(false)
                    Text("TREE").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                .help("Tree shows parent/child processes; collapsed branches show Σ subtree totals")
                Picker("", selection: $vm.scope) {
                    ForEach(MonitorViewModel.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            .padding(Theme.Space.s)
            .background(Theme.surfaceRaised)
            HStack(spacing: 0) {
                header(.pid, width: 64, align: .trailing)
                header(.name, width: nil, align: .leading)
                header(.cpu, width: 64, align: .trailing)
                header(.memory, width: 84, align: .trailing)
                header(.threads, width: 46, align: .trailing)
                header(.user, width: 92, align: .leading)
            }
            .font(Theme.Font.micro).tracking(0.8)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if rows.isEmpty {
                InlineState(kind: .empty, title: "No processes match.", detail: vm.search.isEmpty ? nil : "Clear the filter to see all processes.")
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if vm.showsTree {
                                ForEach(vm.treeRows) { row in
                                    ProcessRow(process: row.sample, selected: vm.selectedPID == row.sample.pid, tree: row,
                                               collapsed: vm.collapsed.contains(row.sample.pid)) { vm.toggleCollapsed(row.sample.pid) }
                                        .onTapGesture { vm.select(row.sample.pid) }
                                }
                            } else {
                                ForEach(rows) { p in
                                    ProcessRow(process: p, selected: vm.selectedPID == p.pid)
                                        .onTapGesture { vm.select(p.pid) }
                                }
                            }
                        }
                        // Rows share pids across modes; a fresh stack per mode stops LIST rows being reused in TREE.
                        .id(vm.showsTree)
                    }
                    .onChange(of: vm.selectedPID) { _, pid in
                        if let pid { withAnimation(Motion.quick) { proxy.scrollTo(pid) } }
                    }
                }
            }
        }
        .background(Theme.surface.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { vm.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { vm.moveSelection(1); return .handled }
        .onKeyPress(.leftArrow) { guard vm.showsTree else { return .ignored }; vm.treeLeft(); return .handled }
        .onKeyPress(.rightArrow) { guard vm.showsTree else { return .ignored }; vm.treeRight(); return .handled }
        .accessibilityHint("Arrow keys change the selected process; in tree view, left and right collapse and expand")
    }

    private func header(_ key: MonitorViewModel.SortKey, width: CGFloat?, align: Alignment) -> some View {
        let vm = app.monitor
        let active = vm.sortKey == key
        return Button {
            if active { vm.ascending.toggle() } else { vm.sortKey = key; vm.ascending = key == .name || key == .pid || key == .user }
        } label: {
            Text(key.rawValue + (active ? (vm.ascending ? " ▲" : " ▼") : ""))
                .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: align)
                .frame(width: width, alignment: align)
                .padding(.leading, align == .leading ? 10 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(key.rawValue)")
    }
}

private struct ProcessRow: View {
    let process: ProcessSample
    let selected: Bool
    var tree: ProcessTree.Row? = nil
    var collapsed = false
    var onToggle: (() -> Void)? = nil

    /// "│  │  ├─ " style guides for tree mode.
    private var treePrefix: String {
        guard let tree, tree.depth > 0 else { return "" }
        let guides = tree.continuingAncestors.dropFirst().map { $0 ? "│  " : "   " }.joined()
        return guides + (tree.isLastSibling ? "└─" : "├─")
    }

    private var showSubtree: Bool { collapsed && (tree?.hasChildren ?? false) }

    private var accessibilityText: String {
        var parts = ["\(process.name), pid \(process.pid)"]
        if let tree {
            if tree.depth > 0 { parts.append("level \(tree.depth + 1)") }
            if tree.hasChildren { parts.append(collapsed ? "collapsed, \(tree.subtreeCount - 1) descendants" : "expanded") }
        }
        if showSubtree, let tree {
            parts.append(String(format: "branch CPU %.0f percent", tree.subtreeCPU))
            parts.append("branch memory \(MonitorObservations.bytes(tree.subtreeRSS))")
        } else {
            parts.append("CPU \(process.cpuPercent.map { String(format: "%.0f", $0) } ?? "unknown") percent")
            parts.append("memory \(process.residentBytes.map(MonitorObservations.bytes) ?? "unknown")")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(String(process.pid)).frame(width: 64, alignment: .trailing).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 4) {
                if tree != nil {
                    Text(treePrefix).foregroundStyle(Theme.textTertiary).padding(.trailing, -4)
                    if tree?.hasChildren == true {
                        Button { onToggle?() } label: {
                            Text(collapsed ? "▸" : "▾").foregroundStyle(Theme.accentDim).frame(width: 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(collapsed ? "Expand \(process.name)" : "Collapse \(process.name)")
                    } else {
                        Text(tree?.depth == 0 ? " " : "─").foregroundStyle(Theme.textTertiary).frame(width: 10)
                    }
                }
                Text(process.name).lineLimit(1).foregroundStyle(Theme.textPrimary)
                if showSubtree, let t = tree { Text("+\(t.subtreeCount - 1)").font(Theme.Font.micro).foregroundStyle(Theme.accentDim) }
                if process.source == .ps { Text("ps").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).help("Owned by another user; measured with ps (lower precision)") }
                if process.source == .unavailable { Text("restricted").font(Theme.Font.micro).foregroundStyle(Theme.amber) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
            Text(showSubtree ? String(format: "Σ%.1f", tree?.subtreeCPU ?? 0) : (process.cpuPercent.map { String(format: "%.1f", $0) } ?? "—"))
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(((showSubtree ? tree?.subtreeCPU : process.cpuPercent) ?? 0) > 80 ? Theme.amber : Theme.textPrimary)
            Text(showSubtree ? "Σ" + MonitorObservations.bytes(tree?.subtreeRSS ?? 0) : (process.residentBytes.map(MonitorObservations.bytes) ?? "—"))
                .frame(width: 84, alignment: .trailing).foregroundStyle(Theme.textSecondary)
            Text(process.threadCount.map(String.init) ?? "—").frame(width: 46, alignment: .trailing).foregroundStyle(Theme.textTertiary)
            Text(process.user ?? "?").lineLimit(1).frame(width: 92, alignment: .leading).padding(.leading, 10).foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Font.caption).monospacedDigit()
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
        .background(selected ? Theme.accent.opacity(0.12) : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.accent).frame(width: 2) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        // The ▾/▸ button is inside an element that ignores children, so expose collapse/expand as an action.
        .accessibilityActions {
            if let tree, tree.hasChildren {
                Button(collapsed ? "Expand" : "Collapse") { onToggle?() }
            }
        }
    }
}

// MARK: - Detail

private struct ProcessDetail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.monitor
        Panel {
            // Scrolls on short windows: the detail list must never force the whole layout taller than the window.
            ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionLabel(text: "Process detail")
                if let p = vm.selectedProcess {
                    Text(p.name).font(Theme.Font.title).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    KeyValueRow(key: "pid / ppid", value: "\(p.pid) / \(p.ppid.map(String.init) ?? "—")")
                    KeyValueRow(key: "user", value: p.user ?? "unavailable")
                    KeyValueRow(key: "cpu", value: p.cpuPercent.map { String(format: "%.1f%% of one core", $0) } ?? "needs two samples")
                    KeyValueRow(key: "memory (rss)", value: p.residentBytes.map(MonitorObservations.bytes) ?? "unavailable")
                    KeyValueRow(key: "threads", value: p.threadCount.map(String.init) ?? "unavailable")
                    KeyValueRow(key: "cpu time", value: p.cpuTimeSeconds.map { String(format: "%.1f s", $0) } ?? "unavailable")
                    KeyValueRow(key: "started", value: p.startTime?.formatted(date: .abbreviated, time: .standard) ?? "unavailable")
                    KeyValueRow(key: "path", value: p.path.map { Redactor().redact($0) } ?? "not visible")
                    KeyValueRow(key: "source", value: p.source.rawValue, valueColor: p.source == .libproc ? Theme.textSecondary : Theme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU HISTORY (\(vm.selectedHistory.count) samples)").font(Theme.Font.micro).tracking(0.8).foregroundStyle(Theme.textTertiary)
                        if vm.selectedHistory.count > 1 {
                            Sparkline(values: vm.selectedHistory.map { Optional($0) }, maxValue: max(100, vm.selectedHistory.max() ?? 100))
                                .frame(height: 36)
                        } else {
                            Text("Tracked once the process ranks among the top CPU users.").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    let mine = p.uid == getuid()
                    HStack(spacing: Theme.Space.xs) {
                        Button(vm.isPinned(p.name) ? "UNPIN" : "PIN") { vm.togglePin(p.name) }
                            .buttonStyle(.term(vm.isPinned(p.name) ? .warning : .quiet))
                            .help("Pinned processes stay at the top with history, and alert when they stop or start")
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Button("INSPECT") { vm.stage("process.inspect", pid: p.pid, label: "Inspect \(p.name) (pid \(p.pid))") }
                            .buttonStyle(.term(.primary))
                        Button("TREE") { vm.stage("process.tree", pid: p.pid, label: "Process tree of \(p.name)") }.buttonStyle(.term(.quiet))
                        Button("SIGNATURE") { vm.stage("process.code_signature", pid: p.pid, label: "Verify code signature of \(p.name)") }
                            .buttonStyle(.term(.quiet)).disabled(p.path == nil)
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Button("FILES") { vm.stage("process.open_files", pid: p.pid, label: "Open files of \(p.name)") }
                            .buttonStyle(.term(.quiet)).disabled(!mine).help("lsof only sees your own processes")
                        Button("ERRORS") { vm.stage("logs.process_errors", arguments: ["process": .string(p.name), "minutes": .integer(10)], label: "Recent errors from \(p.name)") }
                            .buttonStyle(.term(.quiet))
                        if let path = p.path {
                            Button("REVEAL") { vm.stage("finder.reveal", arguments: ["path": .string(path)], label: "Reveal \(p.name) in Finder") }
                                .buttonStyle(.term(.quiet))
                        }
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Button("QUIT APP…") { vm.stage("app.quit", pid: p.pid, label: "Quit \(p.name) gracefully") }
                            .buttonStyle(.term(.warning)).disabled(!mine)
                            .help("Asks the app to quit normally (it can prompt to save)")
                        Button("TERMINATE…") { vm.stage("process.terminate", pid: p.pid, label: "Terminate \(p.name) (pid \(p.pid))") }
                            .buttonStyle(.term(.danger)).disabled(!mine)
                            .help(mine ? "Sends SIGTERM after your approval" : "Only your own processes can be terminated")
                    }
                    Text("Actions open in SYS.ADMIN for review; nothing runs until you approve.").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    HStack(spacing: Theme.Space.xs) {
                        Button(vm.explainingPID == p.pid ? "EXPLAINING…" : "WHAT IS THIS? (AI)") { vm.explainProcess(p) }
                            .buttonStyle(.term(.primary))
                            .disabled(!app.hasAPIKey || vm.explainingPID != nil)
                            .help("Sends the name, path (~ for your home), owner and measurements to NVIDIA")
                    }
                    if let text = vm.processExplanations[p.pid], !text.isEmpty {
                        ScrollView { ModelText(text: text).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 180)
                        Text("AI · based on name, path, owner and measurements · may be wrong").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    }
                    if let err = vm.processExplainError, vm.explainingPID == nil, vm.processExplanations[p.pid]?.isEmpty ?? true {
                        Text("✕ \(err)").font(Theme.Font.caption).foregroundStyle(Theme.red)
                    }
                } else {
                    Text("Select a process to see its metadata and recent CPU history.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Analysis

private struct AnalysisPanel: View {
    @Environment(AppModel.self) private var app
    static let prompts = ["Why is CPU usage high?", "Which processes use the most memory?", "Has any process changed significantly?", "What should I investigate next?"]

    var body: some View {
        @Bindable var vm = app.monitor
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text("ASK").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.accent)
                    TextField("", text: $vm.question, prompt: Text("ask about the measurements above").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain).font(Theme.Font.body)
                        .onSubmit { vm.analyze() }
                    if vm.isAnalyzing {
                        Button("CANCEL") { vm.cancelAnalysis() }.buttonStyle(.term(.warning))
                    } else {
                        Button("ANALYZE") { vm.analyze() }.buttonStyle(.term(.primary))
                            .disabled(!app.hasAPIKey || vm.question.isEmpty)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    ForEach(Self.prompts, id: \.self) { p in
                        Button(p) { vm.analyze(p) }.buttonStyle(.term(.quiet)).disabled(!app.hasAPIKey || vm.isAnalyzing)
                    }
                }
                if !app.hasAPIKey {
                    Text("AI analysis needs an NVIDIA API key (⌘,). Monitoring itself is fully local.").font(Theme.Font.caption).foregroundStyle(Theme.amber)
                }
                if vm.isAnalyzing || !vm.analysis.isEmpty || vm.analysisError != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if let d = vm.analysisDisclosure { Text(d).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary) }
                            if vm.isAnalyzing && vm.analysis.isEmpty { ProgressView().controlSize(.small) }
                            ModelText(text: vm.analysis)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let e = vm.analysisError { Text("✕ \(e)").font(Theme.Font.caption).foregroundStyle(Theme.red) }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
    }
}

// MARK: - Alerts

private struct AlertStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.monitor
        Panel(padding: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ALERTS").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.amber)
                    Text("observations from measurements — investigate before concluding").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button(vm.showAlertList ? "COLLAPSE" : "ALL \(vm.alerts.count)") { vm.showAlertList.toggle() }.buttonStyle(.term(.quiet))
                    Button("CLEAR") { vm.clearAlerts() }.buttonStyle(.term(.quiet))
                }
                ForEach(vm.alerts.prefix(vm.showAlertList ? 30 : 2)) { a in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(a.time.formatted(date: .omitted, time: .standard)).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        Tag(text: a.level.rawValue, color: a.level == .notice ? Theme.info : (a.level == .warning ? Theme.amber : Theme.red))
                        Text(a.title).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
                        Text(a.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        if let pid = a.pid {
                            Button("SELECT") { vm.select(pid) }.buttonStyle(.term(.quiet))
                        }
                        if a.key.hasPrefix("crash.") {
                            Button("VIEW REPORT") { vm.viewCrashReport(a) }.buttonStyle(.term(.quiet))
                        }
                    }
                }
            }
        }
        .onAppear { vm.unseenAlerts = 0 }
    }
}

// MARK: - Pinned processes

private struct PinnedStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.monitor
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(vm.pinnedStats) { stat in
                    Panel(padding: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("◆").font(Theme.Font.micro).foregroundStyle(Theme.accent)
                                Text(stat.name).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Button("×") { vm.togglePin(stat.name) }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Unpin")
                            }
                            if stat.instances == 0 {
                                Text("NOT RUNNING").font(Theme.Font.micro).foregroundStyle(Theme.amber)
                            } else {
                                Text(String(format: "%.1f%% cpu · %@ · %d proc", stat.cpu, MonitorObservations.bytes(stat.rss), stat.instances))
                                    .font(Theme.Font.micro).monospacedDigit().foregroundStyle(Theme.textSecondary)
                            }
                            Sparkline(values: stat.history, maxValue: max(100, stat.history.compactMap { $0 }.max() ?? 100),
                                      color: stat.instances == 0 ? Theme.amber : Theme.accent)
                                .frame(height: 22)
                        }
                    }
                    .frame(width: 210)
                    .onTapGesture {
                        if let pid = vm.snapshot?.processes.first(where: { $0.name == stat.name })?.pid { vm.select(pid) }
                    }
                }
            }
        }
        .frame(height: 74)
    }
}

// MARK: - Network pane

private struct NetworkPane: View {
    let snapshot: MonitorSnapshot
    @Environment(AppModel.self) private var app
    @State private var selected: String?

    private var current: String? { selected ?? snapshot.interfaces.first?.name }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
          VStack(spacing: Theme.Space.m) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("INTERFACE").frame(width: 110, alignment: .leading)
                    Text("STATE").frame(width: 60, alignment: .leading)
                    Text("ADDRESSES").frame(maxWidth: .infinity, alignment: .leading)
                    Text("↓ NOW").frame(width: 96, alignment: .trailing)
                    Text("↑ NOW").frame(width: 96, alignment: .trailing)
                    Text("↓ TOTAL").frame(width: 90, alignment: .trailing)
                    Text("↑ TOTAL").frame(width: 90, alignment: .trailing)
                }
                .font(Theme.Font.micro).tracking(0.8).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                Rectangle().fill(Theme.border).frame(height: Theme.hairline)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.interfaces) { i in
                            row(i).onTapGesture { selected = i.name }
                        }
                    }
                }
                Rectangle().fill(Theme.border).frame(height: Theme.hairline)
                Text("Interface counters from the kernel (NET_RT_IFLIST2). macOS does not expose per-process network usage through public APIs, so HackCode does not show it.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surface.opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            if let wifi = app.monitor.wifi { WiFiCard(status: wifi, history: app.monitor.wifiRSSI) }
          }

            Panel {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionLabel(text: current.map { "Throughput · \($0)" } ?? "Throughput")
                    if let name = current, let points = snapshot.interfaceHistory[name], points.count > 1 {
                        let peak = max(1, points.map { max($0.inBytesPerSecond, $0.outBytesPerSecond) }.max() ?? 1)
                        ZStack {
                            Sparkline(values: points.map { Optional($0.inBytesPerSecond) }, maxValue: peak, color: Theme.accent)
                            Sparkline(values: points.map { Optional($0.outBytesPerSecond) }, maxValue: peak, color: Theme.info)
                        }
                        .frame(height: 120)
                        HStack(spacing: Theme.Space.m) {
                            legend("↓ in", Theme.accent)
                            legend("↑ out", Theme.info)
                            Spacer()
                            Text("peak \(Self.rate(peak)) · \(points.count) samples").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        }
                    } else {
                        Text("History appears after a few samples.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    SectionLabel(text: "Inspect")
                    VStack(alignment: .leading, spacing: 6) {
                        BracketButton("CONNECTIONS", color: Theme.accent) { stage("network.connections", "Established connections") }
                        BracketButton("LISTENING SERVICES", color: Theme.textSecondary) { stage("network.listening", "Listening TCP services") }
                        BracketButton("DNS CONFIG", color: Theme.textSecondary) { stage("network.dns_config", "DNS configuration") }
                        BracketButton("ROUTES", color: Theme.textSecondary) { stage("network.routes", "Routing table") }
                    }
                    Text("These open in SYS.ADMIN, where they run read-only and sandboxed.").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 360)
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ i: InterfaceRate) -> some View {
        let isSel = i.name == current
        return HStack(spacing: 0) {
            Text(i.name).frame(width: 110, alignment: .leading).foregroundStyle(Theme.textPrimary)
            Text(i.isUp ? "up" : "down").frame(width: 60, alignment: .leading).foregroundStyle(i.isUp ? Theme.accent : Theme.textTertiary)
            Text((snapshot.interfaceAddresses[i.name] ?? []).joined(separator: "  ")).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Theme.textSecondary)
            Text(Self.rate(i.bytesInPerSecond)).frame(width: 96, alignment: .trailing).foregroundStyle(Theme.textPrimary)
            Text(Self.rate(i.bytesOutPerSecond)).frame(width: 96, alignment: .trailing).foregroundStyle(Theme.textPrimary)
            Text(MonitorObservations.bytes(i.totalIn)).frame(width: 90, alignment: .trailing).foregroundStyle(Theme.textTertiary)
            Text(MonitorObservations.bytes(i.totalOut)).frame(width: 90, alignment: .trailing).foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Font.caption).monospacedDigit()
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
        .background(isSel ? Theme.accent.opacity(0.12) : .clear)
        .overlay(alignment: .leading) { if isSel { Rectangle().fill(Theme.accent).frame(width: 2) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(i.name), \(i.isUp ? "up" : "down"), in \(Self.rate(i.bytesInPerSecond)), out \(Self.rate(i.bytesOutPerSecond))")
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 10, height: 2)
            Text(text).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
        }
    }

    private func stage(_ id: String, _ label: String) {
        app.sysAdmin.stage(OperationRequest(operationID: id, provenance: .user), note: label)
    }

    static func rate(_ v: Double) -> String { ByteFormat.rate(v) }
}

// MARK: - Wi-Fi

private struct WiFiCard: View {
    let status: WiFiStatus
    let history: [Double?]

    private var securityColor: Color {
        switch status.security.strength {
        case .weak: return Theme.red
        case .fair: return Theme.amber
        case .good, .strong: return Theme.accent
        case .unknown: return Theme.textTertiary
        }
    }

    private var signalColor: Color {
        switch status.quality {
        case .excellent, .good: return Theme.accent
        case .fair: return Theme.amber
        case .poor: return Theme.red
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Theme.Space.s) {
                    Text("WI-FI · \(status.interface)").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if status.associated {
                        Text("\(status.security.rawValue) · \(status.security.strength.rawValue)")
                            .font(Theme.Font.micro).tracking(0.6).foregroundStyle(securityColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(securityColor.opacity(0.7)))
                    }
                }
                if !status.poweredOn {
                    Text("Wi-Fi is turned off.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else if !status.associated {
                    Text("Not connected to a Wi-Fi network.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        SignalBars(filled: status.quality.bars, color: signalColor)
                        Text("\(status.rssi) dBm").font(Theme.Font.title).monospacedDigit().foregroundStyle(Theme.textPrimary)
                        Text(status.quality.rawValue).font(Theme.Font.micro).tracking(0.8).foregroundStyle(signalColor)
                        Text("noise \(status.noise) dBm · SNR \(status.snr) dB").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(Int(status.transmitRateMbps)) Mbps").font(Theme.Font.bodyStrong).monospacedDigit().foregroundStyle(Theme.textPrimary)
                    }
                    Text([status.channel.map { "channel \($0)" }, status.band, status.channelWidthMHz.map { "\($0) MHz" }, status.phyMode]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    if history.compactMap({ $0 }).count > 1 {
                        Sparkline(values: history.map { $0.map { $0 + 100 } }, maxValue: 70, color: signalColor)
                            .frame(height: 34)
                            .accessibilityLabel("Signal strength history")
                    }
                    Text(status.security.advice + (status.quality == .poor ? " Weak signal: move closer to the router, or prefer 5/6 GHz when close and 2.4 GHz through walls." : ""))
                        .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SignalBars: View {
    let filled: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= filled ? color : Theme.textTertiary.opacity(0.35))
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
        .accessibilityLabel("\(filled) of 4 signal bars")
    }
}
