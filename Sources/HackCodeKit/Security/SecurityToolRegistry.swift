import Foundation

/// Evidence gathered by a check, before evaluation.
public struct CollectedEvidence: Sendable {
    public var items: [EvidenceItem]
    /// Combined text used by the evaluator (stdout + stderr, unredacted, never shown or logged directly).
    public var raw: String
    public var failure: String?

    public init(items: [EvidenceItem], raw: String, failure: String? = nil) {
        self.items = items
        self.raw = raw
        self.failure = failure
    }
}

public struct Evaluation: Sendable, Equatable {
    public var status: FindingStatus
    public var severity: Severity
    public var confidence: Confidence
    public var note: String?

    public static func pass(_ note: String? = nil, confidence: Confidence = .high) -> Evaluation {
        Evaluation(status: .pass, severity: .info, confidence: confidence, note: note)
    }
    public static func issue(_ severity: Severity, _ note: String, confidence: Confidence = .high) -> Evaluation {
        Evaluation(status: .issue, severity: severity, confidence: confidence, note: note)
    }
    public static func observed(_ note: String) -> Evaluation {
        Evaluation(status: .observed, severity: .info, confidence: .high, note: note)
    }
    public static func couldNotRun(_ note: String) -> Evaluation {
        Evaluation(status: .couldNotRun, severity: .info, confidence: .low, note: note)
    }
}

/// A registered, read-only audit check. Only checks in `SecurityToolRegistry` can run.
public struct SecurityCheck: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let component: String
    public let category: String
    /// Scope: always the local machine. No check targets other hosts.
    public let scope = "This Mac (local, read-only)"
    public let requiredPermissions: [String]
    public let evidenceMethod: String
    public let timeoutSeconds: TimeInterval
    public let whyItMatters: String
    public let limitations: [String]
    public let remediation: Remediation?
    public let verificationSteps: [String]
    public let collect: @Sendable (ProcessRunning) async -> CollectedEvidence
    public let evaluate: @Sendable (CollectedEvidence) -> Evaluation
}

public struct SecurityToolRegistry: Sendable {
    public let checks: [SecurityCheck]

    public init(checks: [SecurityCheck]) { self.checks = checks }

    public func check(id: String) -> SecurityCheck? { checks.first { $0.id == id } }

    public static func standard(home: String = NSHomeDirectory()) -> SecurityToolRegistry {
        SecurityToolRegistry(checks: [
            firewall, stealthMode, fileVault, gatekeeper, sip, automaticUpdates, pendingUpdates, xprotect, screenLock,
            autoLogin, guestAccount,
            remoteService(id: "remote-login", title: "Remote Login (SSH)", label: "com.openssh.sshd",
                          settings: "Sharing › Remote Login", operationID: "security.disable_remote_login"),
            remoteService(id: "screen-sharing", title: "Screen Sharing", label: "com.apple.screensharing",
                          settings: "Sharing › Screen Sharing"),
            remoteService(id: "file-sharing", title: "File Sharing (SMB)", label: "com.apple.smbd",
                          settings: "Sharing › File Sharing"),
            listeningServices, firewallAllowedApps, launchItems(home: home), systemExtensions, appSignatures(home: home),
            homePermissions(home: home), adminAccounts, backups, deviceManagement, wifiSecurity,
        ])
    }

    // MARK: - Evidence helpers

    static func run(_ runner: ProcessRunning, _ executable: String, _ args: [String], timeout: TimeInterval = 20,
                    sandbox: SandboxProfile = .readOnlyNoNetwork) async -> CollectedEvidence {
        let display = ArgvFormatter.display([executable] + args)
        do {
            let r = try await runner.run(ProcessRunRequest(executable: executable, arguments: args, timeout: timeout,
                                                          maxOutputBytes: 128 * 1024, sandbox: sandbox), sink: .discard)
            let combined = [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            let shown = Redactor.sanitizeForPrompt(Redactor().redact(combined.trimmingCharacters(in: .whitespacesAndNewlines)), maxCharacters: 4000)
            var failure: String?
            if r.timedOut { failure = "timed out after \(Int(timeout)) s" } else if r.cancelled { failure = "cancelled" }
            return CollectedEvidence(items: [EvidenceItem(source: display, output: shown, exitCode: r.exitCode, sandboxed: r.sandboxed)],
                                     raw: combined, failure: failure)
        } catch {
            return CollectedEvidence(items: [EvidenceItem(source: display, output: error.localizedDescription)], raw: "",
                                     failure: error.localizedDescription)
        }
    }

    static func plist(_ path: String) -> (CollectedEvidence, [String: Any]?) {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            let exists = FileManager.default.fileExists(atPath: path)
            let msg = exists ? "file exists but could not be read" : "file not present"
            return (CollectedEvidence(items: [EvidenceItem(source: "read plist \(path)", output: msg)], raw: "", failure: exists ? msg : nil), nil)
        }
        return (CollectedEvidence(items: [], raw: ""), dict)
    }

    // MARK: - Checks

    static let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    static let firewall = SecurityCheck(
        id: "firewall", title: "Application Firewall", component: "Network › Firewall", category: "NETWORK",
        requiredPermissions: [], evidenceMethod: "socketfilterfw --getglobalstate (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "With the firewall off, any app that opens a listening port accepts connections from other devices on the same network.",
        limitations: ["Reports the Application Firewall only; it does not see third-party firewalls or network filters."],
        remediation: Remediation(summary: "Turn on the macOS Application Firewall.",
                                 exactChange: "\(firewallTool) --setglobalstate on  (as administrator)",
                                 operationID: "security.enable_firewall",
                                 manualSteps: ["Open System Settings › Network › Firewall", "Turn Firewall on"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: socketfilterfw --getglobalstate", "Expect: “Firewall is enabled”"],
        collect: { await run($0, firewallTool, ["--getglobalstate"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("state = 1") || t.contains("state = 2") || t.contains("firewall is enabled") { return .pass("Firewall is enabled.") }
            if t.contains("state = 0") || t.contains("firewall is disabled") { return .issue(.medium, "Firewall is disabled.") }
            return .couldNotRun("Unrecognised output from socketfilterfw.")
        })

    static let stealthMode = SecurityCheck(
        id: "firewall-stealth", title: "Firewall Stealth Mode", component: "Network › Firewall", category: "NETWORK",
        requiredPermissions: [], evidenceMethod: "socketfilterfw --getstealthmode (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "Stealth mode stops this Mac from answering ICMP probes and connection attempts to closed ports, making it less visible on untrusted networks.",
        limitations: ["Only takes effect while the Application Firewall is enabled."],
        remediation: Remediation(summary: "Enable firewall stealth mode.",
                                 exactChange: "\(firewallTool) --setstealthmode on  (as administrator)",
                                 operationID: "security.enable_stealth_mode",
                                 manualSteps: ["Open System Settings › Network › Firewall › Options", "Enable stealth mode"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: socketfilterfw --getstealthmode", "Expect: “stealth mode is on”"],
        collect: { await run($0, firewallTool, ["--getstealthmode"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("stealth mode is on") || t.contains("stealth mode enabled") { return .pass("Stealth mode is on.") }
            if t.contains("stealth mode is off") || t.contains("stealth mode disabled") { return .issue(.low, "Stealth mode is off.") }
            return .couldNotRun("Unrecognised output from socketfilterfw.")
        })

    static let fileVault = SecurityCheck(
        id: "filevault", title: "FileVault Disk Encryption", component: "Storage › FileVault", category: "DATA PROTECTION",
        requiredPermissions: [], evidenceMethod: "fdesetup status (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "Without FileVault, anyone with physical access to the Mac or its disk can read its data.",
        limitations: ["Reports the boot volume only."],
        remediation: Remediation(summary: "Turn on FileVault from System Settings and store the recovery key safely.",
                                 exactChange: "System Settings › Privacy & Security › FileVault › Turn On",
                                 operationID: nil,
                                 manualSteps: ["Open System Settings › Privacy & Security", "Turn on FileVault", "Store the recovery key somewhere safe"],
                                 settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: fdesetup status", "Expect: “FileVault is On.”"],
        collect: { await run($0, "/usr/bin/fdesetup", ["status"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("decryption in progress") { return .issue(.high, "FileVault decryption is in progress.") }
            if t.contains("encryption in progress") { return .pass("FileVault encryption is in progress.", confidence: .medium) }
            if t.contains("filevault is on") { return .pass("FileVault is on.") }
            if t.contains("filevault is off") { return .issue(.high, "FileVault is off.") }
            return .couldNotRun("Unrecognised output from fdesetup.")
        })

    static let gatekeeper = SecurityCheck(
        id: "gatekeeper", title: "Gatekeeper", component: "System › Gatekeeper", category: "SYSTEM INTEGRITY",
        requiredPermissions: [], evidenceMethod: "spctl --status (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "Gatekeeper blocks apps that are not signed and notarized, reducing the chance of running tampered software.",
        limitations: ["Does not report per-app exceptions the user has approved."],
        remediation: Remediation(summary: "Re-enable Gatekeeper assessments.",
                                 exactChange: "/usr/sbin/spctl --global-enable  (as administrator)",
                                 operationID: "security.enable_gatekeeper",
                                 manualSteps: ["Open System Settings › Privacy & Security", "Under Security, allow apps from the App Store and identified developers"],
                                 settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: spctl --status", "Expect: “assessments enabled”"],
        collect: { await run($0, "/usr/sbin/spctl", ["--status"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("assessments enabled") { return .pass("Gatekeeper assessments are enabled.") }
            if t.contains("assessments disabled") { return .issue(.high, "Gatekeeper assessments are disabled.") }
            return .couldNotRun("Unrecognised output from spctl.")
        })

    static let sip = SecurityCheck(
        id: "sip", title: "System Integrity Protection", component: "System › SIP", category: "SYSTEM INTEGRITY",
        requiredPermissions: [], evidenceMethod: "csrutil status (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "SIP prevents even administrator processes from modifying protected system files and processes.",
        limitations: ["Can only be changed from macOS Recovery; HackCode never modifies it."],
        remediation: Remediation(summary: "Re-enable SIP from macOS Recovery.",
                                 exactChange: "In Recovery: csrutil enable",
                                 operationID: nil,
                                 manualSteps: ["Shut down and start up in macOS Recovery", "Open Terminal from the Utilities menu", "Run: csrutil enable", "Restart"],
                                 settingsURL: nil, reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: csrutil status", "Expect: “System Integrity Protection status: enabled.”"],
        collect: { await run($0, "/usr/bin/csrutil", ["status"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("custom configuration") || t.contains("unknown") { return .issue(.medium, "SIP is in a custom (partially disabled) configuration.") }
            if t.contains("status: enabled") { return .pass("SIP is enabled.") }
            if t.contains("status: disabled") { return .issue(.high, "SIP is disabled.") }
            return .couldNotRun("Unrecognised output from csrutil.")
        })

    static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate.plist"

    static let automaticUpdates = SecurityCheck(
        id: "auto-updates", title: "Automatic Security Updates", component: "Software Update", category: "PATCHING",
        requiredPermissions: [], evidenceMethod: "Read \(softwareUpdatePlist) (native)", timeoutSeconds: 5,
        whyItMatters: "Rapid Security Responses and XProtect data updates deliver fixes for actively exploited issues; disabling them delays protection.",
        limitations: ["A missing key is treated as the macOS default (enabled), so confidence is reduced.",
                      "Configuration profiles (MDM) can override these preferences."],
        remediation: Remediation(summary: "Enable automatic checks, security responses and system data files.",
                                 exactChange: "defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled/CriticalUpdateInstall/ConfigDataInstall -bool true  (as administrator)",
                                 operationID: "security.enable_security_updates",
                                 manualSteps: ["Open System Settings › General › Software Update", "Click ⓘ next to Automatic Updates", "Enable “Install Security Responses and system files”"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check", "Expect AutomaticCheckEnabled, CriticalUpdateInstall and ConfigDataInstall to be true or unset"],
        collect: { _ in
            let (ev, dict) = plist(softwareUpdatePlist)
            guard let dict else { return ev }
            let keys = ["AutomaticCheckEnabled", "AutomaticDownload", "CriticalUpdateInstall", "ConfigDataInstall", "AutomaticallyInstallMacOSUpdates"]
            let lines = keys.map { k in "\(k) = \(dict[k].map { "\($0)" } ?? "(not set — macOS default)")" }
            let text = lines.joined(separator: "\n")
            return CollectedEvidence(items: [EvidenceItem(source: "read plist \(softwareUpdatePlist)", output: text)], raw: text)
        },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            if ev.raw.isEmpty { return .pass("Preferences file not present; macOS defaults apply.", confidence: .low) }
            func isOff(_ key: String) -> Bool { ev.raw.contains("\(key) = 0") || ev.raw.contains("\(key) = false") }
            var problems: [String] = []
            if isOff("AutomaticCheckEnabled") { problems.append("automatic update checks are off") }
            if isOff("CriticalUpdateInstall") { problems.append("security responses are not installed automatically") }
            if isOff("ConfigDataInstall") { problems.append("system data files (XProtect) are not installed automatically") }
            if !problems.isEmpty { return .issue(.medium, problems.joined(separator: "; ").capitalizedFirst + ".") }
            let unset = ev.raw.contains("not set")
            return .pass(unset ? "Security update settings are enabled or at their default." : "Security update settings are enabled.",
                         confidence: unset ? .medium : .high)
        })

    static let pendingUpdates = SecurityCheck(
        id: "pending-updates", title: "Pending Software Updates", component: "Software Update", category: "PATCHING",
        requiredPermissions: ["Network access to Apple's update service"],
        evidenceMethod: "softwareupdate --list (sandboxed: no file writes; network allowed)", timeoutSeconds: 120,
        whyItMatters: "Pending macOS updates frequently contain security fixes.",
        limitations: ["Requires network access to Apple; results reflect what Apple offers this Mac right now."],
        remediation: Remediation(summary: "Install the pending updates from System Settings.",
                                 exactChange: "System Settings › General › Software Update › Update Now",
                                 operationID: nil,
                                 manualSteps: ["Open System Settings › General › Software Update", "Install the listed updates"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                                 reversible: false, requiresConfirmation: true),
        verificationSteps: ["Re-run: softwareupdate --list", "Expect: “No new software available.”"],
        collect: { await run($0, "/usr/sbin/softwareupdate", ["--list"], timeout: 120, sandbox: .readOnlyWithNetwork) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw
            if t.contains("No new software available") { return .pass("No pending updates.") }
            let titles = t.split(separator: "\n").filter { $0.contains("Title:") }
                .map { $0.replacingOccurrences(of: "Title:", with: "").split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
            if titles.isEmpty {
                if t.lowercased().contains("error") || t.lowercased().contains("could not") { return .couldNotRun("softwareupdate reported an error.") }
                return .couldNotRun("Unrecognised output from softwareupdate.")
            }
            let os = titles.contains { $0.hasPrefix("macOS") }
            return .issue(os ? .medium : .low, "\(titles.count) pending: " + titles.joined(separator: "; "))
        })

    static let screenLock = SecurityCheck(
        id: "screen-lock", title: "Screen Lock Delay", component: "Lock Screen", category: "ACCESS CONTROL",
        requiredPermissions: [], evidenceMethod: "sysadminctl -screenLock status (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "A long or disabled delay before requiring a password leaves an unattended Mac usable by anyone nearby.",
        limitations: ["Reports the current user's setting."],
        remediation: Remediation(summary: "Require a password immediately after sleep or screen saver.",
                                 exactChange: "System Settings › Lock Screen › Require password after screen saver begins or display is turned off: Immediately",
                                 operationID: nil,
                                 manualSteps: ["Open System Settings › Lock Screen", "Set “Require password…” to Immediately"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: sysadminctl -screenLock status", "Expect: “screenLock delay is immediate”"],
        collect: { await run($0, "/usr/sbin/sysadminctl", ["-screenLock", "status"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            if t.contains("screenlock delay is immediate") { return .pass("Password is required immediately.") }
            if t.contains("screenlock is off") || t.contains("screenlock delay is off") { return .issue(.medium, "No password is required after sleep or screen saver.") }
            if let r = t.range(of: "screenlock delay is "), let seconds = Int(t[r.upperBound...].prefix { $0.isNumber }) {
                if seconds <= 5 { return .pass("Password required after \(seconds) s.") }
                return .issue(seconds > 300 ? .medium : .low, "Password is required only after \(seconds) s.")
            }
            return .couldNotRun("Unrecognised output from sysadminctl.")
        })

    static let loginWindowPlist = "/Library/Preferences/com.apple.loginwindow.plist"

    static func loginWindowEvidence(_ key: String) -> CollectedEvidence {
        let (ev, dict) = plist(loginWindowPlist)
        guard let dict else { return ev }
        let text: String
        if key == "autoLoginUser" {
            text = dict["autoLoginUser"] != nil ? "autoLoginUser = (set)" : "autoLoginUser = (not set)"
        } else {
            text = "GuestEnabled = \(dict["GuestEnabled"].map { "\($0)" } ?? "(not set)")"
        }
        return CollectedEvidence(items: [EvidenceItem(source: "read plist \(loginWindowPlist) key \(key)", output: text)], raw: text)
    }

    static let autoLogin = SecurityCheck(
        id: "auto-login", title: "Automatic Login", component: "Users & Groups", category: "ACCESS CONTROL",
        requiredPermissions: [], evidenceMethod: "Read \(loginWindowPlist) (native)", timeoutSeconds: 5,
        whyItMatters: "Automatic login starts a session without a password, so anyone who powers on the Mac gets your account.",
        limitations: ["MDM profiles can override this setting.", "FileVault normally disables automatic login."],
        remediation: Remediation(summary: "Turn off automatic login.",
                                 exactChange: "System Settings › Users & Groups › Automatically log in as: Off",
                                 operationID: nil,
                                 manualSteps: ["Open System Settings › Users & Groups", "Set “Automatically log in as” to Off"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check", "Expect autoLoginUser not set"],
        collect: { _ in loginWindowEvidence("autoLoginUser") },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            if ev.raw.isEmpty { return .pass("Login window preferences not present; automatic login is off.", confidence: .medium) }
            return ev.raw.contains("(set)") && !ev.raw.contains("not set") ? .issue(.high, "Automatic login is configured.") : .pass("Automatic login is off.")
        })

    static let guestAccount = SecurityCheck(
        id: "guest-account", title: "Guest Account", component: "Users & Groups", category: "ACCESS CONTROL",
        requiredPermissions: [], evidenceMethod: "Read \(loginWindowPlist) (native)", timeoutSeconds: 5,
        whyItMatters: "An enabled guest account lets anyone with physical access start a session on this Mac.",
        limitations: ["MDM profiles can override this setting."],
        remediation: Remediation(summary: "Disable the guest account.",
                                 exactChange: "/usr/sbin/sysadminctl -guestAccount off  (as administrator)",
                                 operationID: "security.disable_guest_account",
                                 manualSteps: ["Open System Settings › Users & Groups", "Turn off the Guest User"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check", "Expect GuestEnabled = false"],
        collect: { _ in loginWindowEvidence("GuestEnabled") },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            if ev.raw.contains("GuestEnabled = 1") || ev.raw.contains("GuestEnabled = true") { return .issue(.low, "The guest account is enabled.") }
            return .pass(ev.raw.isEmpty || ev.raw.contains("not set") ? "Guest account is not enabled (default)." : "Guest account is disabled.",
                         confidence: ev.raw.contains("not set") || ev.raw.isEmpty ? .medium : .high)
        })

    static func remoteService(id: String, title: String, label: String, settings: String, operationID: String? = nil) -> SecurityCheck {
        SecurityCheck(
            id: id, title: title, component: "Sharing › \(title)", category: "EXPOSED SERVICES",
            requiredPermissions: [], evidenceMethod: "launchctl print system/\(label) (sandboxed)", timeoutSeconds: 10,
            whyItMatters: "\(title) accepts connections from other devices. If you do not use it, turning it off removes an attack surface.",
            limitations: ["Inferred from whether the launchd service is loaded; confidence is medium.",
                          "Being enabled is not a vulnerability if you need it and use strong credentials."],
            remediation: Remediation(summary: "Turn off \(title) if you do not use it.",
                                     exactChange: operationID == nil ? "System Settings › General › \(settings): Off" : "/usr/sbin/systemsetup -f -setremotelogin off  (as administrator)",
                                     operationID: operationID,
                                     manualSteps: ["Open System Settings › General › Sharing", "Turn off \(title)"],
                                     settingsURL: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                                     reversible: true, requiresConfirmation: true),
            verificationSteps: ["Re-run this check", "Expect the \(label) service not to be loaded"],
            collect: { await run($0, "/bin/launchctl", ["print", "system/\(label)"]) },
            evaluate: { ev in
                if let f = ev.failure { return .couldNotRun(f) }
                let t = ev.raw.lowercased()
                if t.contains("could not find service") { return .pass("\(title) is off (service not loaded).", confidence: .medium) }
                if t.contains("system/\(label.lowercased()) = {") || t.contains("state =") {
                    return .issue(.low, "\(title) is enabled (service loaded).", confidence: .medium)
                }
                return .couldNotRun("Unrecognised output from launchctl.")
            })
    }

    static let listeningServices = SecurityCheck(
        id: "listening-services", title: "Listening Network Services", component: "Network › Listening sockets", category: "EXPOSED SERVICES",
        requiredPermissions: [], evidenceMethod: "lsof -nP -iTCP -sTCP:LISTEN (sandboxed)", timeoutSeconds: 20,
        whyItMatters: "Services listening on all interfaces can be reached from the local network unless the firewall blocks them.",
        limitations: ["Without administrator rights, lsof only shows processes owned by the current user.",
                      "Listening is not itself a vulnerability; review whether each service is expected."],
        remediation: Remediation(summary: "Quit or reconfigure services you do not need, or enable the firewall.",
                                 exactChange: "Review the listed processes; stop unneeded ones (process.terminate) or bind them to 127.0.0.1",
                                 operationID: nil,
                                 manualSteps: ["Identify each listed process", "Quit apps you do not need listening", "Keep the Application Firewall enabled"],
                                 settingsURL: nil, reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check", "Expect fewer services bound to * / 0.0.0.0"],
        collect: { await run($0, "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let rows = parseLsofListen(ev.raw)
            if rows.isEmpty {
                return ev.raw.isEmpty ? .pass("No listening TCP services visible to this user.", confidence: .medium)
                    : .couldNotRun("Unrecognised output from lsof.")
            }
            let exposed = rows.filter(\.allInterfaces)
            let names = Set(exposed.map { "\($0.command):\($0.port)" }).sorted()
            if exposed.isEmpty { return .observed("\(rows.count) listening sockets, all bound to loopback.") }
            return Evaluation(status: .issue, severity: .low, confidence: .medium,
                              note: "\(names.count) service(s) listen on all interfaces: " + names.prefix(12).joined(separator: ", "))
        })

    public struct ListenRow: Equatable, Sendable {
        public let command: String
        public let pid: String
        public let address: String
        public let port: String
        public var allInterfaces: Bool { address == "*" || address == "0.0.0.0" || address == "[::]" }
    }

    public static func parseLsofListen(_ text: String) -> [ListenRow] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, let nameIdx = cols.lastIndex(where: { $0.contains(":") }) else { return nil }
            let name = String(cols[nameIdx])
            guard let colon = name.lastIndex(of: ":") else { return nil }
            return ListenRow(command: String(cols[0]), pid: String(cols[1]), address: String(name[..<colon]),
                             port: String(name[name.index(after: colon)...]))
        }
    }

    static func launchItems(home: String) -> SecurityCheck {
        let dirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents", (home as NSString).appendingPathComponent("Library/LaunchAgents")]
        return SecurityCheck(
            id: "launch-items", title: "Third-Party Launch Items", component: "Persistence › launchd", category: "PERSISTENCE",
            requiredPermissions: [], evidenceMethod: "Enumerate launchd plists (native) + codesign --verify on each program (sandboxed)",
            timeoutSeconds: 60,
            whyItMatters: "Launch agents and daemons start automatically. Unexpected, unsigned or user-writable system items deserve review.",
            limitations: ["Lists items; it does not judge whether software is malicious.",
                          "Background items registered through SMAppService are not included."],
            remediation: Remediation(summary: "Review unexpected items and remove software you do not recognise.",
                                     exactChange: "System Settings › General › Login Items & Extensions: disable unwanted background items",
                                     operationID: nil,
                                     manualSteps: ["Review each listed item and its program path", "Uninstall software you do not recognise", "Fix ownership of writable system launch items (should be root:wheel, 644)"],
                                     settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                                     reversible: true, requiresConfirmation: true),
            verificationSteps: ["Re-run this check"],
            collect: { runner in
                var lines: [String] = []
                var rawFlags: [String] = []
                var checked = 0
                for dir in dirs {
                    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                    for file in files.sorted() where file.hasSuffix(".plist") && !file.hasPrefix("com.apple.") {
                        let path = (dir as NSString).appendingPathComponent(file)
                        let dict = NSDictionary(contentsOfFile: path) as? [String: Any]
                        let program = (dict?["Program"] as? String) ?? ((dict?["ProgramArguments"] as? [String])?.first) ?? "?"
                        var flags: [String] = []
                        var st = stat()
                        if stat(path, &st) == 0, dir.hasPrefix("/Library") {
                            if st.st_uid != 0 { flags.append("NOT-ROOT-OWNED") }
                            if st.st_mode & 0o022 != 0 { flags.append("GROUP/WORLD-WRITABLE") }
                        }
                        if program != "?" && program.hasPrefix("/") && !FileManager.default.fileExists(atPath: program) {
                            flags.append("PROGRAM-MISSING")
                        } else if program.hasPrefix("/"), checked < 25 {
                            checked += 1
                            let r = try? await runner.run(ProcessRunRequest(executable: "/usr/bin/codesign", arguments: ["--verify", "--", program],
                                                                            timeout: 15, maxOutputBytes: 16 * 1024, sandbox: .readOnlyNoNetwork), sink: .discard)
                            if let r, r.exitCode != 0 { flags.append("SIGNATURE-INVALID-OR-UNSIGNED") }
                        }
                        lines.append("\(path) → \(program)" + (flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"))
                        rawFlags.append(contentsOf: flags)
                    }
                }
                let text = lines.isEmpty ? "No third-party launch items found." : lines.joined(separator: "\n")
                let shown = Redactor().redact(text)
                return CollectedEvidence(items: [EvidenceItem(source: "enumerate " + dirs.map { Redactor().redact($0) }.joined(separator: ", "), output: shown, sandboxed: true)],
                                         raw: text + "\nFLAGS:" + rawFlags.joined(separator: ","))
            },
            evaluate: { ev in
                if let f = ev.failure { return .couldNotRun(f) }
                let count = ev.raw.split(separator: "\n").filter { $0.contains(" → ") }.count
                if ev.raw.contains("GROUP/WORLD-WRITABLE") || ev.raw.contains("NOT-ROOT-OWNED") {
                    return .issue(.high, "A system launch item is writable by non-root users — a privilege-escalation risk.")
                }
                if ev.raw.contains("SIGNATURE-INVALID-OR-UNSIGNED") {
                    return Evaluation(status: .issue, severity: .low, confidence: .medium,
                                      note: "At least one launch item runs a program that failed code-signature verification. Review it.")
                }
                if ev.raw.contains("PROGRAM-MISSING") {
                    return Evaluation(status: .issue, severity: .low, confidence: .high, note: "At least one launch item points to a missing program (leftover from uninstalled software).")
                }
                return .observed(count == 0 ? "No third-party launch items." : "\(count) third-party launch item(s); all signed and correctly owned.")
            })
    }

    static func homePermissions(home: String) -> SecurityCheck {
        SecurityCheck(
            id: "home-permissions", title: "Home & SSH Permissions", component: "File permissions", category: "DATA PROTECTION",
            requiredPermissions: [], evidenceMethod: "stat() on the home folder, ~/.ssh and its files (native; contents never read)",
            timeoutSeconds: 5,
            whyItMatters: "World-accessible home folders or SSH private keys let other local accounts or processes read sensitive data.",
            limitations: ["Checks POSIX modes only; ACLs are not evaluated.", "File contents are never read."],
            remediation: Remediation(summary: "Restrict permissions on ~/.ssh and private keys.",
                                     exactChange: "chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_* (private keys only)",
                                     operationID: "security.fix_ssh_permissions",
                                     manualSteps: ["If your home folder itself is world-writable, run: chmod o-w ~"],
                                     settingsURL: nil, reversible: true, requiresConfirmation: true),
            verificationSteps: ["Re-run this check"],
            collect: { _ in
                var lines: [String] = []
                func mode(_ path: String) -> mode_t? {
                    var st = stat()
                    return lstat(path, &st) == 0 ? st.st_mode : nil
                }
                if let m = mode(home) { lines.append(String(format: "~ mode %o", m & 0o777)) }
                let ssh = (home as NSString).appendingPathComponent(".ssh")
                if let m = mode(ssh) {
                    lines.append(String(format: "~/.ssh mode %o", m & 0o777))
                    for f in ((try? FileManager.default.contentsOfDirectory(atPath: ssh)) ?? []).sorted()
                    where f.hasPrefix("id_") && !f.hasSuffix(".pub") {
                        if let fm = mode((ssh as NSString).appendingPathComponent(f)) {
                            lines.append(String(format: "~/.ssh/%@ mode %o", f, fm & 0o777))
                        }
                    }
                } else {
                    lines.append("~/.ssh not present")
                }
                let text = lines.joined(separator: "\n")
                return CollectedEvidence(items: [EvidenceItem(source: "stat (native)", output: text)], raw: text)
            },
            evaluate: { ev in
                var problems: [(Severity, String)] = []
                for line in ev.raw.split(separator: "\n") {
                    let parts = line.split(separator: " ")
                    guard parts.count == 3, parts[1] == "mode", let m = Int(parts[2], radix: 8) else { continue }
                    let item = String(parts[0])
                    if item == "~" {
                        if m & 0o002 != 0 { problems.append((.high, "home folder is world-writable")) }
                    } else if item == "~/.ssh" {
                        if m & 0o077 != 0 { problems.append((.medium, "~/.ssh is accessible to other users")) }
                    } else if m & 0o077 != 0 {
                        problems.append((.high, "\(item) (private key) is readable by other users"))
                    }
                }
                guard !problems.isEmpty else { return .pass("Home and SSH permissions are restrictive.") }
                let sev = problems.map(\.0).max() ?? .low
                return .issue(sev, problems.map(\.1).joined(separator: "; ").capitalizedFirst + ".")
            })
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
