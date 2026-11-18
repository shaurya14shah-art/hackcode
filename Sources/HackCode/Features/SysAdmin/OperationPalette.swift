import SwiftUI
import HackCodeKit

/// Searchable catalogue of every registered operation. Selecting one stages it (or pre-fills /run for parameters).
struct OperationPalette: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var tier: RiskTier?
    @FocusState private var focused: Bool

    private var matches: [OperationSpec] {
        let q = query.lowercased()
        return app.registry.ordered.filter { spec in
            (tier == nil || spec.baseRisk == tier) &&
            (q.isEmpty || spec.id.contains(q) || spec.title.lowercased().contains(q) || spec.summary.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("⌕").foregroundStyle(Theme.accent)
                TextField("", text: $query, prompt: Text("search \(app.registry.ordered.count) operations").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(Theme.Font.body).focused($focused)
                    .onSubmit { if let first = matches.first { app.sysAdmin.stageFromPalette(first) } }
                Picker("", selection: $tier) {
                    Text("ALL").tag(RiskTier?.none)
                    ForEach(RiskTier.allCases, id: \.self) { Text($0.label).tag(RiskTier?.some($0)) }
                }
                .labelsHidden().frame(width: 120)
                Button("CLOSE") { app.sysAdmin.showPalette = false }.buttonStyle(.term(.quiet)).keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.m)
            .background(Theme.surfaceRaised)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.id) { spec in
                        Button { app.sysAdmin.stageFromPalette(spec) } label: {
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                RiskTag(tier: spec.baseRisk).frame(width: 74, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(spec.id).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                                        Text(spec.title).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                    }
                                    Text(spec.summary).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !spec.parameters.isEmpty {
                                        Text(spec.parameters.map { "\($0.name)\($0.isRequired ? "" : "?")" }.joined(separator: " "))
                                            .font(Theme.Font.micro).foregroundStyle(Theme.info)
                                    }
                                }
                                Spacer()
                                Text(spec.sandbox.map { $0.isSandboxed ? "sandboxed" : "unsandboxed" } ?? "native")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Theme.border.opacity(0.6)).frame(height: Theme.hairline)
                    }
                }
            }
            Text("Selecting an operation stages it for review — nothing runs until you press RUN.")
                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
        }
        .frame(width: 760, height: 560)
        .background(Theme.background)
        .onAppear { focused = true }
    }
}
