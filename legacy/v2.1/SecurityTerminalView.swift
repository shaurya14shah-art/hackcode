import SwiftUI

struct SecurityTerminalView: View {
    @ObservedObject var llmService: LLMService
    @ObservedObject var engine: SecurityEngine
    
    @State private var commandInput: String = ""
    @State private var isPaletteManuallyOpened: Bool = false
    @State private var terminalOutput: [String] = [
        "SEC-TERM v2.5 [CODEHACK MODE ENGAGED]",
        "System security intelligence active. Press '/' to browse all audits & commands."
    ]
    
    private var isPaletteVisible: Bool {
        commandInput.hasPrefix("/") || isPaletteManuallyOpened
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("CODEHACK SECURITY TERMINAL")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.red)
                
                Text("[PRESS '/' FOR AUDITS & COMMANDS]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
                
                Spacer()
                
                if engine.isAuditing {
                    HStack(spacing: 6) {
                        Text("AUDITING SYSTEM...")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.yellow)
                        
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 8, height: 8)
                    }
                } else if llmService.isProcessing {
                    HStack(spacing: 6) {
                        Text("PROCESSING AI...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.red)
                        
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.85))
            .border(Color.white.opacity(0.08), width: 1)
            
            // Terminal Logs Area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(terminalOutput.enumerated()), id: \.offset) { index, log in
                            HStack(alignment: .top, spacing: 8) {
                                if log.hasPrefix(">") {
                                    Text(">")
                                        .font(.system(.caption, design: .monospaced).bold())
                                        .foregroundColor(.red)
                                        .frame(width: 12, alignment: .leading)
                                    
                                    Text(String(log.dropFirst(2)))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.white)
                                } else if log.hasPrefix("[ALERT]") || log.hasPrefix("[ERROR]") {
                                    Text(log)
                                        .font(.system(.caption, design: .monospaced).bold())
                                        .foregroundColor(.yellow)
                                } else if log.hasPrefix("[INSPECT]") || log.hasPrefix("[DISCOVER]") {
                                    Text(log)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.cyan)
                                } else if log.hasPrefix("[IDENTIFY]") || log.hasPrefix("[REPORT]") {
                                    Text(log)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.green)
                                } else {
                                    Text(log)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.red.opacity(0.85))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                        }
                    }
                    .padding(10)
                }
                .background(Color.black.opacity(0.9))
                .onChange(of: terminalOutput.count) { _, _ in
                    if !terminalOutput.isEmpty {
                        withAnimation {
                            proxy.scrollTo(terminalOutput.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: engine.auditLog.count) { old, new in
                    if new > old {
                        let newLogs = engine.auditLog.suffix(new - old)
                        terminalOutput.append(contentsOf: newLogs)
                    } else if new > 0 && new <= old {
                        terminalOutput.append(contentsOf: engine.auditLog)
                    }
                }
            }
            .border(Color.white.opacity(0.08), width: 1)
            
            // Slash Command Dropdown (Visible when user types '/' or clicks '/')
            if isPaletteVisible {
                HStack {
                    SlashCommandPaletteView(
                        searchText: commandInput,
                        themeColor: .red,
                        onSelect: { item in
                            handleSelectCommand(item)
                        },
                        onDismiss: {
                            isPaletteManuallyOpened = false
                            if commandInput.hasPrefix("/") {
                                commandInput = ""
                            }
                        }
                    )
                    .frame(maxWidth: 620)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // Input Bar
            HStack(spacing: 8) {
                // Quick '/' slash dropdown toggle button
                Button(action: {
                    isPaletteManuallyOpened.toggle()
                    if isPaletteManuallyOpened && !commandInput.hasPrefix("/") {
                        commandInput = "/"
                    }
                }) {
                    Text("/")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isPaletteVisible ? .white : Color.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                        .background(isPaletteVisible ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Toggle slash commands dropdown")
                .accessibilityHint("Opens list of all security audits and system commands")
                
                Text("codehack@root ~ %")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.white.opacity(0.85))
                
                TextField("Type command, audit name, or '/' for dropdown...", text: $commandInput)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                    .accentColor(.white)
                    .disableAutocorrection(true)
                    .onSubmit {
                        executeCommand()
                    }
                
                Button(action: executeCommand) {
                    Image(systemName: "return")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Execute command")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.clear)
    }
    
    private func handleSelectCommand(_ item: SlashCommandItem) {
        isPaletteManuallyOpened = false
        if item.requiresArgs {
            // Fill the input bar with syntax prefix so user can add arguments
            commandInput = item.command + " "
        } else {
            commandInput = item.command
            executeCommand()
        }
    }
    
    @MainActor
    private func executeCommand() {
        let raw = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        
        // Log user command
        terminalOutput.append("> \(raw)")
        commandInput = ""
        isPaletteManuallyOpened = false
        
        // Normalize: strip leading slash for uniform matching
        var normalized = raw
        if normalized.hasPrefix("/") {
            normalized = String(normalized.dropFirst())
        }
        let lowerCmd = normalized.lowercased()
        
        // 1. Terminal Utilities
        if lowerCmd == "clear" {
            terminalOutput.removeAll()
            terminalOutput.append("SEC-TERM v2.5 [CODEHACK MODE ENGAGED]")
            return
        }
        
        if lowerCmd == "help" {
            let helpLines = [
                "=== CODEHACK SECURITY COMMAND & AUDIT REFERENCE ===",
                "Type '/' anywhere in the input line to open the high-accessibility palette.",
                "",
                "AUDIT COMMANDS:",
                "  /audit              - Run complete security audit (all modules)",
                "  /audit-firewall     - Audit Application Firewall & stealth rules",
                "  /audit-sip          - Audit System Integrity Protection (SIP)",
                "  /audit-gatekeeper   - Audit Gatekeeper code-signing policy",
                "  /audit-filevault    - Audit FileVault full disk encryption",
                "  /audit-ssh          - Audit SSH remote login daemon",
                "  /audit-sharing      - Audit sharing services (Screen/File/AirDrop)",
                "  /audit-autoupdate   - Audit macOS automatic software update policies",
                "  /audit-screenlock   - Audit screensaver & lock timeout security",
                "  /audit-secrets      - Scan local directories for leaked API keys",
                "  /audit-ports        - Probe local TCP listening ports (21-9090)",
                "  /audit-dns          - Query DNS configuration & records",
                "  /audit-network      - Subnet ARP discovery & device map",
                "",
                "ASSESSMENT ACTIONS:",
                "  /status             - Show live audit state, posture score & findings count",
                "  /report             - Generate formal security assessment report",
                "  /findings           - List all discovered vulnerabilities by severity",
                "  /remediate          - List remediation recommendations",
                "  /remediate <N>      - Apply automated fix for finding index N",
                "  /cancel             - Emergency Kill Switch (abort running audit)",
                "",
                "SYSTEM DIAGNOSTICS:",
                "  /whoami             - Display current user identity & groups",
                "  /uptime             - Display system uptime and CPU load averages",
                "  /info               - Display macOS software version and architecture",
                "  /processes          - Inspect top active processes",
                "",
                "AI ADVISOR:",
                "  /set-key <KEY>      - Configure NVIDIA API Key in macOS Keychain",
                "  /advisor <QUESTION> - Ask AI Security Analyst with findings context"
            ]
            terminalOutput.append(contentsOf: helpLines)
            return
        }
        
        // 2. Full Security Audit
        if lowerCmd == "audit" || lowerCmd == "audit-full" {
            terminalOutput.append("[SECURITY AUDIT] Starting comprehensive security posture audit...")
            Task {
                await engine.startAudit()
            }
            return
        }
        
        // 3. Focused Modular Audits
        if lowerCmd == "audit-firewall" {
            terminalOutput.append("[AUDIT: FIREWALL] Probing macOS Application Firewall configuration...")
            Task { await engine.runSingleCheck(id: "mac-firewall") }
            return
        }
        
        if lowerCmd == "audit-sip" {
            terminalOutput.append("[AUDIT: SIP] Inspecting System Integrity Protection (csrutil)...")
            Task { await engine.runSingleCheck(id: "mac-sip") }
            return
        }
        
        if lowerCmd == "audit-gatekeeper" {
            terminalOutput.append("[AUDIT: GATEKEEPER] Inspecting Gatekeeper assessment subsystem (spctl)...")
            Task { await engine.runSingleCheck(id: "mac-gatekeeper") }
            return
        }
        
        if lowerCmd == "audit-filevault" {
            terminalOutput.append("[AUDIT: FILEVAULT] Querying CoreStorage / APFS disk encryption state...")
            Task { await engine.runSingleCheck(id: "mac-filevault") }
            return
        }
        
        if lowerCmd == "audit-ssh" {
            terminalOutput.append("[AUDIT: SSH] Probing systemsetup remote login daemon...")
            Task { await engine.runSingleCheck(id: "mac-ssh") }
            return
        }
        
        if lowerCmd == "audit-sharing" {
            terminalOutput.append("[AUDIT: SHARING] Querying Screen Sharing, File Sharing, and AirDrop...")
            Task { await engine.runSingleCheck(id: "mac-sharing") }
            return
        }
        
        if lowerCmd == "audit-autoupdate" {
            terminalOutput.append("[AUDIT: AUTOUPDATE] Auditing softwareupdate background schedule...")
            Task { await engine.runSingleCheck(id: "mac-autoupdate") }
            return
        }
        
        if lowerCmd == "audit-screenlock" {
            terminalOutput.append("[AUDIT: SCREENLOCK] Auditing screensaver delay & password enforcement...")
            Task { await engine.runSingleCheck(id: "mac-screenlock") }
            return
        }
        
        if lowerCmd == "audit-secrets" {
            terminalOutput.append("[AUDIT: SECRETS] Scanning current workspace for exposed API tokens & private keys...")
            Task { await engine.runSecretsAudit() }
            return
        }
        
        if lowerCmd == "audit-ports" {
            terminalOutput.append("[AUDIT: PORTS] Probing local TCP listening ports on 127.0.0.1...")
            Task { await engine.runPortAudit() }
            return
        }
        
        if lowerCmd == "audit-dns" {
            terminalOutput.append("[AUDIT: DNS] Inspecting DNS resolver configuration...")
            Task { await engine.runDNSAudit() }
            return
        }
        
        if lowerCmd == "audit-network" || lowerCmd == "netscan" {
            terminalOutput.append("[NET.SCAN] Network topology sweep available via NETWORK tab.")
            terminalOutput.append("[NET.SCAN] Executing local ARP probe...")
            let arpRes = CommandExecutor.execute(executable: "arp", arguments: ["-a"])
            terminalOutput.append(arpRes.displayOutput)
            return
        }
        
        // 4. Audit Engine Actions & Findings
        if lowerCmd == "status" {
            let statusStr = engine.isAuditing ? "RUNNING" : "IDLE"
            let checksCount = engine.session?.checksPerformed ?? 0
            let findingsCount = engine.session?.findings.count ?? 0
            let score = engine.session?.overallScore ?? 100
            
            terminalOutput.append("=== AUDIT ENGINE STATUS ===")
            terminalOutput.append("  Status:            \(statusStr)")
            terminalOutput.append("  Checks Performed:  \(checksCount)")
            terminalOutput.append("  Findings Recorded: \(findingsCount)")
            terminalOutput.append("  Posture Score:     \(score)/100")
            return
        }
        
        if lowerCmd == "report" {
            let report = engine.generateReport()
            terminalOutput.append("=== AUDIT REPORT ===")
            terminalOutput.append(contentsOf: report.components(separatedBy: .newlines))
            return
        }
        
        if lowerCmd == "findings" {
            if let findings = engine.session?.findings, !findings.isEmpty {
                terminalOutput.append("=== ACTIVE VULNERABILITY FINDINGS (\(findings.count)) ===")
                for (idx, f) in findings.enumerated() {
                    terminalOutput.append("[\(idx + 1)] [\(f.severity.rawValue)] \(f.title)")
                    terminalOutput.append("     Category: \(f.category)")
                    terminalOutput.append("     Remediation: \(f.remediation)")
                }
                terminalOutput.append("Type '/remediate <number>' to apply a fix.")
            } else {
                terminalOutput.append("No active findings. Run '/audit' to assess security posture.")
            }
            return
        }
        
        if lowerCmd == "remediate" {
            if let session = engine.session, !session.findings.isEmpty {
                terminalOutput.append("=== REMEDIATION ROADMAP ===")
                for (index, finding) in session.findings.enumerated() {
                    terminalOutput.append("[\(index + 1)] \(finding.severity.rawValue.uppercased()): \(finding.title)")
                    terminalOutput.append("    -> Fix: \(finding.remediation)")
                }
                terminalOutput.append("Type '/remediate <number>' to apply fix automatically.")
            } else {
                terminalOutput.append("No findings currently require remediation.")
            }
            return
        }
        
        if lowerCmd.hasPrefix("remediate ") || lowerCmd.hasPrefix("remediate-finding ") {
            let parts = lowerCmd.split(separator: " ")
            if parts.count >= 2, let num = Int(parts[1]), let session = engine.session {
                let index = num - 1
                if index >= 0 && index < session.findings.count {
                    let finding = session.findings[index]
                    terminalOutput.append("Remediating finding #\(num): \(finding.title)...")
                    Task {
                        await engine.remediateFinding(finding)
                    }
                } else {
                    terminalOutput.append("Invalid finding index #\(num). Run '/findings' to view list.")
                }
            } else {
                terminalOutput.append("Usage: /remediate <number>")
            }
            return
        }
        
        if lowerCmd == "cancel" {
            engine.cancelAudit()
            terminalOutput.append("[CANCEL] Emergency Kill Switch triggered. Audit halted.")
            return
        }
        
        // 5. System Commands
        if lowerCmd == "whoami" {
            let res = CommandExecutor.execute(executable: "whoami", arguments: [])
            let idRes = CommandExecutor.execute(executable: "id", arguments: [])
            terminalOutput.append("User: \(res.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            terminalOutput.append("Groups: \(idRes.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        
        if lowerCmd == "uptime" {
            let res = CommandExecutor.execute(executable: "uptime", arguments: [])
            terminalOutput.append(res.displayOutput)
            return
        }
        
        if lowerCmd == "info" {
            let res = CommandExecutor.execute(executable: "sw_vers", arguments: [])
            let uname = CommandExecutor.execute(executable: "uname", arguments: ["-a"])
            terminalOutput.append(res.displayOutput)
            terminalOutput.append(uname.displayOutput)
            return
        }
        
        if lowerCmd == "processes" {
            let res = CommandExecutor.execute(executable: "/bin/sh", arguments: ["-c", "ps -arcx -o %cpu,%mem,pid,command | head -n 12"])
            terminalOutput.append(res.displayOutput)
            return
        }
        
        // 6. Keychain API Key Management
        if lowerCmd.hasPrefix("set-key ") {
            let key = String(raw.dropFirst("set-key ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                terminalOutput.append("Usage: /set-key <YOUR_NVIDIA_API_KEY>")
            } else {
                if llmService.setAPIKey(key) {
                    terminalOutput.append("API key stored securely in macOS Keychain under 'HackCode_NVIDIA_API_KEY'.")
                } else {
                    terminalOutput.append("Failed to store API key in Keychain.")
                }
            }
            return
        }
        
        // 7. AI Security Advisor
        var question = raw
        if lowerCmd.hasPrefix("advisor ") {
            question = String(raw.dropFirst("advisor ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        Task {
            await askAdvisor(question: question)
        }
    }
    
    @MainActor
    private func askAdvisor(question: String) async {
        let findings = engine.session?.findings ?? []
        llmService.isProcessing = true
        defer { llmService.isProcessing = false }
        
        do {
            let response = try await llmService.askAdvisor(question: question, findings: findings)
            self.terminalOutput.append("AI ADVISOR > \(response)")
        } catch let error as NSError {
            if error.domain == "LLMService_Fatal" && error.code == 401 {
                self.terminalOutput.append("Authentication failed. Check your API key with '/set-key <API_KEY>'.")
            } else if error is URLError && (error as! URLError).code == .timedOut {
                self.terminalOutput.append("Request timed out. The LLM server may be overloaded.")
            } else {
                self.terminalOutput.append("Advisor Error: \(error.localizedDescription)")
            }
        } catch {
            self.terminalOutput.append("Advisor Error: \(error.localizedDescription)")
        }
    }
}
