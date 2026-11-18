import SwiftUI
import Charts
import HackCodeKit

/// SECURITY AUDIT › HISTORY: score over time, a check × run drift matrix, and per-run changes.
struct AuditHistoryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.security
        let runs = vm.historyRuns
        let timeline = AuditTimeline.make(runs)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(runs.isEmpty ? "No audit runs recorded yet."
                     : "\(runs.count) run\(runs.count == 1 ? "" : "s") since \(Self.day(runs.first!.date)) · status/score summaries only, stored at ~/Library/Application Support/HackCode/audit-history.json (owner-only)")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("CLEAR HISTORY") { vm.clearHistory() }.buttonStyle(.term(.danger)).disabled(runs.isEmpty)
            }
            .padding(Theme.Space.m)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if runs.isEmpty {
                InlineState(kind: .empty, title: "Run an audit to start the history.",
                            detail: "Each run records only check statuses and the score, so drift between runs can be spotted here. Turn on scheduled audits in Settings › Privacy to build it automatically.")
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ScoreChart(runs: runs)
                        DriftMatrix(timeline: timeline)
                        RunList(runs: runs)
                    }
                    .padding(Theme.Space.m)
                }
            }
        }
        .background(Theme.surface.opacity(0.9))
        .task { await vm.loadHistory() }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: d)
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd-MMM HH:mm"
        return f.string(from: d)
    }
}

private struct ScoreChart: View {
    let runs: [AuditSummary]

    var body: some View {
        let scored = runs.compactMap { r in r.score.map { (r.date, $0) } }
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("POSTURE SCORE").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let last = scored.last {
                        let delta = scored.count > 1 ? last.1 - scored[scored.count - 2].1 : 0
                        Text("\(last.1)/100").font(Theme.Font.title).monospacedDigit().foregroundStyle(Self.color(last.1))
                        if delta != 0 {
                            Text(delta > 0 ? "▲ \(delta)" : "▼ \(-delta)").font(Theme.Font.caption).foregroundStyle(delta > 0 ? Theme.accent : Theme.amber)
                        }
                    }
                }
                if scored.count > 1 {
                    Chart {
                        RuleMark(y: .value("good", 85)).foregroundStyle(Theme.accent.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        RuleMark(y: .value("fair", 60)).foregroundStyle(Theme.amber.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        ForEach(Array(scored.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("run", p.0), y: .value("score", p.1)).foregroundStyle(Theme.accent)
                            PointMark(x: .value("run", p.0), y: .value("score", p.1)).foregroundStyle(Self.color(p.1)).symbolSize(28)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine().foregroundStyle(Theme.border)
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: [0, 60, 85, 100]) { v in
                            AxisGridLine().foregroundStyle(Theme.border)
                            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary) }
                        }
                    }
                    .frame(height: 140)
                } else {
                    Text("The chart appears after the second run.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    static func color(_ s: Int) -> Color { s >= 85 ? Theme.accent : (s >= 60 ? Theme.amber : Theme.red) }
}

private struct DriftMatrix: View {
    let timeline: AuditTimeline

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.m) {
                    Text("CHECK × RUN (last \(timeline.runs.count))").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    legend("■", Theme.accent, "pass")
                    legend("■", Theme.amber, "issue")
                    legend("■", Theme.info.opacity(0.7), "observed")
                    legend("■", Theme.textTertiary.opacity(0.5), "could not run")
                    legend("·", Theme.textTertiary, "absent")
                }
                .padding(.bottom, 4)
                ForEach(timeline.rows) { row in
                    HStack(spacing: 2) {
                        Text(row.title).lineLimit(1).foregroundStyle(row.cells.last.flatMap { $0 } == .issue ? Theme.textPrimary : Theme.textSecondary)
                            .frame(width: 260, alignment: .leading)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Self.cell(cell)
                        }
                        Text(row.flips > 0 ? "\(row.flips) change\(row.flips == 1 ? "" : "s")" : "")
                            .foregroundStyle(row.flips > 0 ? Theme.amber : Theme.textTertiary)
                            .padding(.leading, Theme.Space.s)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title): latest \(row.cells.last.flatMap { $0 }?.rawValue ?? "absent"), \(row.flips) changes")
                }
            }
        }
    }

    @ViewBuilder static func cell(_ c: AuditTimeline.Cell?) -> some View {
        let color: Color = switch c {
        case .pass: Theme.accent
        case .issue: Theme.amber
        case .observed: Theme.info.opacity(0.7)
        case .couldNotRun: Theme.textTertiary.opacity(0.5)
        case nil: .clear
        }
        ZStack {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 14, height: 12)
            if c == nil { Text("·").foregroundStyle(Theme.textTertiary) }
        }
        .frame(width: 16, height: 14)
    }

    private func legend(_ glyph: String, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(glyph).foregroundStyle(color)
            Text(label).foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Font.micro)
    }
}

private struct RunList: View {
    let runs: [AuditSummary]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Text("RUNS (newest first)").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary).padding(.bottom, 4)
                let indexed = Array(runs.enumerated()).reversed()
                ForEach(Array(indexed), id: \.offset) { i, run in
                    let changes = i > 0 ? AuditHistoryStore.diff(from: runs[i - 1], to: run) : []
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(AuditHistoryView.stamp(run.date)).foregroundStyle(Theme.textTertiary).frame(width: 110, alignment: .leading)
                        Text(run.score.map { "\($0)/100" } ?? "—").monospacedDigit()
                            .foregroundStyle(run.score.map(ScoreChart.color) ?? Theme.textTertiary).frame(width: 64, alignment: .leading)
                        Text("\(AuditTimeline.issueCount(run)) issue\(AuditTimeline.issueCount(run) == 1 ? "" : "s")").foregroundStyle(Theme.textSecondary).frame(width: 70, alignment: .leading)
                        if i == 0 {
                            Text("first recorded run").foregroundStyle(Theme.textTertiary)
                        } else if changes.isEmpty {
                            Text("no changes").foregroundStyle(Theme.textTertiary)
                        } else {
                            Text(changes.map { "\($0.marker) \($0.title) \($0.from)→\($0.to)" }.joined(separator: " · "))
                                .foregroundStyle(changes.contains(where: \.isRegression) ? Theme.amber
                                                 : (changes.allSatisfy(\.isImprovement) ? Theme.accent : Theme.textSecondary))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.caption)
                    .padding(.vertical, 3)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: Theme.hairline) }
                }
            }
        }
    }
}
