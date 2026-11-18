import SwiftUI
import HackCodeKit

/// The user@host identity shown in prompts.
enum TerminalIdentity {
    static let user = NSUserName()
    static let host: String = {
        let raw = SystemMetrics.sysctlString("kern.hostname") ?? "mac"
        return raw.hasSuffix(".local") ? String(raw.dropLast(6)) : raw
    }()
    static var prompt: String { "\(user)@\(host)" }
}

/// SYS.ADMIN — rendered as a terminal session over the Matrix rain.
struct SysAdminView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var vm = app.sysAdmin
        VStack(spacing: 0) {
            TerminalTitleBar()
            if vm.isFinding { FindBar() }
            TabContent(vm: vm)
        }
        .background(Color.black.opacity(0.38))
        .sheet(isPresented: $vm.showPalette) { OperationPalette() }
        .onChange(of: vm.focusRequest) { _, _ in inputFocused = true }
        .onChange(of: app.activeTerminal) { _, _ in inputFocused = true }
        .onAppear { inputFocused = true }
        .alert(approvalTitle(vm.pendingApproval), isPresented: Binding(
            get: { vm.pendingApproval != nil },
            set: { if !$0 { vm.denyPending() } }
        ), presenting: vm.pendingApproval) { block in
            Button(block.operation.risk.tier == .critical ? "Authorize & Run" : "Approve & Run",
                   role: block.operation.spec.isReversible ? nil : .destructive) { vm.approvePending() }
            Button("Deny", role: .cancel) { vm.denyPending() }
        } message: { block in
            Text(approvalMessage(block))
        }
    }

    /// Transcript + prompt for one tab. Keyed by the tab so each keeps its own scroll position.
    @ViewBuilder
    private func TabContent(vm: SysAdminViewModel) -> some View {   // swiftlint:disable:this identifier_name
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if vm.trimmedCount > 0 {
                            Text("[\(vm.trimmedCount) older lines trimmed to bound memory]")
                                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(vm.entries) { entry in
                            EntryView(entry: entry)
                                .overlay(alignment: .leading) {
                                    if vm.isFinding, vm.findMatches.contains(entry.id) {
                                        Rectangle().fill(entry.id == vm.currentFindMatch ? Theme.amber : Theme.amber.opacity(0.35))
                                            .frame(width: 3).offset(x: -10)
                                    }
                                }
                                .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: vm.entries.count) { _, _ in
                    withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: vm.currentFindMatch) { _, id in
                    if let id { withAnimation(Motion.quick) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            promptArea(vm: vm)
        }
        .id(ObjectIdentifier(vm))
    }

    // MARK: Prompt (the terminal's current line) + "/" dropdown

    private func promptArea(vm: SysAdminViewModel) -> some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 0) {
            if vm.isSearchingHistory {
                HStack(spacing: 6) {
                    Text("match:").foregroundStyle(Theme.textTertiary)
                    if let m = vm.searchMatch {
                        Text(m.line).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    } else {
                        Text(vm.input.isEmpty ? "type to search history" : "no match").foregroundStyle(Theme.amber)
                    }
                    Spacer()
                    Text("⌃R older · ↵ run · ⇥ edit · esc cancel").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.Space.l).padding(.bottom, 4)
            } else if vm.isSlashVisible {
                SlashPaletteView()
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let hint = vm.argumentHint {
                HStack(spacing: 6) {
                    Text(hint.id).foregroundStyle(Theme.accent)
                    Text(hint.syntax ?? "").foregroundStyle(Theme.info)
                    Text("— \(hint.title)").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.Space.l).padding(.bottom, 4)
            }
            HStack(spacing: Theme.Space.s) {
                if vm.isSearchingHistory {
                    Text("(reverse-i-search)`").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
                } else {
                    PromptLabel()
                }
                TextField("", text: $vm.input, prompt: Text(app.hasAPIKey ? "describe a task, or type / for commands" : "type / for commands (add an API key in Settings for AI planning)")
                    .foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .focused($inputFocused)
                    .onSubmit { vm.isSearchingHistory ? vm.acceptHistorySearch(run: true) : vm.submit() }
                    .onChange(of: vm.input) { _, _ in vm.isSearchingHistory ? vm.historySearchChanged() : vm.inputChanged() }
                    .onKeyPress(.upArrow) {
                        if vm.isSearchingHistory { vm.beginHistorySearch(); return .handled }
                        if vm.isSlashVisible { vm.moveSlashSelection(-1) } else { vm.historyUp() }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if vm.isSlashVisible { vm.moveSlashSelection(1) } else { vm.historyDown() }
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        if vm.isSearchingHistory { vm.acceptHistorySearch(run: false); return .handled }
                        if vm.isSlashVisible, let cmd = vm.slashMatches.indices.contains(vm.slashSelection) ? vm.slashMatches[vm.slashSelection] : nil {
                            vm.input = cmd.id + (cmd.requiredArguments.isEmpty ? "" : " " + cmd.requiredArguments.map { "\($0)=" }.joined(separator: " "))
                            vm.dismissSlash()
                        } else {
                            vm.complete()
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if vm.isSearchingHistory { vm.cancelHistorySearch(); return .handled }
                        if vm.isSlashVisible { vm.dismissSlash(); return .handled }
                        if vm.isThinking { vm.cancelThinking(); return .handled }
                        return .ignored
                    }
                    .disabled(vm.isThinking)
                    .accessibilityLabel("Command line")
                    .accessibilityHint("Type a request, or slash to browse commands")
                if vm.isThinking {
                    BracketButton("CANCEL ⎋", color: Theme.amber) { vm.cancelThinking() }
                }
                if vm.pendingWithoutApproval.count >= 2 {
                    BracketButton("RUN ALL \(vm.pendingWithoutApproval.count)", color: Theme.accent) { vm.runAllPending() }
                        .help("Runs every staged operation that needs no approval, one after another")
                }
                if let pending = vm.newestPending {
                    BracketButton("RUN \(pending.operation.spec.id) ⌘↩", color: pending.operation.requiresConfirmation ? Theme.amber : Theme.accent) {
                        vm.requestRun(pending)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                BracketButton("/", color: vm.isSlashVisible ? Theme.accent : Theme.textTertiary) { vm.toggleSlashPalette() }
                    .help("Browse every command (or just type /)")
                    .accessibilityLabel("Toggle command dropdown")
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.45))
            .overlay(alignment: .top) { Rectangle().fill(Theme.accent.opacity(0.18)).frame(height: Theme.hairline) }
        }
        .animation(Motion.quick, value: vm.isSlashVisible)
    }

    private func approvalTitle(_ block: OperationBlock?) -> String {
        guard let block else { return "" }
        return "Approve \(block.operation.risk.tier.label) operation: \(block.operation.spec.title)?"
    }

    private func approvalMessage(_ block: OperationBlock) -> String {
        let op = block.operation
        var parts = ["Exactly what will run:\n\(op.displayCommand)",
                     "Effect: \(op.spec.sideEffects)",
                     op.spec.isReversible ? "Reversible: yes" : "Reversible: NO",
                     "Why HackCode rates it \(op.risk.tier.label): " + op.risk.reasons.joined(separator: " "),
                     "Proposed by: \(op.provenance.rawValue)"]
        if op.spec.isPrivileged {
            parts.append("macOS will ask for your administrator password next. HackCode never stores it.")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Terminal chrome

private struct TerminalTitleBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(app.terminals.enumerated()), id: \.offset) { i, tab in
                TerminalTab(index: i, tab: tab, selected: i == app.activeTerminal, closable: app.terminals.count > 1)
            }
            Button { app.newTerminal() } label: {
                Text(" + ").font(Theme.Font.bodyStrong).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New terminal tab (⌘T)")
            .accessibilityLabel("New terminal tab")
            Spacer()
            Text("\(app.registry.ordered.count) ops · \(app.settings.modelID.split(separator: "/").last.map(String.init) ?? "")")
                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).lineLimit(1)
                .padding(.trailing, Theme.Space.l)
        }
        .background(Color.black.opacity(0.45))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: Theme.hairline) }
    }
}

private struct TerminalTab: View {
    let index: Int
    let tab: SysAdminViewModel
    let selected: Bool
    let closable: Bool
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isBusy { StatusDot(color: Theme.accent, pulsing: true) }
            Text("\(index + 1)").font(Theme.Font.micro).foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            Text(tab.tabTitle).font(Theme.Font.caption).lineLimit(1)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            if closable && (hovering || selected) {
                Button { app.closeTerminal(index) } label: {
                    Text("×").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close tab \(index + 1)")
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
        .frame(maxWidth: 240)
        .background(selected ? Color.black.opacity(0.55) : (hovering ? Theme.surfaceHover.opacity(0.4) : .clear))
        .overlay(alignment: .top) { if selected { Rectangle().fill(Theme.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: Theme.hairline) }
        .contentShape(Rectangle())
        .onTapGesture { app.selectTerminal(index) }
        .onHover { hovering = $0 }
        .help("⌘⇧] / ⌘⇧[ switch tabs · ⌘W closes")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal tab \(index + 1): \(tab.tabTitle)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// zsh-style prompt: user@host ~ %
struct PromptLabel: View {
    var body: some View {
        (Text(TerminalIdentity.prompt).foregroundColor(Theme.accent)
         + Text(" ~ ").foregroundColor(Theme.info)
         + Text("%").foregroundColor(Theme.textPrimary))
            .font(Theme.Font.bodyStrong)
            .accessibilityHidden(true)
    }
}

/// Text button in square brackets: [ RUN ].
struct BracketButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text("[ \(title) ]")
                .font(Theme.Font.label)
                .foregroundStyle(isEnabled ? color : Theme.textTertiary)
                .padding(.horizontal, 2)
                .background(hovering && isEnabled ? color.opacity(0.15) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A transcript line with a fixed-width prefix column ("SYS.AI >", "ERR >", …).
private struct PrefixedLine<Content: View>: View {
    let prefix: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(prefix).font(Theme.Font.bodyStrong).foregroundStyle(color).frame(width: 74, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Entries

private struct EntryView: View {
    let entry: TerminalEntry

    var body: some View {
        switch entry.kind {
        case .banner: BannerView()
        case .user(let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                PromptLabel()
                FindableText(text: text, base: Theme.textPrimary)
            }
            .padding(.top, Theme.Space.s)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
        case .thinking(let started): ThinkingView(started: started)
        case .plan(let plan): PlanView(plan: plan)
        case .answer(let text):
            PrefixedLine(prefix: "SYS.AI >", color: Theme.accent) { ModelText(text: text) }
        case .operation(let block): OperationBlockView(block: block)
        case .notice(let level, let text):
            PrefixedLine(prefix: level == .warning ? "WARN >" : "SYS >", color: level == .warning ? Theme.amber : Theme.accentDim) {
                Text(text).font(Theme.Font.body).foregroundStyle(level == .warning ? Theme.amber : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .error(let text, let detail):
            PrefixedLine(prefix: "ERR >", color: Theme.red) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(Theme.Font.body).foregroundStyle(Theme.red)
                    if let detail { Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .watch(let session): WatchBlockView(session: session)
        case .table(let text):
            FindableText(text: text, base: Theme.textPrimary.opacity(0.85))
        }
    }
}

private struct BannerView: View {
    @Environment(AppModel.self) private var app

    /// "HACKCODE" in figlet's standard font, assembled letter by letter.
    static let wordmark: String = {
        let letters: [[String]] = [
            [" _   _ ", "| | | |", "| |_| |", "|  _  |", "|_| |_|"],                 // H
            ["    _    ", "   / \\   ", "  / _ \\  ", " / ___ \\ ", "/_/   \\_\\"],  // A
            ["  ____ ", " / ___|", "| |    ", "| |___ ", " \\____|"],                // C
            [" _  __", "| |/ /", "| ' / ", "| . \\ ", "|_|\\_\\"],                   // K
            ["  ____ ", " / ___|", "| |    ", "| |___ ", " \\____|"],                // C
            ["  ___  ", " / _ \\ ", "| | | |", "| |_| |", " \\___/ "],               // O
            [" ____  ", "|  _ \\ ", "| | | |", "| |_| |", "|____/ "],                // D
            [" _____ ", "| ____|", "|  _|  ", "| |___ ", "|_____|"],                 // E
        ]
        return (0..<5).map { row in letters.map { $0[row] }.joined(separator: " ") }.joined(separator: "\n")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last login: \(Self.loginDate) on hackcode")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            Text(Self.wordmark)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineSpacing(1)
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.35), radius: 3)
                .padding(.vertical, 6)
                .accessibilityLabel("HackCode")
            Text("SYS.ADMIN intelligent terminal · v3.1")
                .font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
            Text("Describe a task in plain English, or type / to browse every command. The model only proposes registered operations; HackCode validates them, shows exactly what will run, and executes nothing until you press RUN.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                statusLine("model", app.settings.modelID, ok: app.hasAPIKey)
                statusLine("key", app.hasAPIKey ? "macOS Keychain" : "missing — open Settings (⌘,)", ok: app.hasAPIKey)
                statusLine("ops", "\(app.registry.ordered.count) registered · \(Runbook.all.count) runbooks · /help", ok: true)
                statusLine("sandbox", Self.sandboxAvailable ? "seatbelt profiles available for read-only tools" : "sandbox-exec missing — sandboxed operations will refuse to run", ok: Self.sandboxAvailable)
                statusLine("history", app.settings.persistHistory ? "\(app.sysAdmin.historyCount) commands restored · ⌃R to search" : "not kept between launches", ok: true)
            }
            .padding(.vertical, 4)
            if let recap = app.sessionRecap {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.s) {
                        Text("since last session").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        BracketButton("DISMISS", color: Theme.textTertiary) { app.sessionRecap = nil }
                    }
                    ForEach(recap.lines, id: \.key) { line in
                        statusLine(line.key, line.text, ok: !line.warn)
                    }
                }
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Since last session: " + recap.lines.map(\.text).joined(separator: ". "))
            }
            Text("try:").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            ForEach(SysAdminViewModel.examples, id: \.self) { example in
                Button {
                    app.sysAdmin.input = example
                    app.sysAdmin.submit()
                } label: {
                    Text("  › \(example)").font(Theme.Font.body).foregroundStyle(app.hasAPIKey ? Theme.accentDim : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!app.hasAPIKey)
                .help(app.hasAPIKey ? "Send this request" : "Requires an API key")
            }
            HStack(spacing: Theme.Space.s) {
                Text("runbooks:").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                ForEach(Runbook.all) { book in
                    BracketButton(book.id, color: Theme.textSecondary) { app.sysAdmin.runRunbook(book) }
                        .help("\(book.title): \(book.summary) (offline, read-only)")
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, Theme.Space.s)
    }

    private func statusLine(_ key: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(ok ? "[  OK  ]" : "[ WARN ]").foregroundStyle(ok ? Theme.accent : Theme.amber)
            Text(key.padding(toLength: 8, withPad: " ", startingAt: 0)).foregroundStyle(Theme.textTertiary)
            Text(value).foregroundStyle(Theme.textSecondary)
        }
        .font(Theme.Font.body)
    }

    private static let sandboxAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")

    private static let loginDate: String = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d HH:mm:ss"
        return f.string(from: Date())
    }()
}

private struct ThinkingView: View {
    let started: Date
    @Environment(AppModel.self) private var app
    static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        TimelineView(.periodic(from: started, by: 0.1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(started)
            PrefixedLine(prefix: "SYS.AI >", color: Theme.accent) {
                HStack(spacing: Theme.Space.s) {
                    Text(String(Self.spinner[Int(elapsed * 10) % Self.spinner.count])).foregroundStyle(Theme.accent)
                    Text("planning with \(app.settings.modelID)").foregroundStyle(Theme.textSecondary)
                    Text(elapsed.elapsedString).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    Text("(esc to cancel)").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Font.body)
            }
        }
    }
}

private struct PlanView: View {
    let plan: PlanInfo
    @State private var showBasis = false

    var body: some View {
        PrefixedLine(prefix: "SYS.AI >", color: Theme.accent) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text("PLAN").font(Theme.Font.bodyStrong).foregroundStyle(Theme.accent)
                    Text(plan.intent).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    BracketButton(showBasis ? "hide basis" : "why?", color: Theme.textTertiary) { withAnimation(Motion.quick) { showBasis.toggle() } }
                        .help("Show the evidence and constraints behind this plan")
                }
                if !plan.approach.isEmpty {
                    Text(plan.approach).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plan.limitations, id: \.self) { l in
                    Text("# \(l)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                ForEach(plan.rejections, id: \.id) { r in
                    Text("✕ rejected \(r.id): \(r.reason)").font(Theme.Font.caption).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showBasis {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("# \(plan.contextDisclosure)")
                        Text("# model \(plan.modelID) answered in \(plan.latency.elapsedString); its reasoning text is not requested or stored.")
                        Text("# every operation below was re-validated locally: risk tier, arguments and paths are decided by HackCode, not the model.")
                    }
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

// MARK: - Operation block (terminal style: gutter line, $ command, output, bracket actions)

struct OperationBlockView: View {
    let block: OperationBlock
    @Environment(AppModel.self) private var app
    @State private var showDetails = false

    private var op: ValidatedOperation { block.operation }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(gutterColor).frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                header
                commandLine
                if let rationale = op.rationale, !rationale.isEmpty {
                    Text("# \(rationale)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showDetails || (op.requiresConfirmation && block.phase == .pending) { details }
                output
                controls
                explanation
            }
            .padding(.leading, Theme.Space.m)
            .padding(.vertical, 6)
        }
        .padding(.leading, 82)
        .background(Color.black.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operation \(op.spec.title), risk \(op.risk.tier.label)")
    }

    private var gutterColor: Color {
        switch block.phase {
        case .pending: return op.requiresConfirmation ? Theme.color(for: op.risk.tier) : Theme.borderStrong
        case .running: return Theme.accent
        case .finished: return block.record.map { Theme.color(for: $0.status) } ?? Theme.border
        case .denied: return Theme.border
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(op.spec.id).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
            tag(op.risk.tier.label, Theme.color(for: op.risk.tier))
            if op.spec.isReadOnly { tag("READ-ONLY", Theme.textSecondary) }
            if let sandbox = op.spec.sandbox {
                tag(sandbox.isSandboxed ? "SANDBOXED" : "UNSANDBOXED", sandbox.isSandboxed ? Theme.accentDim : Theme.amber)
                    .help(sandbox.displayLabel)
            } else {
                tag("NATIVE", Theme.textSecondary).help("Implemented in-process with Foundation/Darwin APIs; no shell")
            }
            tag(op.provenance.rawValue, Theme.textTertiary)
            Spacer()
            phaseLabel
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.Font.micro).tracking(0.6).foregroundStyle(color)
    }

    private var commandLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
            CommandText(command: op.displayCommand)
                .contextMenu { Button("Copy Command") { copyToPasteboard(op.displayCommand) } }
            if let p = block.pipeline {
                Text(p.description).font(Theme.Font.body).foregroundStyle(Theme.info)
                    .help("Applied by HackCode to the captured output; nothing extra is executed")
                Text("(local filter)").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder private var phaseLabel: some View {
        switch block.phase {
        case .pending:
            Text(op.requiresConfirmation ? "[ AWAITING APPROVAL ]" : "[ READY ]").font(Theme.Font.micro)
                .foregroundStyle(op.requiresConfirmation ? Theme.amber : Theme.textSecondary)
        case .running:
            if let started = block.startedAt {
                TimelineView(.periodic(from: started, by: 0.1)) { ctx in
                    let t = ctx.date.timeIntervalSince(started)
                    Text("[ \(String(ThinkingView.spinner[Int(t * 10) % ThinkingView.spinner.count])) RUNNING \(t.elapsedString) ]")
                        .font(Theme.Font.micro).monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
        case .finished:
            if let r = block.record {
                Text("[ \(r.status == .succeeded ? "OK" : r.status.rawValue) · \(r.duration.elapsedString)\(r.exitCode.map { " · exit \($0)" } ?? "") ]")
                    .font(Theme.Font.micro).foregroundStyle(Theme.color(for: r.status))
            }
        case .denied:
            Text("[ DENIED ]").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            KeyValueRow(key: "effect", value: op.spec.sideEffects)
            KeyValueRow(key: "risk basis", value: op.risk.reasons.joined(separator: " "), valueColor: Theme.color(for: op.risk.tier))
            if let claimed = op.claimedRisk, claimed.uppercased() != op.risk.tier.label {
                KeyValueRow(key: "model said", value: "\(claimed) — overridden by local policy", valueColor: Theme.amber)
            }
            KeyValueRow(key: "reversible", value: op.spec.isReversible ? "yes" : "no")
            if let sandbox = op.spec.sandbox { KeyValueRow(key: "isolation", value: sandbox.displayLabel) }
            if !op.spec.requiredPermissions.isEmpty { KeyValueRow(key: "permissions", value: op.spec.requiredPermissions.joined(separator: "; ")) }
            KeyValueRow(key: "limits", value: "timeout \(Int(op.spec.timeoutSeconds)) s · output ≤ \(op.spec.maxOutputBytes / 1024) KB")
        }
    }

    @ViewBuilder private var output: some View {
        let raw = block.record.map { $0.output + ($0.errorOutput.isEmpty ? "" : ($0.output.isEmpty ? "" : "\n") + $0.errorOutput) } ?? block.liveOutput
        let text = block.displayed(raw)
        if block.phase == .running || !text.isEmpty || block.record != nil {
            VStack(alignment: .leading, spacing: 2) {
                ScrollView {
                    FindableText(text: text.isEmpty ? (block.phase == .running ? "waiting for output…" : "(no output)") : String(text.suffix(64_000)),
                                 base: block.record?.status == .rejected || block.record?.status == .failed ? Theme.red.opacity(0.9) : Theme.textPrimary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: text.count < 2000)
                if let note = block.record?.note {
                    Text("! \(note)").font(Theme.Font.caption).foregroundStyle(Theme.amber)
                }
                if text.count > 64_000 || block.liveTruncated {
                    Text("# display shows the last 64 KB; [ COPY OUTPUT ] copies everything captured").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            switch block.phase {
            case .pending:
                BracketButton(op.requiresConfirmation ? "REVIEW & APPROVE" : "RUN", color: op.requiresConfirmation ? Theme.amber : Theme.accent) {
                    app.sysAdmin.requestRun(block)
                }
                BracketButton("DENY", color: Theme.textSecondary) { app.sysAdmin.deny(block) }
                if !op.requiresConfirmation {
                    BracketButton(showDetails ? "HIDE DETAILS" : "DETAILS", color: Theme.textTertiary) { showDetails.toggle() }
                }
            case .running:
                BracketButton("CANCEL ⌘.", color: Theme.red) { app.sysAdmin.cancel(block) }
            case .finished:
                if let r = block.record {
                    BracketButton("COPY OUTPUT", color: Theme.textSecondary) { copyToPasteboard(block.displayed(r.output + (r.errorOutput.isEmpty ? "" : "\n" + r.errorOutput))) }
                    if r.status != .rejected {
                        BracketButton(block.isExplaining ? "EXPLAINING…" : "EXPLAIN WITH AI", color: Theme.accent) { app.sysAdmin.explain(block) }
                            .disabled(block.isExplaining || !app.hasAPIKey)
                            .help("Sends the redacted output (≤ 6 KB) and the command to NVIDIA for an evidence-based explanation")
                    }
                }
            case .denied:
                EmptyView()
            }
            Spacer()
            BracketButton("COPY CMD", color: Theme.textTertiary) { copyToPasteboard(op.displayCommand) }
        }
    }

    @ViewBuilder private var explanation: some View {
        if block.isExplaining || !block.explanation.isEmpty || block.explainError != nil {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("AI >").font(Theme.Font.bodyStrong).foregroundStyle(Theme.accent)
                    Text("explanation of the output above · may be wrong").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    if block.isExplaining { ProgressView().controlSize(.mini) }
                }
                if !block.explanation.isEmpty { ModelText(text: block.explanation) }
                if let err = block.explainError { Text("ERR > \(err)").font(Theme.Font.caption).foregroundStyle(Theme.red) }
            }
            .padding(.top, 2)
        }
    }
}


/// Monospaced transcript text that highlights the active ⌘F query.
struct FindableText: View {
    let text: String
    let base: Color
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.sysAdmin
        Group {
            if vm.isFinding, !vm.findQuery.isEmpty, text.localizedCaseInsensitiveContains(vm.findQuery) {
                Text(highlighted(text, query: vm.findQuery, base: base))
            } else {
                Text(text).foregroundStyle(base)
            }
        }
        .font(Theme.Font.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FindBar: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var vm = app.sysAdmin
        HStack(spacing: Theme.Space.s) {
            Text("find:").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
            TextField("", text: $vm.findQuery, prompt: Text("search the transcript").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain).font(Theme.Font.body)
                .focused($focused)
                .onSubmit { vm.findNext(-1) }
                .onKeyPress(.escape) { vm.endFind(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { vm.findNext(1); return .handled }
                    return .ignored
                }
            Text(vm.findQuery.isEmpty ? "" : (vm.findMatches.isEmpty ? "no matches" : "\(vm.findMatches.count - vm.findIndex)/\(vm.findMatches.count)"))
                .font(Theme.Font.caption).monospacedDigit().foregroundStyle(vm.findMatches.isEmpty ? Theme.red : Theme.textSecondary)
            BracketButton("‹ older", color: Theme.textSecondary) { vm.findNext(-1) }.disabled(vm.findMatches.isEmpty)
            BracketButton("newer ›", color: Theme.textSecondary) { vm.findNext(1) }.disabled(vm.findMatches.isEmpty)
            Spacer()
            Text("↵ older · ⇧↵ newer · ⌘G · esc").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
            BracketButton("DONE", color: Theme.accent) { vm.endFind() }
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.amber.opacity(0.4)).frame(height: Theme.hairline) }
        .onAppear { focused = true }
        .onChange(of: vm.findFocusRequest) { _, _ in focused = true }
    }
}
