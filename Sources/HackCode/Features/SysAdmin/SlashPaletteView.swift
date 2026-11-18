import SwiftUI
import HackCodeKit

/// Dropdown shown above the prompt while typing "/". ↑↓ navigate, ↵ / Tab pick, Esc closes.
struct SlashPaletteView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.sysAdmin
        let matches = vm.slashMatches
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SlashCategory.allCases) { cat in
                    let selected = vm.slashCategory == cat
                    Button {
                        vm.slashCategory = cat
                        vm.focusRequest += 1
                    } label: {
                        Text(cat.rawValue)
                            .font(Theme.Font.micro).tracking(0.6)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(selected ? Color.black : Theme.textSecondary)
                            .background(selected ? Theme.accent : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(cat.rawValue) commands")
                }
                Spacer()
                Text("↑↓ select  ↵ run  ⇥ insert  esc close")
                    .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
            Rectangle().fill(Theme.accent.opacity(0.35)).frame(height: Theme.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text("no command matches '/\(vm.slashQuery ?? "")'")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                .padding(Theme.Space.m)
                        }
                        // Rows are identified by command id only (a second positional .id would make SwiftUI reuse stale rows).
                        ForEach(matches) { cmd in
                            row(cmd, selected: cmd.id == selectedID(matches, vm))
                                .onTapGesture { vm.acceptSlash(cmd) }
                        }
                    }
                }
                .frame(maxHeight: 264)
                .fixedSize(horizontal: false, vertical: matches.count < 9)   // short lists shrink to fit
                .onChange(of: vm.slashSelection) { _, _ in
                    if let id = selectedID(vm.slashMatches, vm) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            Text("\(matches.count) of \(vm.slashCatalog.count) commands · ops also run directly, e.g. /files.largest path=~/Downloads")
                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
        }
        .background(Color.black.opacity(0.94))
        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
        .shadow(color: Theme.accent.opacity(0.12), radius: 12)
    }

    private func selectedID(_ matches: [SlashCommand], _ vm: SysAdminViewModel) -> String? {
        matches.indices.contains(vm.slashSelection) ? matches[vm.slashSelection].id : nil
    }

    private func row(_ cmd: SlashCommand, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(selected ? "›" : " ").font(Theme.Font.bodyStrong).foregroundStyle(Theme.accent).frame(width: 8)
            Text(cmd.id).font(Theme.Font.bodyStrong).foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
            if let syntax = cmd.syntax {
                Text(syntax).font(Theme.Font.caption).foregroundStyle(Theme.info.opacity(0.85)).lineLimit(1)
            }
            Text("— \(cmd.title)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            if (app.sysAdmin.slashQuery ?? "").isEmpty, app.sysAdmin.recentSlashCommands.contains(cmd.id) {
                Text("RECENT").font(Theme.Font.micro).foregroundStyle(Theme.accent)
            }
            Text(cmd.mode).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
            if let risk = cmd.risk {
                Text(risk.label).font(Theme.Font.micro).foregroundStyle(Theme.color(for: risk)).frame(width: 64, alignment: .trailing)
            } else {
                Text(cmd.category.rawValue).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
        .background(selected ? Theme.accent.opacity(0.13) : Color.clear)
        .contentShape(Rectangle())
        .help(cmd.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cmd.id), \(cmd.title). \(cmd.detail)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
