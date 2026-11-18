import SwiftUI
import HackCodeKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettings().tabItem { Label("Model", systemImage: "cpu") }
            MonitorSettings().tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            PermissionsGuide().tabItem { Label("Permissions", systemImage: "lock.shield") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "sparkles.tv") }
        }
        .frame(width: 640, height: 500)
        .background(Theme.background)
    }
}

struct ModelSettings: View {
    @Environment(AppModel.self) private var app
    @State private var keyField = ""
    @State private var message: (String, Bool)?
    @State private var busy = false
    @State private var available: [String] = []
    @State private var modelField = ""

    var body: some View {
        Form {
            Section("NVIDIA API key") {
                HStack {
                    SecureField(app.hasAPIKey ? "•••••••• stored in Keychain — paste to replace" : "nvapi-…", text: $keyField)
                        .font(Theme.Font.body)
                    Button("Save") { save() }.disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove", role: .destructive) { remove() }.disabled(!app.hasAPIKey)
                }
                Text("Stored in the macOS Keychain (this device only, available when unlocked). Never written to logs, settings or model prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model") {
                HStack {
                    // Edited locally and applied on Return / Apply, so typing does not save (and audit-log) every keystroke.
                    TextField("Model ID", text: $modelField)
                        .font(Theme.Font.body)
                        .onSubmit { applyModel() }
                        .onAppear { modelField = app.settings.modelID }
                        .onChange(of: app.settings.modelID) { _, v in modelField = v }
                    Button("Apply") { applyModel() }
                        .disabled(modelField.trimmingCharacters(in: .whitespaces) == app.settings.modelID)
                    Menu("Presets") {
                        ForEach(HackCodeSettings.suggestedModelIDs, id: \.self) { id in
                            Button(id) { app.update { $0.modelID = id } }
                        }
                        if !available.isEmpty {
                            Divider()
                            ForEach(available, id: \.self) { id in Button("\(id) (available)") { app.update { $0.modelID = id } } }
                        }
                    }
                    .frame(width: 100)
                }
                if !app.settings.isModelIDWellFormed { Text("Model ID must look like vendor/model.").font(.caption).foregroundStyle(.red) }
                Toggle("Enable Nemotron reasoning mode (slower; reasoning text is discarded)", isOn: Binding(get: { app.settings.enableModelReasoning }, set: { v in app.update { $0.enableModelReasoning = v } }))
                Stepper("Request timeout: \(Int(app.settings.requestTimeoutSeconds)) s", value: Binding(get: { app.settings.requestTimeoutSeconds }, set: { v in app.update { $0.requestTimeoutSeconds = v } }), in: 10...300, step: 10)
                Stepper("Conversation turns kept: \(app.settings.maxConversationTurns)", value: Binding(get: { app.settings.maxConversationTurns }, set: { v in app.update { $0.maxConversationTurns = v } }), in: 2...40)
                LabeledContent("Endpoint", value: app.settings.baseURL)
                HStack {
                    Button("Verify model") { verify() }.disabled(!app.hasAPIKey || busy)
                    Button("Send test prompt") { ping() }.disabled(!app.hasAPIKey || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let (text, ok) = message {
                    Text(text).font(.caption).foregroundStyle(ok ? Theme.accent : Theme.red).textSelection(.enabled)
                }
                Text("Verify lists models via GET /v1/models (no personal data). The test prompt sends only “Reply with the single word OK.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyModel() {
        let v = modelField.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        app.update { $0.modelID = v }
    }

    private func save() {
        do {
            try app.saveAPIKey(keyField)
            keyField = ""
            message = ("Key saved to Keychain.", true)
        } catch {
            message = (error.localizedDescription, false)
        }
    }

    private func remove() {
        do {
            try app.deleteAPIKey()
            message = ("Key removed from Keychain.", true)
        } catch {
            message = (error.localizedDescription, false)
        }
    }

    private func verify() {
        busy = true
        Task {
            do {
                let result = try await app.llm.verifyConfiguredModel()
                available = result.nemotronModels
                message = result.available
                    ? ("\(app.settings.modelID) is listed for this key. Listing does not guarantee access — use Send test prompt.", true)
                    : ("\(app.settings.modelID) is not listed. Nemotron models listed: \(result.nemotronModels.joined(separator: ", "))", false)
            } catch {
                message = (error.localizedDescription, false)
            }
            busy = false
        }
    }

    private func ping() {
        busy = true
        Task {
            do {
                let latency = try await app.llm.pingModel()
                app.modelStatus = .ok(app.settings.modelID)
                message = ("\(app.settings.modelID) answered in \(latency.elapsedString).", true)
            } catch {
                app.modelStatus = .failed(error.localizedDescription)
                message = (error.localizedDescription, false)
            }
            busy = false
        }
    }
}

struct MonitorSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Refresh interval", selection: Binding(get: { app.settings.monitorIntervalSeconds }, set: { v in app.update { $0.monitorIntervalSeconds = v }; app.monitor.restartLoop() })) {
                    ForEach([1.0, 2.0, 5.0, 10.0, 30.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Stepper("History length: \(app.settings.monitorHistoryLength) samples", value: Binding(get: { app.settings.monitorHistoryLength }, set: { v in app.update { $0.monitorHistoryLength = v } }), in: 10...600, step: 10)
                Toggle("Background monitoring (keep sampling and alerting while MONITOR is hidden)", isOn: Binding(get: { app.settings.backgroundMonitoring }, set: { v in app.update { $0.backgroundMonitoring = v } }))
                Text("Without background monitoring, process sampling runs only while MONITOR is visible and not paused. The header CPU/MEM readout uses a cheap system-wide counter every 3 s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Stepper("Process CPU ≥ \(Int(app.settings.alertThresholds.processCPUPercent))% of a core…", value: Binding(get: { app.settings.alertThresholds.processCPUPercent }, set: { v in app.update { $0.alertThresholds.processCPUPercent = v } }), in: 20...800, step: 5)
                Stepper("…for \(app.settings.alertThresholds.sustainedSamples) consecutive samples", value: Binding(get: { app.settings.alertThresholds.sustainedSamples }, set: { v in app.update { $0.alertThresholds.sustainedSamples = v } }), in: 2...60)
                Stepper("Boot disk free below \(Int(app.settings.alertThresholds.diskFreePercent))%", value: Binding(get: { app.settings.alertThresholds.diskFreePercent }, set: { v in app.update { $0.alertThresholds.diskFreePercent = v } }), in: 1...50)
                Stepper("Battery below \(app.settings.alertThresholds.lowBatteryPercent)%", value: Binding(get: { app.settings.alertThresholds.lowBatteryPercent }, set: { v in app.update { $0.alertThresholds.lowBatteryPercent = v } }), in: 1...50)
                Text("Alerts also fire on memory-pressure warnings, large swap growth, per-process memory growth and serious thermal states. They are observations, never malware verdicts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data sources") {
                Text("System CPU and memory: Mach host statistics. Processes: libproc for your processes; a ps call (every third sample) for other users' processes (lower precision, marked “ps”; ps is setuid, so it runs with constant arguments outside the sandbox). Network: interface counters only — macOS does not expose per-process network usage through these APIs, so HackCode does not show it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var app
    @State private var cleared = false
    @State private var pendingImport: SettingsTransfer.ImportResult?
    @State private var transferMessage: String?

    var body: some View {
        Form {
            Section("What leaves this Mac") {
                Text("""
                Only requests to NVIDIA (integrate.api.nvidia.com) leave the device, and only when you use an AI feature:
                • SYS.ADMIN planning: your request, macOS version, the operation catalogue, recent conversation summary, and — for performance questions, if allowed below — names and memory of your top 5 processes.
                • EXPLAIN WITH AI: the command and its redacted output (≤ 6 KB), only when you press the button (or enable auto-explain).
                • MONITOR ANALYZE: your question and a summary of current measurements.
                • SECURITY EXPLAIN: one finding's redacted evidence.
                Secrets (API keys, tokens, passwords, private keys) are redacted and your home path is shortened to ~. Monitoring and security checks themselves are entirely local. HackCode does not provide end-to-end encryption beyond HTTPS to NVIDIA.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications & automation") {
                Toggle("macOS notifications for warnings and posture regressions", isOn: Binding(get: { app.settings.notificationsEnabled }, set: { v in
                    app.update { $0.notificationsEnabled = v }
                    if v { Task { _ = await app.requestNotificationPermission() } }
                }))
                Toggle("Show HackCode in the menu bar", isOn: Binding(get: { app.settings.showMenuBarExtra }, set: { v in app.update { $0.showMenuBarExtra = v } }))
                Picker("Scheduled security audit", selection: Binding(get: { app.settings.autoAuditHours }, set: { v in app.update { $0.autoAuditHours = v } })) {
                    Text("Off").tag(0)
                    ForEach([1, 6, 12, 24], id: \.self) { Text("Every \($0) h while open").tag($0) }
                }
                Text("Notifications contain only titles and short summaries, never command output or secrets. Scheduled audits are read-only and record a score/status summary for drift detection (~/Library/Application Support/HackCode/audit-history.json).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Controls") {
                Toggle("Include top-process summary in performance-related requests", isOn: Binding(get: { app.settings.shareProcessSnapshotWithModel }, set: { v in app.update { $0.shareProcessSnapshotWithModel = v } }))
                Toggle("Automatically explain results with AI (sends output)", isOn: Binding(get: { app.settings.autoExplainResults }, set: { v in app.update { $0.autoExplainResults = v } }))
                Toggle("Keep terminal command history between launches", isOn: Binding(get: { app.settings.persistHistory }, set: { v in
                    app.update { $0.persistHistory = v }
                    if !v { Task { await app.sharedHistory.deleteFile() } }
                }))
                Text("History is stored redacted (API keys, tokens and passwords removed) in ~/Library/Application Support/HackCode/command-history.json, readable only by you. Turning this off deletes the file; /history clear erases it at any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local data") {
                HStack {
                    Button("Clear session history") {
                        Task { await app.clearAllSessionData(); cleared = true }
                    }
                    if cleared { Text("Cleared.").font(.caption).foregroundStyle(Theme.accent) }
                }
                Text("Terminal transcript, conversation memory, analysis text and audit results live in memory only and are discarded on quit. The audit log (metadata, redacted) is kept on disk until you clear it in SECURITY AUDIT › AUDIT LOG; trend samples (disk, swap, battery — no names or paths) until you clear them in MONITOR › TRENDS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup & transfer") {
                HStack {
                    Button("Export settings…") { transferMessage = app.exportSettings() ? "Exported." : nil }
                    Button("Import settings…") { chooseImport() }
                    if let transferMessage { Text(transferMessage).font(.caption).foregroundStyle(Theme.accent) }
                }
                Text("Covers theme, rain, aliases, alert thresholds, monitor and privacy preferences. Never includes the API key (Keychain) or the API endpoint. Imports are validated, aliases are re-checked like /alias, and every change is listed for confirmation first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Apply imported settings?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), presenting: pendingImport) { r in
            Button("Apply \(r.changedKeys.count) change\(r.changedKeys.count == 1 ? "" : "s")") {
                app.applyImport(r)
                transferMessage = "Imported."
            }
            .disabled(r.changedKeys.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(Self.importSummary(r))
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImport = try app.prepareImport(from: url)
            transferMessage = nil
        } catch {
            transferMessage = "✕ " + error.localizedDescription
        }
    }

    static func importSummary(_ r: SettingsTransfer.ImportResult) -> String {
        var lines: [String] = []
        lines.append(r.changedKeys.isEmpty ? "The file matches your current settings." : "Changes: " + r.changedKeys.joined(separator: ", "))
        if !r.privacyWarnings.isEmpty {
            lines.append("⚠ Turns ON (sends more data to NVIDIA): " + r.privacyWarnings.joined(separator: ", "))
        }
        if !r.skippedAliases.isEmpty { lines.append("Skipped invalid or reserved aliases: " + r.skippedAliases.joined(separator: ", ")) }
        lines.append("The API key and endpoint are never imported.")
        return lines.joined(separator: "\n\n")
    }
}

struct PermissionsGuide: View {
    var body: some View {
        Form {
            Section("macOS permissions HackCode may need") {
                LabeledContent("Files & Folders", value: "Prompted when you scan Desktop, Documents or Downloads")
                LabeledContent("Administrator password", value: "Only for firewall remediation, via the macOS prompt")
                LabeledContent("Full Disk Access", value: "Not required; some folders stay unreadable without it")
                LabeledContent("Keychain", value: "macOS may ask once to allow access to the stored key")
            }
            Section("Isolation") {
                Text("Read-only system tools run under a macOS Seatbelt profile (sandbox-exec) that denies file writes and network access; the UI labels each operation SANDBOXED, UNSANDBOXED (with the reason) or NATIVE API. Child processes get a minimal environment, no stdin, and their own process group so cancel and timeouts stop the whole tree. HackCode itself is not App Sandboxed because it must read system state.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never done") {
                Text("No arbitrary shell commands, no sudo, no automatic privilege escalation, no SIP/Gatekeeper changes, no network scanning of other hosts, no exploitation tooling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Colour theme", selection: Binding(get: { app.settings.terminalTheme }, set: { v in app.update { $0.terminalTheme = v } })) {
                    ForEach(TerminalPalette.allCases) { p in
                        HStack {
                            Circle().fill(p.accent).frame(width: 10, height: 10)
                            Text(p.title)
                        }
                        .tag(p.rawValue)
                    }
                }
                Toggle("tmux-style status line at the bottom", isOn: Binding(get: { app.settings.showStatusLine }, set: { v in app.update { $0.showStatusLine = v } }))
                Toggle("Matrix rain background", isOn: Binding(get: { app.settings.matrixRain }, set: { v in app.update { $0.matrixRain = v } }))
                HStack {
                    Text("Intensity")
                    Slider(value: Binding(get: { app.settings.matrixRainIntensity }, set: { v in app.update { $0.matrixRainIntensity = v } }), in: 0.1...1.0)
                        .disabled(!app.settings.matrixRain)
                    Text("\(Int(app.settings.matrixRainIntensity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("The rain runs at up to 24 fps (8 fps when HackCode is in the background), speeds up while HackCode is working, and stops moving when System Settings › Accessibility › Display › Reduce Motion is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
