import SwiftUI

/// ⌘/ — every keyboard shortcut in one place.
struct ShortcutSheet: View {
    @Environment(AppModel.self) private var model

    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [("⌘1 … ⌘4", "SYS.ADMIN · MONITOR · SECURITY AUDIT · STORAGE"), ("⌘\\", "show / hide sidebar"),
                        ("⌘,", "settings"), ("⌘/", "this sheet")]),
        ("Terminal", [("/", "command dropdown (↑↓ select, ↵ run, ⇥ insert, esc close)"), ("↑ / ↓", "command history"),
                      ("⌃R", "reverse history search"), ("Tab", "complete commands and operation ids"),
                      ("⌘↩", "run the newest staged operation"), ("⌃C", "interrupt / discard line"), ("⌃L · ⌘K", "clear"),
                      ("⌘F · ⌘G · ⇧⌘G", "find in transcript"), ("⌘O", "operations palette"), ("⇧⌘O", "open quickly (go to anything)"), ("⌘L", "focus command line"),
                      ("⌘.", "cancel running work"), ("⌘⇧E", "export transcript")]),
        ("Tabs", [("⌘T", "new terminal tab"), ("⌘W", "close tab"), ("⌘⇧] · ⌘⇧[", "next / previous tab")]),
        ("Modules", [("⌘⇧R", "run security audit"), ("⌘⇧P", "pause / resume monitor"),
                     ("↑ ↓ ↵ ← →", "navigate process, finding and storage lists")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("KEYBOARD SHORTCUTS").font(Theme.Font.label).tracking(1.2).foregroundStyle(Theme.accent)
                Spacer()
                BracketButton("CLOSE", color: Theme.textSecondary) { model.showShortcuts = false }
                    .keyboardShortcut(.cancelAction)
            }
            ForEach(groups, id: \.0) { group in
                SectionLabel(text: group.0)
                ForEach(group.1, id: \.0) { key, what in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(key).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary).frame(width: 150, alignment: .leading)
                        Text(what).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Pipes: any command can end in | grep [-i] [-v] x | head N | tail N | sort [-rn] | uniq | wc -l (local filters).")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
        .background(Theme.background)
    }
}
