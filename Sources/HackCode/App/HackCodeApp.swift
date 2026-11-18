import SwiftUI
import HackCodeKit

@main
struct HackCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("HackCode", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal Tab") { model.newTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Terminal Tab") { model.closeTerminal() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.terminals.count < 2 || model.destination != .sysAdmin)
                Button("Next Tab") { model.cycleTerminal(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(model.terminals.count < 2)
                Button("Previous Tab") { model.cycleTerminal(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(model.terminals.count < 2)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(Destination.allCases) { d in
                    Button(d.rawValue) { model.destination = d }
                        .keyboardShortcut(d.shortcut, modifiers: .command)
                }
            }
            CommandMenu("Session") {
                Button("Focus Command Line") { model.destination = .sysAdmin; model.sysAdmin.focusRequest += 1 }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Clear Terminal") { model.sysAdmin.clear() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Find in Terminal…") { model.destination = .sysAdmin; model.sysAdmin.beginFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Older Match") { model.sysAdmin.findNext(-1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!model.sysAdmin.isFinding)
                Button("Find Newer Match") { model.sysAdmin.findNext(1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.sysAdmin.isFinding)
                Button("Search History (reverse-i-search)") { model.destination = .sysAdmin; model.sysAdmin.beginHistorySearch() }
                    .keyboardShortcut("r", modifiers: .control)
                Button("Clear Screen") { if model.destination == .sysAdmin { model.sysAdmin.clear() } }
                    .keyboardShortcut("l", modifiers: .control)
                Button("Interrupt") { if model.destination == .sysAdmin { model.sysAdmin.interrupt() } }
                    .keyboardShortcut("c", modifiers: .control)
                Divider()
                Button("Operations Palette…") { model.destination = .sysAdmin; model.sysAdmin.showPalette = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Quickly…") { model.showQuickOpen = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Export Transcript…") { saveTextFile(model.sysAdmin.transcriptMarkdown(), suggestedName: "hackcode-session-\(timestampForFile()).md") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Cancel Running Operation") { model.sysAdmin.cancelActive() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Run Security Audit") { model.destination = .securityAudit; model.security.runAudit() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Export Audit Report…") { saveTextFile(model.security.markdownReport(), suggestedName: "hackcode-audit-\(timestampForFile()).md") }
                    .disabled(model.security.findings.isEmpty)
                Button(model.monitor.isRunning ? "Pause Monitor" : "Resume Monitor") { model.monitor.toggleRunning() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarExtra }, set: { v in model.update { $0.showMenuBarExtra = v } })) {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a bare binary (swift run) the app would otherwise not become a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep running in the menu bar when the window is closed (Quit from the menu bar or ⌘Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
