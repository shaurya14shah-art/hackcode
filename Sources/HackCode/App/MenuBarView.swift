import SwiftUI
import HackCodeKit

/// Compact status panel in the macOS menu bar: live pulse, alerts, posture and quick actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var wifi: WiFiStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("HACKCODE").font(Theme.Font.title).tracking(2).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(app.pulse.pressure).font(Theme.Font.micro).foregroundStyle(app.pulse.pressure == "NORMAL" ? Theme.textTertiary : Theme.amber)
            }
            row("CPU", app.pulse.cpu)
            row("MEM", app.pulse.memory)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            HStack {
                Text("ALERTS").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(app.monitor.alerts.isEmpty ? "none" : "\(app.monitor.alerts.count)")
                    .font(Theme.Font.caption).foregroundStyle(app.monitor.alerts.isEmpty ? Theme.textSecondary : Theme.amber)
            }
            if let latest = app.monitor.alerts.first {
                Text(latest.title).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
            if !app.monitor.isSamplingActive {
                Text("Alerts need MONITOR open or background monitoring (Settings › Monitor).").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("POSTURE").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(postureText).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Text("DISK").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(diskText.0).font(Theme.Font.caption).foregroundStyle(diskText.1 ? Theme.amber : Theme.textSecondary)
            }
            if let w = wifi, w.poweredOn {
                HStack {
                    Text("WI-FI").font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(w.associated ? "\(w.rssi) dBm \(w.quality.rawValue.lowercased()) · \(w.security.rawValue)" : "not connected")
                        .font(Theme.Font.caption).lineLimit(1)
                        .foregroundStyle(w.associated && (w.security.strength == .weak || w.quality == .poor) ? Theme.amber : Theme.textSecondary)
                }
            }
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            VStack(alignment: .leading, spacing: 4) {
                action("Open HackCode") { open(.sysAdmin) }
                action("Monitor") { open(.monitor) }
                action(app.security.isRunning ? "Audit running…" : "Run security audit") { open(.securityAudit); app.security.runAudit() }
                action("Quick health check") { open(.sysAdmin); if let b = Runbook.named("health") { app.sysAdmin.runRunbook(b) } }
                Rectangle().fill(Theme.border).frame(height: Theme.hairline)
                action("Quit HackCode") { NSApp.terminate(nil) }
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
        .onAppear { wifi = WiFiMetrics.current() }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    /// This session's score, else the last recorded run.
    private var postureText: String {
        if let s = app.security.score { return "\(s)/100" }
        if let last = app.security.historyRuns.last, let s = last.score {
            return "\(s)/100 · \(last.date.formatted(.relative(presentation: .named)))"
        }
        return "not audited"
    }

    /// Free space now, plus a forecast when the 14-day trend points at full within 60 days.
    private var diskText: (String, Bool) {
        guard let free = app.trends.samples.last?.diskFreeBytes ?? SystemMetrics.volumes().first(where: { $0.mountPoint == "/" })?.availableBytes
        else { return ("—", false) }
        if let days = TrendForecast.diskFullWithin(app.trends.samples, horizonDays: 60) {
            return ("\(ByteFormat.string(free)) free · full in ~\(Int(days.rounded())) d", days < 14)
        }
        return ("\(ByteFormat.string(free)) free", false)
    }

    private func open(_ d: Destination) {
        app.destination = d
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Font.micro).tracking(1).foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .leading)
            Meter(fraction: v)
            Text(v.map { String(format: "%3.0f%%", $0 * 100) } ?? "—").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
        }
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let alerts = app.monitor.alerts.filter { $0.level != .notice }.count
        HStack(spacing: 3) {
            Image(systemName: alerts > 0 ? "exclamationmark.shield" : "terminal")
            Text(app.pulse.cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "")
        }
    }
}
