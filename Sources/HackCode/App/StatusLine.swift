import SwiftUI
import HackCodeKit

/// tmux-style status line: `[hackcode] 0:sys.admin* 1:monitor …    cpu 12% │ mem 78% │ bat 69% │ up 25d │ 18:31 21-Oct`
struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text(" [hackcode] ").foregroundStyle(Color.black).background(Theme.accent)
            ForEach(Array(Destination.allCases.enumerated()), id: \.element) { i, d in
                let current = model.destination == d
                Button {
                    model.destination = d
                } label: {
                    Text(" \(i):\(d.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))\(d == .sysAdmin && model.terminals.count > 1 ? "[\(model.terminals.count)]" : "")\(current ? "*" : "") ")
                        .foregroundStyle(current ? Theme.accent : Theme.textSecondary)
                        .background(current ? Theme.accent.opacity(0.14) : .clear)
                }
                .buttonStyle(.plain)
                .help("⌘\(i + 1)")
            }
            if model.isBusy {
                Text(" ● working ").foregroundStyle(Theme.amber)
            }
            Spacer(minLength: 8)
            Group {
                segment("cpu", model.pulse.cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "—", warn: (model.pulse.cpu ?? 0) > 0.85)
                divider
                segment("mem", model.pulse.memory.map { String(format: "%.0f%%", $0 * 100) } ?? "—", warn: model.pulse.pressure != "NORMAL" && model.pulse.pressure != "—")
                if let b = model.pulse.battery {
                    divider
                    segment("bat", "\(b.percent)%\(b.isCharging ? "⚡" : (b.onAC ? "~" : ""))", warn: !b.onAC && b.percent <= 15)
                }
                divider
                segment("up", Self.uptime, warn: false)
                if !model.monitor.alerts.isEmpty {
                    divider
                    Button { model.destination = .monitor } label: {
                        Text("⚠ \(model.monitor.alerts.count)").foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.plain)
                    .help("Monitor alerts")
                }
                divider
                TimelineView(.everyMinute) { ctx in
                    Text(Self.clock.string(from: ctx.date))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 6)
                        .background(Theme.accent)
                }
            }
        }
        .font(Theme.Font.caption)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 20)
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .top) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(height: Theme.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status line")
    }

    private var divider: some View {
        Text(" │ ").foregroundStyle(Theme.textTertiary)
    }

    private func segment(_ label: String, _ value: String, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(value).foregroundStyle(warn ? Theme.amber : Theme.textPrimary)
        }
    }

    /// 24-hour clock like tmux's default status-right ("18:36 21-Oct").
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd-MMM"
        return f
    }()

    private static var uptime: String {
        guard let boot = SystemMetrics.bootTime() else { return "?" }
        let s = Int(Date().timeIntervalSince(boot))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
}
