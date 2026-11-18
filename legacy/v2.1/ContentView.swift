import SwiftUI


// MARK: - ContentView

struct ContentView: View {
    @State private var inputText: String = ""
    @State private var terminalOutput: [TerminalMessage] = [
        TerminalMessage(text: "HACKCODE v2.1 -- SYSTEM READY", type: .systemStatus),
        TerminalMessage(text: "Awaiting instructions...", type: .systemStatus)
    ]
    @State private var terminalState: TerminalState = .idle
    @State private var activeMode: HackCodeMode = .systemAdmin
    @State private var pendingCommand: String? = nil
    @State private var pendingRisk: String? = nil
    @State private var securitySelectedSection: SecuritySection? = .findings
    @State private var isSecurityAuditUnlocked: Bool = false
    @State private var isPaletteManuallyOpened: Bool = false
    
    private var isCodehackMode: Bool {
        isSecurityAuditUnlocked || activeMode == .security
    }
    
    private var isCodehackPaletteVisible: Bool {
        isCodehackMode && (inputText.hasPrefix("/") || isPaletteManuallyOpened)
    }
    
    @StateObject private var llmService = LLMService()
    @StateObject private var processManager = ProcessManager()
    @StateObject private var securityEngine = SecurityEngine()
    @StateObject private var networkScanner = NetworkScanner()
    
    var currentThemeColor: Color {
        switch activeMode {
        case .security: return .red
        case .networkScanner: return .cyan
        default: return .green
        }
    }
    
    var body: some View {
        ZStack {
            // Layer 0: Matrix background
            MatrixRainView(isWorking: terminalState == .thinking || terminalState == .executing || securityEngine.isAuditing, themeColor: currentThemeColor)
            
            // Layer 1: UI content
            VStack(spacing: 0) {
                headerBar
                
                Divider()
                    .frame(height: 1)
                    .background(currentThemeColor.opacity(0.4))
                
                if activeMode == .systemAdmin {
                    terminalView
                } else if activeMode == .monitor {
                    activityMonitorView
                } else if activeMode == .security {
                    HStack {
                        SecuritySidebarView(selectedSection: $securitySelectedSection)
                        SecurityDashboardView(engine: securityEngine, llmService: llmService, selectedSection: securitySelectedSection)
                    }
                } else if activeMode == .networkScanner {
                    NetworkScannerView()
                }
            }
        }
        .colorScheme(.dark)
        .task {
            securityEngine.attach(llmService: llmService)
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: 16) {
            Text("HackCode")
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(currentThemeColor)
            
            Text("//")
                .foregroundColor(currentThemeColor.opacity(0.3))
                .font(.system(.title3, design: .monospaced))
            
            Text(activeMode.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(currentThemeColor.opacity(0.6))
            
            Spacer()
            
            // State indicator
            Text("[ \(terminalState.rawValue) ]")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(stateColor)
            
            // Tab buttons
            TabButton(title: "TERMINAL", isSelected: activeMode == .systemAdmin, themeColor: currentThemeColor) {
                activeMode = .systemAdmin
            }
            TabButton(title: "MONITOR", isSelected: activeMode == .monitor, themeColor: currentThemeColor) {
                activeMode = .monitor
                processManager.refreshProcesses()
            }
            TabButton(title: "NETWORK", isSelected: activeMode == .networkScanner, themeColor: currentThemeColor) {
                activeMode = .networkScanner
            }
            if isSecurityAuditUnlocked {
                TabButton(title: "CODEHACK", isSelected: activeMode == .security, themeColor: .red) {
                    activeMode = .security
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85))
    }
    
    private var stateColor: Color {
        switch terminalState {
        case .idle: return .green.opacity(0.4)
        case .thinking: return .yellow
        case .commandReady, .complete: return .green
        case .confirmationRequired: return .yellow
        case .executing: return .cyan
        case .error: return .red
        case .blocked: return .orange
        }
    }
    
    // MARK: - Terminal View
    
    private var terminalView: some View {
        VStack(spacing: 0) {
            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if terminalOutput.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("HackCode v1.0 // System Intelligence Layer")
                                    .foregroundColor(.green.opacity(0.6))
                                Text("Type a system problem or question. Type 'clear' to reset.")
                                    .foregroundColor(.green.opacity(0.3))
                                Text("Type 'set-key <API_KEY>' to configure NVIDIA API access.")
                                    .foregroundColor(.green.opacity(0.3))
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.top, 8)
                        }
                        
                        ForEach(terminalOutput) { message in
                            terminalMessageView(message)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: terminalOutput.count) { _, _ in
                    if let last = terminalOutput.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
                .frame(height: 1)
                .background(Color.green.opacity(0.2))
            
            // Confirmation bar (when awaiting user confirmation)
            if terminalState == .confirmationRequired, let cmd = pendingCommand {
                confirmationBar(command: cmd)
            }
            
            // Codehack Slash Command Dropdown (Accessible in Codehack mode)
            if isCodehackPaletteVisible {
                HStack {
                    SlashCommandPaletteView(
                        searchText: inputText,
                        themeColor: currentThemeColor,
                        onSelect: { item in
                            handleSelectSlashCommand(item)
                        },
                        onDismiss: {
                            isPaletteManuallyOpened = false
                            if inputText.hasPrefix("/") {
                                inputText = ""
                            }
                        }
                    )
                    .frame(maxWidth: 620)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // Input bar
            inputBar
        }
    }
    
    // MARK: - Terminal Message Rendering
    
    @ViewBuilder
    private func terminalMessageView(_ message: TerminalMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message.prefixText)
                .foregroundColor(message.prefixColor)
                .font(.system(.body, design: .monospaced).bold())
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .foregroundColor(message.color)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                
                // Suggested command block
                if let command = message.command {
                    commandBlock(command: command, risk: message.risk, requiresConfirmation: message.requiresConfirmation)
                }
            }
        }
    }
    
    private func commandBlock(command: String, risk: String?, requiresConfirmation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Risk label
            if let risk = risk {
                Text("RISK: \(risk)")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundColor(riskColor(risk))
            }
            
            HStack(spacing: 8) {
                Text("$ \(command)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black)
                    .overlay(
                        Rectangle()
                            .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                    )
                
                if !requiresConfirmation {
                    Button(action: { executeValidatedCommand(command) }) {
                        Text("RUN")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(Color.green.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Button(action: {
                        pendingCommand = command
                        pendingRisk = risk
                        terminalState = .confirmationRequired
                    }) {
                        Text("CONFIRM & RUN")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(Color.yellow.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.top, 4)
    }
    
    private func riskColor(_ risk: String) -> Color {
        switch risk.uppercased() {
        case "LOW": return .green
        case "MODERATE": return .yellow
        case "HIGH": return .red
        default: return .gray
        }
    }
    
    // MARK: - Confirmation Bar
    
    private func confirmationBar(command: String) -> some View {
        HStack(spacing: 12) {
            Text("CONFIRM EXECUTION:")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(.yellow)
            
            Text("$ \(command)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.yellow)
                .lineLimit(1)
            
            Spacer()
            
            Button(action: {
                executeValidatedCommand(command)
                terminalState = .idle
                pendingCommand = nil
                pendingRisk = nil
            }) {
                Text("[ EXECUTE ]")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                terminalState = .idle
                pendingCommand = nil
                pendingRisk = nil
                appendMessage("Command execution cancelled by user.", type: .systemStatus)
            }) {
                Text("[ CANCEL ]")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.green)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.9))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.yellow.opacity(0.3)),
            alignment: .top
        )
    }
    
    // MARK: - Input Bar
    
    private var inputBar: some View {
        HStack(spacing: 8) {
            if isCodehackMode {
                Button(action: {
                    isPaletteManuallyOpened.toggle()
                    if isPaletteManuallyOpened && !inputText.hasPrefix("/") {
                        inputText = "/"
                    }
                }) {
                    Text("/")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isCodehackPaletteVisible ? .white : Color.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                        .background(isCodehackPaletteVisible ? Color.white.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Toggle codehack command dropdown")
                .accessibilityHint("Browse all security audits and diagnostic commands")
            }
            
            Text("root@mac ~ %")
                .foregroundColor(.white)
                .font(.system(.body, design: .monospaced).bold())
            
            TextField(isCodehackMode ? "Type command, problem, or '/' for audit dropdown..." : "Type system problem or command...", text: $inputText)
                .textFieldStyle(PlainTextFieldStyle())
                .foregroundColor(.white)
                .accentColor(.white)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submitInput() }
                .disabled(terminalState == .thinking || terminalState == .executing)
            
            if terminalState == .thinking {
                Text("...")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.yellow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(6)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
    
    private func handleSelectSlashCommand(_ item: SlashCommandItem) {
        isPaletteManuallyOpened = false
        if item.requiresArgs {
            inputText = item.command + " "
        } else {
            inputText = item.command
            submitInput()
        }
    }
    
    // MARK: - Actions
    
    @MainActor
    private func submitInput() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        inputText = ""
        
        appendMessage(raw, type: .userInput)
        
        // Built-in commands
        if raw.lowercased() == "clear" || raw.lowercased() == "/clear" {
            terminalOutput.removeAll()
            llmService.clearHistory()
            terminalState = .idle
            return
        }
        
        // Strict Codehack mode gating: slash commands only work in codehack mode
        if raw.hasPrefix("/") && !isCodehackMode && raw.lowercased() != "/codehack" && raw.lowercased() != "/help" {
            appendMessage("[ACCESS DENIED] Codehack mode required for slash audits and commands. Type 'codehack' to unlock.", type: .blocked)
            terminalState = .idle
            return
        }
        
        if raw.hasPrefix("set-key ") || raw.hasPrefix("/set-key ") {
            let prefix = raw.hasPrefix("/set-key ") ? "/set-key " : "set-key "
            let key = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                appendMessage("Usage: /set-key <YOUR_NVIDIA_API_KEY>", type: .error)
                return
            }
            if llmService.setAPIKey(key) {
                appendMessage("API key stored securely in Keychain.", type: .systemStatus)
            } else {
                appendMessage("Failed to store API key in Keychain.", type: .error)
            }
            return
        }
        
        let lowerRaw = raw.lowercased()
        
        if lowerRaw == "codehack" || lowerRaw == "/codehack" {
            isSecurityAuditUnlocked = true
            activeMode = .security
            appendMessage("[SYS.WARN] CODEHACK PROTOCOLS UNLOCKED. SECURITY AUDIT ENGAGED.", type: .systemStatus)
            appendMessage("Type '/' in the terminal anytime to open the high-accessibility command and audit palette.", type: .aiResponse)
            terminalState = .idle
            return
        }
        
        // Codehack Audit & Action Slash Commands
        if isCodehackMode {
            if lowerRaw == "/audit" || lowerRaw == "audit" || lowerRaw == "/audit-full" {
                activeMode = .security
                appendMessage("[SECURITY AUDIT] Launching comprehensive security audit...", type: .systemStatus)
                Task { await securityEngine.startAudit() }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-firewall" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-firewall") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-sip" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-sip") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-gatekeeper" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-gatekeeper") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-filevault" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-filevault") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-ssh" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-ssh") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-sharing" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-sharing") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-autoupdate" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-autoupdate") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-screenlock" {
                activeMode = .security
                Task { await securityEngine.runSingleCheck(id: "mac-screenlock") }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-secrets" {
                activeMode = .security
                Task { await securityEngine.runSecretsAudit() }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-ports" {
                activeMode = .security
                Task { await securityEngine.runPortAudit() }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-dns" {
                activeMode = .security
                Task { await securityEngine.runDNSAudit() }
                terminalState = .idle
                return
            }
            if lowerRaw == "/audit-network" || lowerRaw == "/netscan" {
                activeMode = .networkScanner
                appendMessage("[NET.SCAN] Switching to Network Scanner & Topology Map...", type: .systemStatus)
                terminalState = .idle
                return
            }
            if lowerRaw == "/status" {
                let statusStr = securityEngine.isAuditing ? "RUNNING" : "IDLE"
                let count = securityEngine.session?.findings.count ?? 0
                let score = securityEngine.session?.overallScore ?? 100
                appendMessage("CODEHACK AUDIT STATUS: \(statusStr) | Findings: \(count) | Posture Score: \(score)/100", type: .systemStatus)
                terminalState = .idle
                return
            }
            if lowerRaw == "/report" {
                activeMode = .security
                let rep = securityEngine.generateReport()
                appendMessage(rep, type: .systemStatus)
                terminalState = .idle
                return
            }
            if lowerRaw == "/findings" {
                if let findings = securityEngine.session?.findings, !findings.isEmpty {
                    var out = "=== DISCOVERED FINDINGS (\(findings.count)) ===\n"
                    for (idx, f) in findings.enumerated() {
                        out += "[\(idx + 1)] [\(f.severity.rawValue)] \(f.title) -> \(f.remediation)\n"
                    }
                    appendMessage(out, type: .systemStatus)
                } else {
                    appendMessage("No findings recorded. Type '/audit' to start a security scan.", type: .systemStatus)
                }
                terminalState = .idle
                return
            }
            if lowerRaw == "/remediate" {
                activeMode = .security
                if let session = securityEngine.session, !session.findings.isEmpty {
                    var out = "=== REMEDIATION ROADMAP ===\n"
                    for (idx, f) in session.findings.enumerated() {
                        out += "[\(idx + 1)] \(f.title) -> \(f.remediation)\n"
                    }
                    out += "Type '/remediate <number>' in the Codehack terminal to apply."
                    appendMessage(out, type: .systemStatus)
                } else {
                    appendMessage("No findings requiring remediation.", type: .systemStatus)
                }
                terminalState = .idle
                return
            }
            if lowerRaw.hasPrefix("/remediate ") {
                let parts = lowerRaw.split(separator: " ")
                if parts.count >= 2, let num = Int(parts[1]), let session = securityEngine.session {
                    let index = num - 1
                    if index >= 0 && index < session.findings.count {
                        activeMode = .security
                        let finding = session.findings[index]
                        appendMessage("Remediating finding #\(num): \(finding.title)...", type: .systemStatus)
                        Task { await securityEngine.remediateFinding(finding) }
                        terminalState = .idle
                        return
                    }
                }
            }
            if lowerRaw == "/cancel" {
                securityEngine.cancelAudit()
                appendMessage("[CANCEL] Security audit cancelled.", type: .systemStatus)
                terminalState = .idle
                return
            }
        }
        
        if lowerRaw == "help" {
            let helpText = """
            Available commands:
              help     - Show all available commands
              whoami   - Execute whoami command directly
              uptime   - Execute uptime command directly
              info     - Execute sw_vers to show macOS version info
              clear    - Clear terminal output
              set-key  - Configure NVIDIA API access
              netscan  - Open Network Scanner & Topology Map
              codehack - ???
            """
            appendMessage(helpText, type: .systemStatus)
            terminalState = .idle
            return
        }
        
        if lowerRaw == "whoami" {
            terminalState = .executing
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CommandExecutor.execute(executable: "whoami", arguments: [])
                DispatchQueue.main.async {
                    terminalState = .complete
                    appendMessage(result.displayOutput, type: .commandOutput)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if terminalState == .complete { terminalState = .idle }
                    }
                }
            }
            return
        }
        
        if lowerRaw == "uptime" {
            terminalState = .executing
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CommandExecutor.execute(executable: "uptime", arguments: [])
                DispatchQueue.main.async {
                    terminalState = .complete
                    appendMessage(result.displayOutput, type: .commandOutput)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if terminalState == .complete { terminalState = .idle }
                    }
                }
            }
            return
        }
        
        if lowerRaw == "info" {
            terminalState = .executing
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CommandExecutor.execute(executable: "sw_vers", arguments: [])
                DispatchQueue.main.async {
                    terminalState = .complete
                    appendMessage(result.displayOutput, type: .commandOutput)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if terminalState == .complete { terminalState = .idle }
                    }
                }
            }
            return
        }
        
        if raw.lowercased() == "netscan" {
            activeMode = .networkScanner
            appendMessage("[NET.SCAN] INITIALIZING NETWORK TOPOLOGY SCANNER PROTOCOLS...", type: .systemStatus)
            terminalState = .idle
            return
        }
        
        // Send to AI
        if raw.lowercased() == "codehack" {
            isSecurityAuditUnlocked = true
            activeMode = .security
            appendMessage("[SYS.WARN] UNAUTHORIZED ACCESS DETECTED. SECURITY AUDIT PROTOCOLS ENGAGED.", type: .systemStatus)
            terminalState = .idle
            return
        }
        
        terminalState = .thinking
        
        Task {
            do {
                let response = try await llmService.analyzeProblem(raw)
                await MainActor.run {
                    let needsConfirm = response.requiresConfirmation || response.risk.uppercased() != "LOW"
                    
                    terminalOutput.append(TerminalMessage(
                        text: response.explanation,
                        type: .aiResponse,
                        command: response.command,
                        risk: response.risk,
                        requiresConfirmation: needsConfirm
                    ))
                    
                    if let cmd = response.command {
                        // Validate through CommandValidator
                        let validationResult = CommandValidator.validate(cmd)
                        switch validationResult {
                        case .success(let validated):
                            if validated.risk == .blocked {
                                terminalState = .blocked
                                appendMessage("Command blocked: \(validated.riskReason)", type: .blocked)
                            } else {
                                terminalState = .commandReady
                            }
                        case .failure(let error):
                            terminalState = .blocked
                            appendMessage("Validation failed: \(error.localizedDescription)", type: .blocked)
                        }
                    } else {
                        terminalState = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    terminalState = .error
                    appendMessage("Network/API error: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }
    
    @MainActor
    private func executeValidatedCommand(_ command: String) {
        let validationResult = CommandValidator.validate(command)
        
        switch validationResult {
        case .success(let validated):
            if validated.risk == .blocked {
                appendMessage("Execution blocked: \(validated.riskReason)", type: .blocked)
                terminalState = .blocked
                return
            }
            
            terminalState = .executing
            appendMessage("Executing: $ \(command)", type: .systemStatus)
            
            DispatchQueue.global(qos: .userInitiated).async {
                let result = CommandExecutor.execute(
                    executable: validated.executable,
                    arguments: validated.arguments
                )
                DispatchQueue.main.async {
                    terminalState = .complete
                    appendMessage(result.displayOutput, type: .commandOutput)
                    
                    // Reset to idle after a moment
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if terminalState == .complete { terminalState = .idle }
                    }
                }
            }
            
        case .failure(let error):
            appendMessage("Validation: \(error.localizedDescription)", type: .blocked)
            terminalState = .blocked
        }
    }
    
    private func appendMessage(_ text: String, type: MessageType) {
        terminalOutput.append(TerminalMessage(text: text, type: type))
    }
    
    // MARK: - Activity Monitor View
    
    private var activityMonitorView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Text("PID")
                    .frame(width: 60, alignment: .leading)
                Text("PROCESS")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU%")
                    .frame(width: 60, alignment: .trailing)
                Text("MEM")
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundColor(.green.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
            
            Divider()
                .frame(height: 1)
                .background(Color.green.opacity(0.2))
            
            // Process list
            List(processManager.processes) { process in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(process.pid)
                            .frame(width: 60, alignment: .leading)
                            .foregroundColor(.green.opacity(0.5))
                        Text(process.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.white)
                        Text(String(format: "%.1f%%", process.cpuUsage))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(cpuColor(process.cpuUsage))
                        Text(String(format: "%.0fMB", process.memoryUsage))
                            .frame(width: 80, alignment: .trailing)
                            .foregroundColor(.yellow.opacity(0.8))
                    }
                    .font(.system(.body, design: .monospaced))
                    
                    if let explanation = process.explanation {
                        Text("  \u{2514}\u{2500} \(explanation)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.7))
                            .padding(.top, 2)
                    } else {
                        Button(action: { explainProcess(process) }) {
                            Text("  \u{2514}\u{2500} [ EXPLAIN ]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.5))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.green.opacity(0.1))
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            
            Divider()
                .frame(height: 1)
                .background(Color.green.opacity(0.2))
            
            // Footer
            HStack {
                Text("\(processManager.processes.count) processes")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green.opacity(0.4))
                
                Spacer()
                
                if processManager.isRefreshing {
                    Text("REFRESHING...")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.yellow)
                } else {
                    Button(action: { processManager.refreshProcesses() }) {
                        Text("[ REFRESH ]")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.green)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
        }
    }
    
    private func cpuColor(_ usage: Double) -> Color {
        if usage > 50 { return .red }
        if usage > 10 { return .yellow }
        return .green
    }
    
    private func explainProcess(_ process: ProcessInfoModel) {
        Task {
            do {
                let explanation = try await llmService.explainProcess(process.name)
                await MainActor.run {
                    processManager.updateExplanation(for: process.pid, explanation: explanation)
                }
            } catch {
                await MainActor.run {
                    processManager.updateExplanation(for: process.pid, explanation: "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    var themeColor: Color = .green
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(isSelected ? .black : themeColor.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? themeColor : Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
