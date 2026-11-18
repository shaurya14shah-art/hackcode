import SwiftUI
import HackCodeKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            HStack(spacing: 0) {
                if model.showSidebar {
                    NavigationRail()
                    Rectangle().fill(Theme.border).frame(width: Theme.hairline)
                }
                ZStack {
                    // Views stay alive (state, scroll position) and are hidden when not selected.
                    SysAdminView().opacity(model.destination == .sysAdmin ? 1 : 0)
                        .allowsHitTesting(model.destination == .sysAdmin)
                        .accessibilityHidden(model.destination != .sysAdmin)
                    if model.destination == .monitor { MonitorView() }
                    if model.destination == .securityAudit { SecurityAuditView() }
                    if model.destination == .storage { StorageView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.settings.showStatusLine { StatusLine() }
        }
        .background {
            ZStack {
                Theme.background
                if model.settings.matrixRain {
                    MatrixRainView(isWorking: model.isBusy, intensity: model.settings.matrixRainIntensity)
                }
            }
            .ignoresSafeArea()
        }
        .tint(Theme.accent)
        .sheet(isPresented: Binding(get: { model.showShortcuts }, set: { model.showShortcuts = $0 })) { ShortcutSheet() }
        .sheet(isPresented: Binding(get: { model.showQuickOpen }, set: { model.showQuickOpen = $0 })) { QuickOpenSheet() }
        .overlay(Scanlines().ignoresSafeArea())
        // Palette colours are read at render time; changing the theme re-renders the whole tree.
        .id(model.settings.terminalTheme)
        .ignoresSafeArea(.container, edges: .top)
        .task {
            model.pulse.start()
            #if DEBUG || SNAPSHOT_HARNESS
            DebugSnapshot.runIfRequested(model)
            #endif
        }
    }
}

struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            // Leave room for the traffic-light buttons of the hidden title bar.
            Spacer().frame(width: 64)
            HStack(spacing: 6) {
                Text("HACKCODE").font(Theme.Font.title).tracking(2).foregroundStyle(Theme.textPrimary)
                Text("▸").foregroundStyle(Theme.textTertiary)
                Text(model.destination.rawValue).font(Theme.Font.label).tracking(1.2).foregroundStyle(Theme.accent)
            }
            Spacer()
            PulseReadout(label: "CPU", value: model.pulse.cpu)
            PulseReadout(label: "MEM", value: model.pulse.memory)
            Text("PRESSURE \(model.pulse.pressure)")
                .font(Theme.Font.micro).tracking(0.8)
                .foregroundStyle(model.pulse.pressure == "NORMAL" ? Theme.textTertiary : Theme.amber)
            ModelStatusView()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 38)
        .background(Theme.surface.opacity(0.7))
    }
}

private struct PulseReadout: View {
    let label: String
    let value: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.Font.micro).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Meter(fraction: value).frame(width: 44)
            Text(value.map { String(format: "%3.0f%%", $0 * 100) } ?? "  —")
                .font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { "\(Int($0 * 100)) percent" } ?? "unavailable")")
    }
}

private struct ModelStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (color, text): (Color, String) = {
            switch model.modelStatus {
            case .unknown: return (Theme.textTertiary, "MODEL: NOT VERIFIED")
            case .missingKey: return (Theme.amber, "MODEL: NO API KEY")
            case .ok: return (Theme.accent, "MODEL: ONLINE")
            case .failed: return (Theme.red, "MODEL: ERROR")
            }
        }()
        SettingsLink {
            HStack(spacing: 6) {
                StatusDot(color: color)
                Text(text).font(Theme.Font.micro).tracking(0.8).foregroundStyle(color)
            }
        }
        .buttonStyle(.plain)
        .help({
            switch model.modelStatus {
            case .ok(let m): return "Verified: \(m)"
            case .failed(let e): return e
            case .missingKey: return "Add an NVIDIA API key in Settings (⌘,). Local operations work without it."
            case .unknown: return "\(model.settings.modelID) — verify in Settings (⌘,)"
            }
        }())
    }
}

struct NavigationRail: View {
    @Environment(AppModel.self) private var model

    private func badge(for d: Destination) -> Int {
        switch d {
        case .monitor: return model.monitor.unseenAlerts
        case .securityAudit: return model.security.changes.filter(\.isRegression).count
        case .sysAdmin, .storage: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Destination.allCases) { d in
                RailItem(destination: d, selected: model.destination == d, badge: badge(for: d)) { model.destination = d }
            }
            Spacer()
            Rectangle().fill(Theme.border).frame(height: Theme.hairline).padding(.vertical, Theme.Space.s)
            SettingsLink {
                HStack(spacing: Theme.Space.s) {
                    Text("⚙").font(Theme.Font.body)
                    Text("SETTINGS").font(Theme.Font.label).tracking(1)
                    Spacer()
                    Text("⌘,").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("v3.1 · local-first")
                .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
        }
        .padding(.top, Theme.Space.s)
        .frame(width: 196)
        .background(Theme.surface.opacity(0.7))
    }
}

private struct RailItem: View {
    let destination: Destination
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Rectangle().fill(selected ? Theme.accent : .clear).frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(destination.index).font(Theme.Font.micro).foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                        Text(destination.rawValue).font(Theme.Font.label).tracking(1)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                        Text("⌘\(String(destination.shortcut.character))").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    }
                    HStack(spacing: 4) {
                        Text(destination.subtitle).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                        if badge > 0 { Tag(text: "\(badge)", color: Theme.amber, filled: true) }
                    }
                }
                .padding(.vertical, 7)
            }
            .padding(.trailing, Theme.Space.m)
            .fixedSize(horizontal: false, vertical: true)
            .background(selected ? Theme.surfaceRaised : (hovering ? Theme.surfaceHover.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(destination.rawValue), \(destination.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
