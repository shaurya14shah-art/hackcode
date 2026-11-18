import SwiftUI
import HackCodeKit

struct SecurityAuditView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.security
        VStack(spacing: 0) {
            AuditToolbar()
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if vm.pane == .log {
                AuditLogView()
            } else if vm.pane == .history {
                AuditHistoryView()
            } else if vm.findings.isEmpty && !vm.isRunning {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    InlineState(kind: .empty, title: "No audit has run in this session.",
                                detail: "RUN AUDIT performs \(app.auditService.registry.checks.count) read-only checks on this Mac — firewall, FileVault, Gatekeeper, SIP, updates, screen lock, sharing services, listening ports, Wi-Fi encryption, launch items and permissions. Nothing is changed and nothing is sent to the model unless you ask for an explanation.")
                    Button("RUN AUDIT ⌘⇧R") { vm.runAudit() }.buttonStyle(.term(.primary)).padding(.leading, Theme.Space.m)
                    Spacer()
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
            } else {
                VStack(spacing: Theme.Space.m) {
                    if vm.showBriefing { BriefingPanel() }
                    if !vm.changes.isEmpty || vm.scoreHistory.count > 1 { PostureChangesBanner() }
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        FindingList().frame(width: 380)
                        FindingDetail()
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .sheet(item: $vm.preview) { p in RemediationSheet(preview: p) }
        .task {
            await vm.loadLog()
            await vm.loadHistory()
        }
    }
}

private struct AuditToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.security
        HStack(spacing: Theme.Space.m) {
            if vm.isRunning {
                Button("■ CANCEL") { vm.cancelAudit() }.buttonStyle(.term(.warning))
                ProgressView(value: Double(vm.completed), total: Double(max(vm.total, 1))).frame(width: 120).tint(Theme.accent)
                Text("\(vm.completed)/\(vm.total) checks").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
            } else {
                Button(vm.findings.isEmpty ? "▶ RUN AUDIT" : "↻ RE-RUN AUDIT") { vm.runAudit() }.buttonStyle(.term(.primary))
            }
            Picker("", selection: $vm.pane) {
                ForEach(SecurityAuditViewModel.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Spacer()
            if !vm.findings.isEmpty {
                let issues = vm.findings.filter(\.isActionable).count
                let failed = vm.findings.filter { $0.status == .couldNotRun }.count
                Text("\(issues) issue\(issues == 1 ? "" : "s") · \(failed) could not run").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                if let score = vm.score {
                    HStack(spacing: 4) {
                        Text("POSTURE").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                        Text("\(score)").font(Theme.Font.title).monospacedDigit().foregroundStyle(score >= 85 ? Theme.accent : (score >= 60 ? Theme.amber : Theme.red))
                        Text("/100").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    }
                    .help("Evidence-weighted: high −20, medium −10, low −4. Checks that could not run are excluded, not assumed to pass.")
                }
                Button(vm.isBriefing ? "BRIEFING…" : "AI BRIEFING") { vm.generateBriefing() }
                    .buttonStyle(.term(.primary))
                    .disabled(vm.isRunning || vm.isBriefing || !app.hasAPIKey)
                    .help("Sends finding titles, statuses and severities (no raw evidence) to NVIDIA for a prioritised plan")
                Menu("EXPORT") {
                    Button("Copy report (text)") { copyToPasteboard(vm.reportText()) }
                    Button("Save report as Markdown…") { saveTextFile(vm.markdownReport(), suggestedName: "hackcode-audit-\(timestampForFile()).md") }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(vm.isRunning)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface.opacity(0.75))
    }
}

private struct FindingList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.security
        VStack(spacing: 0) {
            Picker("", selection: $vm.filter) {
                ForEach(SecurityAuditViewModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(Theme.Space.s)
            .background(Theme.surfaceRaised)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.visibleFindings) { f in
                        FindingRow(finding: f, selected: vm.selectedID == f.id, busy: vm.remediating.contains(f.id) || vm.rechecking.contains(f.id))
                            .onTapGesture { vm.selectedID = f.id }
                    }
                    if vm.isRunning {
                        InlineState(kind: .loading, title: "Running checks…", detail: "Results appear as each check completes.")
                    } else if vm.visibleFindings.isEmpty {
                        InlineState(kind: .empty, title: "Nothing in this filter.")
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
    }
}

private struct PostureChangesBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.security
        Panel(padding: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SINCE LAST AUDIT").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    if vm.changes.isEmpty {
                        Text("No changes in check results.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(vm.changes.prefix(5)) { c in
                        HStack(spacing: 6) {
                            Text(c.marker).foregroundStyle(c.isRegression ? Theme.amber : (c.isImprovement ? Theme.accent : Theme.textTertiary))
                            Text(c.title).foregroundStyle(Theme.textPrimary)
                            Text("\(c.from) → \(c.to)").foregroundStyle(Theme.textSecondary)
                        }
                        .font(Theme.Font.caption)
                    }
                }
                Spacer()
                if vm.scoreHistory.count > 1 {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("SCORE HISTORY (\(vm.scoreHistory.count) runs)").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                        Sparkline(values: vm.scoreHistory.map { Optional(Double($0.score)) }, maxValue: 100)
                            .frame(width: 220, height: 34)
                        Button("CLEAR HISTORY") { vm.clearHistory() }.buttonStyle(.term(.quiet))
                    }
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: Finding
    let selected: Bool
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Rectangle().fill(selected ? Theme.accent : Theme.color(for: finding.status).opacity(0.6)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.status.rawValue).font(Theme.Font.micro).tracking(0.6).foregroundStyle(Theme.color(for: finding.status))
                    if finding.isActionable { SeverityTag(severity: finding.severity) }
                    Spacer()
                    if busy { ProgressView().controlSize(.mini) }
                }
                Text(finding.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                if let note = finding.statusNote {
                    Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            .padding(.vertical, Theme.Space.s)
        }
        .padding(.trailing, Theme.Space.s)
        .background(selected ? Theme.surfaceRaised : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: Theme.hairline) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct FindingDetail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.security
        Panel {
            if let f = vm.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(f.title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                            Tag(text: f.status.rawValue, color: Theme.color(for: f.status), filled: f.isActionable)
                            Spacer()
                        }
                        HStack(spacing: Theme.Space.l) {
                            KeyValueRow(key: "severity", value: f.severity.label, valueColor: Theme.color(for: f.severity)).frame(width: 220)
                            KeyValueRow(key: "confidence", value: f.confidence.rawValue).frame(width: 220)
                        }
                        KeyValueRow(key: "component", value: f.component)
                        KeyValueRow(key: "collected", value: f.collectedAt.formatted(date: .abbreviated, time: .standard))
                        KeyValueRow(key: "id", value: f.id)
                        if let note = f.statusNote { KeyValueRow(key: "result", value: note, valueColor: Theme.color(for: f.status)) }

                        SectionLabel(text: "Evidence")
                        ForEach(Array(f.evidence.enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    CommandText(command: e.source)
                                    if e.sandboxed { Tag(text: "SANDBOXED", color: Theme.accent) }
                                    if let code = e.exitCode { Text("exit \(code)").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary) }
                                }
                                Text(e.output.isEmpty ? "(no output)" : e.output)
                                    .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary.opacity(0.9))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Theme.Space.s)
                                    .background(Theme.background)
                                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.border))
                            }
                        }

                        SectionLabel(text: "Why it matters")
                        Text(f.whyItMatters).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if !f.limitations.isEmpty {
                            SectionLabel(text: "Limitations")
                            ForEach(f.limitations, id: \.self) { Text("~ \($0)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                        }

                        if let r = f.remediation {
                            SectionLabel(text: "Remediation")
                            Text(r.summary).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                            KeyValueRow(key: "exact change", value: r.exactChange)
                            KeyValueRow(key: "reversible", value: r.reversible ? "yes" : "no")
                            KeyValueRow(key: "applied by", value: r.operationID.map { "HackCode operation \($0) (after your approval)" } ?? "you, manually — HackCode does not change this setting")
                            if let result = vm.remediationResults[f.id] {
                                KeyValueRow(key: "last attempt", value: "\(result.status.rawValue)" + (result.note.map { " — \($0)" } ?? "") + (result.errorOutput.isEmpty ? "" : " — \(result.errorOutput.prefix(200))"),
                                            valueColor: Theme.color(for: result.status))
                            }
                        }
                        if !f.verificationSteps.isEmpty {
                            SectionLabel(text: "Verification")
                            ForEach(f.verificationSteps, id: \.self) { Text("› \($0)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                        }

                        HStack(spacing: Theme.Space.s) {
                            if f.remediation != nil && f.isActionable {
                                Button("PREVIEW FIX…") { vm.previewRemediation(f) }.buttonStyle(.term(.warning))
                                    .disabled(vm.remediating.contains(f.id))
                            }
                            Button(vm.rechecking.contains(f.id) ? "RE-CHECKING…" : "RE-CHECK") { vm.recheck(f) }.buttonStyle(.term(.primary))
                                .disabled(vm.rechecking.contains(f.id) || vm.remediating.contains(f.id))
                            Button("EXPLAIN WITH AI") { vm.explain(f) }.buttonStyle(.term(.quiet))
                                .disabled(!app.hasAPIKey || vm.explaining.contains(f.id))
                                .help("Sends this finding's redacted evidence to NVIDIA")
                        }
                        if vm.explaining.contains(f.id) || !(vm.explanations[f.id] ?? "").isEmpty || vm.explainErrors[f.id] != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI EXPLANATION · status and severity were set by HackCode, not the model").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                                ModelText(text: vm.explanations[f.id] ?? "")
                                if let e = vm.explainErrors[f.id] { Text("✕ \(e)").font(Theme.Font.caption).foregroundStyle(Theme.red) }
                            }
                            .padding(Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceRaised)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a finding to see its evidence.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct RemediationSheet: View {
    let preview: SecurityAuditViewModel.RemediationPreview
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.security
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("REMEDIATION PREVIEW").font(Theme.Font.label).tracking(1.2).foregroundStyle(Theme.amber)
                Spacer()
                Tag(text: "DRY RUN — NOTHING HAS CHANGED", color: Theme.textSecondary)
            }
            Text(preview.finding.title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(preview.remediation.summary).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            SectionLabel(text: "Exact change")
            if let op = preview.operation {
                Panel { CommandText(command: op.displayCommand) }
                KeyValueRow(key: "risk", value: "\(op.risk.tier.label) — " + op.risk.reasons.joined(separator: " "), valueColor: Theme.color(for: op.risk.tier))
                KeyValueRow(key: "effect", value: op.spec.sideEffects)
                KeyValueRow(key: "reversible", value: op.spec.isReversible ? "yes (turn it off again in System Settings)" : "no")
                KeyValueRow(key: "authorization", value: op.spec.isPrivileged ? "macOS will ask for your administrator password; HackCode never sees or stores it" : "your approval")
                KeyValueRow(key: "afterwards", value: "HackCode re-runs the check and reports REMEDIATED or UNRESOLVED from fresh evidence")
            } else {
                Panel { Text(preview.remediation.exactChange).font(Theme.Font.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled) }
                if let err = preview.validationError { Text("✕ \(err)").font(Theme.Font.caption).foregroundStyle(Theme.red) }
                Text("HackCode does not change this setting itself. Steps:").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                ForEach(Array(preview.remediation.manualSteps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)").font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                }
                Text("Then use RE-CHECK to verify.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { vm.dismissPreview(approved: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if let url = preview.remediation.settingsURL {
                    Button("Open System Settings") { vm.openSystemSettings(url); vm.dismissPreview(approved: false) }
                }
                if preview.operation != nil {
                    Button(preview.operation?.spec.isPrivileged == true ? "Authorize & Apply" : "Approve & Apply") { vm.dismissPreview(approved: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600, height: 470)
        .background(Theme.background)
    }
}

private struct AuditLogView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.security
        let shown = vm.filteredLog
        let counts = vm.logCounts
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Records what was proposed, approved, run and verified — metadata only, secrets redacted. Stored at ~/Library/Application Support/HackCode/audit-log.jsonl (owner-only).")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("EXPORT CSV") { vm.exportLogCSV() }.buttonStyle(.term(.quiet)).disabled(shown.isEmpty)
                    .help("Saves the rows currently shown (after filters)")
                Button("REFRESH") { Task { await vm.loadLog() } }.buttonStyle(.term(.quiet))
                Button("CLEAR LOG") { vm.clearLog() }.buttonStyle(.term(.danger))
            }
            .padding(Theme.Space.m)
            HStack(spacing: Theme.Space.s) {
                Text("⌕").foregroundStyle(Theme.textTertiary)
                TextField("", text: $vm.logFilter.query, prompt: Text("search  ·  all terms must match  ·  -term excludes").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(Theme.Font.caption).frame(minWidth: 200)
                Picker("", selection: $vm.logFilter.window) {
                    ForEach(AuditLogFilter.Window.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Picker("", selection: $vm.logSource) {
                    ForEach(SecurityAuditViewModel.LogSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                .help("SESSION: events since launch · ON DISK: everything kept in the log file (incl. rotated)")
            }
            .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
            HStack(spacing: Theme.Space.m) {
                ForEach(AuditLogFilter.Category.allCases, id: \.self) { c in
                    let on = vm.logFilter.category == c
                    BracketButton("\(c.rawValue) \(counts[c] ?? 0)", color: on ? Theme.accent : Theme.textTertiary) { vm.logFilter.category = c }
                }
                Spacer()
                Text(vm.logFilter.isActive ? "showing \(shown.count) of \(vm.logEvents.count)" : "\(vm.logEvents.count) events")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                if vm.logFilter.isActive {
                    BracketButton("RESET", color: Theme.textTertiary) { vm.logFilter = AuditLogFilter() }
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if vm.logEvents.isEmpty {
                InlineState(kind: .empty, title: vm.logSource == .session ? "No events in this session yet." : "The log file is empty.")
                Spacer()
            } else if shown.isEmpty {
                InlineState(kind: .empty, title: "No events match the filters.", detail: "Press RESET to show everything.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { e in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(Self.stamp(e.timestamp)).foregroundStyle(Theme.textTertiary).frame(width: 120, alignment: .leading)
                                Text(e.kind.rawValue).foregroundStyle(Theme.accentDim).frame(width: 170, alignment: .leading)
                                Text(e.operation ?? "—").foregroundStyle(Theme.textPrimary).frame(width: 220, alignment: .leading).lineLimit(1)
                                Text(e.risk ?? "").foregroundStyle(Theme.textSecondary).frame(width: 70, alignment: .leading)
                                Text(e.outcome).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading).lineLimit(1)
                                Text(e.detail).foregroundStyle(Theme.textTertiary).lineLimit(2).textSelection(.enabled)
                            }
                            .font(Theme.Font.caption)
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 4)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: Theme.hairline) }
                        }
                    }
                }
                .id(vm.logSource)
            }
        }
        .background(Theme.surface.opacity(0.9))
    }

    /// Time only for today's events, otherwise "dd-MMM HH:mm:ss" so multi-day history is unambiguous.
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "dd-MMM HH:mm:ss"
        return f.string(from: d)
    }
}

private struct BriefingPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.security
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AI BRIEFING").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.accent)
                    Text("from titles, statuses and severities only · statuses were set by HackCode · may be wrong")
                        .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if vm.isBriefing { ProgressView().controlSize(.small) }
                    BracketButton("HIDE", color: Theme.textTertiary) { vm.showBriefing = false }
                }
                if !vm.briefing.isEmpty {
                    ScrollView { ModelText(text: vm.briefing).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220)
                }
                if let e = vm.briefingError { Text("✕ \(e)").font(Theme.Font.caption).foregroundStyle(Theme.red) }
            }
        }
    }
}
