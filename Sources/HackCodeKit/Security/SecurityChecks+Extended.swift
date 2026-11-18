import Foundation

extension SecurityToolRegistry {
    static let xprotectPlist = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"

    static let xprotect = SecurityCheck(
        id: "xprotect", title: "XProtect Definitions", component: "Malware protection", category: "PATCHING",
        requiredPermissions: [], evidenceMethod: "Read XProtect.bundle Info.plist + modification date (native)", timeoutSeconds: 5,
        whyItMatters: "XProtect is macOS's built-in malware signature scanner; stale definitions miss recent threats.",
        limitations: ["Age is taken from the bundle's modification date.", "Apple ships definitions on its own schedule; a few weeks is normal."],
        remediation: Remediation(summary: "Allow system data file updates so XProtect stays current.",
                                 exactChange: "Enable “Install Security Responses and system files” (see Automatic Security Updates)",
                                 operationID: "security.enable_security_updates",
                                 manualSteps: ["Open System Settings › General › Software Update › Automatic Updates", "Enable security responses and system files"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check after the next update cycle"],
        collect: { _ in
            let (ev, dict) = plist(xprotectPlist)
            guard let dict else { return ev }
            let version = dict["CFBundleShortVersionString"] as? String ?? "?"
            let mod = (try? FileManager.default.attributesOfItem(atPath: xprotectPlist)[.modificationDate] as? Date) ?? nil
            let days = mod.map { Int(Date().timeIntervalSince($0) / 86_400) }
            let text = "version = \(version)\nupdated = \(mod?.formatted(date: .abbreviated, time: .omitted) ?? "unknown")\nageDays = \(days.map(String.init) ?? "unknown")"
            return CollectedEvidence(items: [EvidenceItem(source: "read \(xprotectPlist)", output: text)], raw: text)
        },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            guard let line = ev.raw.split(separator: "\n").first(where: { $0.hasPrefix("ageDays = ") }),
                  let days = Int(line.dropFirst(10)) else { return .couldNotRun("XProtect bundle not found or unreadable.") }
            if days > 120 { return .issue(.medium, "XProtect definitions are \(days) days old.", confidence: .medium) }
            if days > 60 { return .issue(.low, "XProtect definitions are \(days) days old.", confidence: .medium) }
            return .pass("XProtect definitions updated \(days) days ago.")
        })

    static let wifiSecurity = SecurityCheck(
        id: "wifi-security", title: "Wi-Fi Encryption", component: "Network › Wi-Fi", category: "NETWORK",
        requiredPermissions: [], evidenceMethod: "CoreWLAN current-association security type (native, no network name)", timeoutSeconds: 5,
        whyItMatters: "On an open, WEP or WPA network, people nearby can read or tamper with unencrypted traffic or crack the key.",
        limitations: ["Describes the network joined right now; other saved networks are not checked.",
                      "HackCode does not read the network name (that needs Location permission)."],
        remediation: Remediation(summary: "Use WPA2 (AES) or WPA3 networks; on open networks use a VPN.",
                                 exactChange: "Router: set security to WPA2-AES or WPA3 · This Mac: forget weak networks in Wi-Fi settings",
                                 operationID: nil,
                                 manualSteps: ["If it is your router, change its security mode to WPA2 (AES) or WPA3 in its admin page",
                                               "Otherwise prefer another network, or use a VPN on this one",
                                               "System Settings › Wi-Fi › Advanced: remove saved open/WEP networks so the Mac does not auto-join them"],
                                 settingsURL: "x-apple.systempreferences:com.apple.wifi-settings-extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check while connected to the network"],
        collect: { _ in
            guard let s = WiFiMetrics.current() else {
                return CollectedEvidence(items: [EvidenceItem(source: "CoreWLAN", output: "No Wi-Fi interface.")], raw: "hardware = none")
            }
            return CollectedEvidence(items: [EvidenceItem(source: "CoreWLAN CWWiFiClient.interface()", output: s.evidenceText)], raw: s.evidenceText)
        },
        evaluate: { ev in evaluateWiFi(ev) })

    static func evaluateWiFi(_ ev: CollectedEvidence) -> Evaluation {
        if let f = ev.failure { return .couldNotRun(f) }
        if ev.raw.contains("hardware = none") { return .observed("This Mac has no Wi-Fi interface.") }
        if ev.raw.contains("associated = no") { return .observed("Not connected to a Wi-Fi network right now.") }
        func value(_ key: String) -> String? {
            ev.raw.split(separator: "\n").first { $0.hasPrefix(key + " = ") }.map { String($0.dropFirst(key.count + 3)) }
        }
        guard let security = value("security"), let strength = value("strength") else { return .couldNotRun("Unrecognised Wi-Fi evidence.") }
        switch strength {
        case "WEAK":
            let sev: Severity = security.hasPrefix("Open") || security == "WEP" ? .high : .medium
            return .issue(sev, "Connected with \(security) — weak or no encryption.")
        case "FAIR": return .issue(.low, "Connected with \(security).", confidence: .medium)
        case "GOOD", "STRONG": return .pass("Connected with \(security).")
        default: return .couldNotRun("macOS did not report the Wi-Fi security type.")
        }
    }

    static let firewallAllowedApps = SecurityCheck(
        id: "firewall-apps", title: "Apps Allowed Through Firewall", component: "Network › Firewall", category: "EXPOSED SERVICES",
        requiredPermissions: [], evidenceMethod: "socketfilterfw --listapps (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "Each app allowed to accept incoming connections is reachable from the network while the firewall is on.",
        limitations: ["Rules only take effect while the Application Firewall is enabled.", "Inventory only; allowing an app is not itself a problem."],
        remediation: nil, verificationSteps: [],
        collect: { await run($0, firewallTool, ["--listapps"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let allowed = ev.raw.components(separatedBy: "(Allow incoming connections)").count - 1
            let blocked = ev.raw.components(separatedBy: "(Block incoming connections)").count - 1
            guard ev.raw.contains("Total number of apps") else { return .couldNotRun("Unrecognised output from socketfilterfw.") }
            return .observed("\(allowed) app(s) allowed and \(blocked) blocked for incoming connections.")
        })

    static let systemExtensions = SecurityCheck(
        id: "system-extensions", title: "System Extensions", component: "Persistence › Extensions", category: "PERSISTENCE",
        requiredPermissions: [], evidenceMethod: "systemextensionsctl list (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "System extensions (network filters, endpoint security, drivers) run with deep access; you should recognise each one.",
        limitations: ["Inventory only; it does not judge whether an extension is trustworthy.", "Legacy kernel extensions are not listed."],
        remediation: Remediation(summary: "Remove extensions you do not recognise by uninstalling their app.",
                                 exactChange: "System Settings › General › Login Items & Extensions",
                                 operationID: nil, manualSteps: ["Review each extension's team and bundle", "Uninstall the owning app if unrecognised"],
                                 settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run this check"],
        collect: { await run($0, "/usr/bin/systemextensionsctl", ["list"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            guard let first = ev.raw.split(separator: "\n").first, first.contains("extension(s)") else { return .couldNotRun("Unrecognised output from systemextensionsctl.") }
            let count = Int(first.split(separator: " ").first ?? "") ?? 0
            return .observed(count == 0 ? "No system extensions installed." : "\(count) system extension(s) installed — review the evidence list.")
        })

    static func appSignatures(home: String) -> SecurityCheck {
        SecurityCheck(
            id: "app-signatures", title: "Application Signatures", component: "Applications", category: "SYSTEM INTEGRITY",
            requiredPermissions: [], evidenceMethod: "codesign --verify on each app in /Applications and ~/Applications (sandboxed, max 120)",
            timeoutSeconds: 150,
            whyItMatters: "An app whose signature fails verification may have been modified after it was signed, or was never signed.",
            limitations: ["Shallow verification of the main executable (not --deep) to keep the audit fast.",
                          "A failed signature is a reason to investigate, not proof of tampering — some updaters modify bundles in place."],
            remediation: Remediation(summary: "Reinstall flagged apps from their official source, or remove them.",
                                     exactChange: "Reinstall or remove each app listed as INVALID",
                                     operationID: nil, manualSteps: ["Check each flagged app with security.assess_app", "Reinstall it from the developer or App Store"],
                                     settingsURL: nil, reversible: true, requiresConfirmation: true),
            verificationSteps: ["Re-run this check"],
            collect: { runner in
                var apps: [String] = []
                for dir in ["/Applications", (home as NSString).appendingPathComponent("Applications")] {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                    apps += names.filter { $0.hasSuffix(".app") }.sorted().map { "\(dir)/\($0)" }
                }
                apps = Array(apps.prefix(120))
                var results: [(String, Bool)] = []
                await withTaskGroup(of: (String, Bool).self) { group in
                    var it = apps.makeIterator()
                    for _ in 0..<6 { if let a = it.next() { group.addTask { (a, await verify(runner, a)) } } }
                    while let r = await group.next() {
                        results.append(r)
                        if let a = it.next() { group.addTask { (a, await verify(runner, a)) } }
                    }
                }
                let bad = results.filter { !$0.1 }.map(\.0).sorted()
                let text = "verified \(results.count) apps\n" + (bad.isEmpty ? "all signatures valid" : bad.map { "INVALID  \($0)" }.joined(separator: "\n"))
                return CollectedEvidence(items: [EvidenceItem(source: "codesign --verify (each app)", output: Redactor().redact(text), sandboxed: true)], raw: text)
            },
            evaluate: { ev in
                if let f = ev.failure { return .couldNotRun(f) }
                let bad = ev.raw.split(separator: "\n").filter { $0.hasPrefix("INVALID") }.count
                if bad == 0 { return .pass(ev.raw.split(separator: "\n").first.map(String.init).map { "\($0); all signatures valid." } ?? "All signatures valid.") }
                return Evaluation(status: .issue, severity: .low, confidence: .medium, note: "\(bad) app(s) failed signature verification.")
            })
    }

    static func verify(_ runner: ProcessRunning, _ app: String) async -> Bool {
        let r = try? await runner.run(ProcessRunRequest(executable: "/usr/bin/codesign", arguments: ["--verify", "--", app], timeout: 20,
                                                        maxOutputBytes: 16 * 1024, sandbox: .readOnlyNoNetwork), sink: .discard)
        return r?.exitCode == 0
    }

    static let adminAccounts = SecurityCheck(
        id: "admin-accounts", title: "Administrator Accounts", component: "Users & Groups", category: "ACCESS CONTROL",
        requiredPermissions: [], evidenceMethod: "dscl . -read /Groups/admin GroupMembership (sandboxed)", timeoutSeconds: 10,
        whyItMatters: "Every admin account can change system settings. Using a standard account day-to-day limits what malware running as you can do.",
        limitations: ["Inventory and guidance only; using an admin account is common and not a vulnerability by itself."],
        remediation: nil, verificationSteps: [],
        collect: { await run($0, "/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            guard let line = ev.raw.split(separator: "\n").first(where: { $0.hasPrefix("GroupMembership:") }) else { return .couldNotRun("Unrecognised dscl output.") }
            let members = line.dropFirst("GroupMembership:".count).split(separator: " ").map(String.init).filter { $0 != "root" && !$0.hasPrefix("_") }
            let me = NSUserName()
            return .observed("\(members.count) human admin account(s): \(members.joined(separator: ", "))." + (members.contains(me) ? " You are using an admin account." : ""))
        })

    static let backups = SecurityCheck(
        id: "backups", title: "Time Machine Backups", component: "Backups", category: "RESILIENCE",
        requiredPermissions: [], evidenceMethod: "tmutil destinationinfo (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "Backups are the main defence against ransomware, disk failure and accidental deletion.",
        limitations: ["Only Time Machine is detected; other backup tools are not seen, so confidence is medium."],
        remediation: Remediation(summary: "Configure a backup destination.",
                                 exactChange: "System Settings › General › Time Machine › Add Backup Disk",
                                 operationID: nil, manualSteps: ["Connect an external disk or network backup target", "Add it in System Settings › General › Time Machine"],
                                 settingsURL: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension",
                                 reversible: true, requiresConfirmation: true),
        verificationSteps: ["Re-run: tmutil destinationinfo"],
        collect: { await run($0, "/usr/bin/tmutil", ["destinationinfo"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            if ev.raw.contains("No destinations configured") { return Evaluation(status: .issue, severity: .low, confidence: .medium, note: "No Time Machine destination is configured.") }
            if ev.raw.contains("Name") || ev.raw.contains("Kind") { return .pass("A Time Machine destination is configured.") }
            return .couldNotRun("Unrecognised output from tmutil.")
        })

    static let deviceManagement = SecurityCheck(
        id: "device-management", title: "Device Management (MDM)", component: "Configuration profiles", category: "CONFIGURATION",
        requiredPermissions: [], evidenceMethod: "profiles status -type enrollment (sandboxed)", timeoutSeconds: 15,
        whyItMatters: "An MDM server can install profiles and change settings; you should know whether this Mac is managed and by whom.",
        limitations: ["Status only; installed profile contents are not read."],
        remediation: nil, verificationSteps: [],
        collect: { await run($0, "/usr/bin/profiles", ["status", "-type", "enrollment"]) },
        evaluate: { ev in
            if let f = ev.failure { return .couldNotRun(f) }
            let t = ev.raw.lowercased()
            guard t.contains("mdm enrollment") else { return .couldNotRun("Unrecognised output from profiles.") }
            return .observed(t.contains("mdm enrollment: no") ? "Not enrolled in MDM." : "This Mac is enrolled in device management.")
        })
}
