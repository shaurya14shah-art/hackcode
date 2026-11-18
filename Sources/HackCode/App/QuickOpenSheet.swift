import SwiftUI
import HackCodeKit

extension AppModel {
    /// Everything Open Quickly can jump to, from state already in memory (no new scans or requests).
    func quickOpenItems() -> [QuickItem] {
        var items: [QuickItem] = Destination.allCases.map { QuickItem(id: "module:\($0.rawValue)", kind: .module, title: $0.rawValue, subtitle: "⌘\($0.shortcut.character) · \($0.subtitle)") }
        items += SlashCommandCatalog.sessionCommands.map { QuickItem(id: "command:\($0.id)", kind: .command, title: $0.id, subtitle: $0.title) }
        items += security.findings.map { QuickItem(id: "finding:\($0.id)", kind: .finding, title: $0.title, subtitle: "\($0.status.rawValue) · \($0.severity.label) · \($0.component)") }
        if let snap = monitor.snapshot {
            items += snap.processes.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.map { p in
                QuickItem(id: "process:\(p.pid)", kind: .process, title: p.name,
                          subtitle: "pid \(p.pid) · \(p.user ?? "?") · \(p.cpuPercent.map { String(format: "%.1f%% cpu", $0) } ?? "cpu —")")
            }
        }
        items += StorageViewModel.shortcuts.map { QuickItem(id: "folder:\($0.1)", kind: .folder, title: $0.0, subtitle: Redactor().redact($0.1)) }
        items += storage.entries.filter { $0.isDirectory && !$0.isProtected }.map {
            QuickItem(id: "folder:\($0.path)", kind: .folder, title: $0.name, subtitle: Redactor().redact($0.path) + " · " + ByteFormat.string($0.bytes))
        }
        items += registry.ordered.map { QuickItem(id: "operation:\($0.id)", kind: .operation, title: $0.id, subtitle: $0.title) }
        return items
    }

    /// Navigates to the item. Commands and operations are only inserted into the command line — nothing runs.
    func openQuickItem(_ item: QuickItem) {
        showQuickOpen = false
        let value = String(item.id.drop { $0 != ":" }.dropFirst())
        switch item.kind {
        case .module:
            if let d = Destination(rawValue: value) { destination = d }
        case .command:
            destination = .sysAdmin
            sysAdmin.input = value + " "
            sysAdmin.focusRequest += 1
        case .operation:
            destination = .sysAdmin
            sysAdmin.input = "/run \(value) "
            sysAdmin.focusRequest += 1
        case .finding:
            destination = .securityAudit
            security.pane = .findings
            security.filter = .all
            security.selectedID = value
        case .process:
            destination = .monitor
            monitor.pane = .processes
            monitor.search = ""
            if let pid = pid_t(value) { monitor.select(pid) }
        case .folder:
            destination = .storage
            storage.open(value)
        }
    }
}

/// ⌘⇧O — fuzzy "go to anything" across modules, commands, findings, processes, folders and operations.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var index = 0
    @State private var all: [QuickItem] = []
    @FocusState private var focused: Bool

    private var results: [QuickItem] { QuickOpen.rank(all, query: query, limit: 60) }

    var body: some View {
        let results = self.results
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("›").font(Theme.Font.bodyStrong).foregroundStyle(Theme.accent)
                TextField("", text: $query, prompt: Text("go to a module, command, finding, process, folder or operation").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(Theme.Font.body).focused($focused)
                    .onSubmit { if results.indices.contains(index) { app.openQuickItem(results[index]) } }
                    .onChange(of: query) { _, _ in index = 0 }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                Button("ESC") { app.showQuickOpen = false }.buttonStyle(.term(.quiet)).keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.m)
            .background(Theme.surfaceRaised)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if results.isEmpty {
                InlineState(kind: .empty, title: "Nothing matches “\(query)”.")
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                Button { app.openQuickItem(item) } label: {
                                    HStack(spacing: Theme.Space.s) {
                                        Text(item.kind.rawValue).font(Theme.Font.micro).tracking(0.8)
                                            .foregroundStyle(Self.color(item.kind)).frame(width: 70, alignment: .leading)
                                        Text(item.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        Text(item.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if i == index { Text("↵").font(Theme.Font.caption).foregroundStyle(Theme.accent) }
                                    }
                                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                                    .background(i == index ? Theme.accent.opacity(0.12) : .clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(i)
                            }
                        }
                    }
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            Text("↑↓ select · ↵ open · esc close — commands and operations are inserted into the command line, never run")
                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
        }
        .frame(width: 720, height: 480)
        .background(Theme.background)
        .onAppear {
            all = app.quickOpenItems()
            focused = true
        }
    }

    static func color(_ kind: QuickItem.Kind) -> Color {
        switch kind {
        case .module: return Theme.accent
        case .command: return Theme.info
        case .finding: return Theme.amber
        case .process: return Theme.textSecondary
        case .folder: return Theme.accentDim
        case .operation: return Theme.info.opacity(0.8)
        }
    }
}
