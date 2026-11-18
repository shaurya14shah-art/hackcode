import Foundation
import Darwin

extension OperationRegistry {
    static let globPattern = "^[A-Za-z0-9*?._ ()\\[\\]+-]{1,64}$"
    static let fileNamePattern = "^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,200}$"

    /// Hides hardware identifiers (serial numbers, UUIDs) from output that would otherwise contain them.
    static let hideIdentifiers: @Sendable (String) -> String = { text in
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let lower = line.lowercased()
            // Any "label: value" line whose label names a serial number or UUID (e.g. "Serial Number (system):").
            if let colon = line.firstIndex(of: ":") {
                let label = lower[..<lower.index(lower.startIndex, offsetBy: line.distance(from: line.startIndex, to: colon))]
                if ["serial", "uuid", "udid"].contains(where: { label.contains($0) }) {
                    return String(line[...colon]) + " [hidden by HackCode]"
                }
            }
            return String(line)
        }.joined(separator: "\n")
    }

    static func extendedOperations(_ deps: OperationDependencies, pid: ParameterSpec) -> [OperationSpec] {
        let path = { (help: String) in ParameterSpec("path", .readablePath, required: true, help: help) }
        let host = ParameterSpec("host", .host, required: true, help: "hostname or IPv4 address")
        return [
            // ---------------- Diagnostics ----------------
            OperationSpec(id: "system.hardware", title: "Hardware overview",
                          summary: "Model, chip, cores, memory and firmware (system_profiler); serial numbers and UUIDs are hidden.",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 30,
                          action: .process(executable: "/usr/sbin/system_profiler", sandbox: .readOnlyNoNetwork) { _, _ in ["SPHardwareDataType"] },
                          outputFilter: hideIdentifiers),
            OperationSpec(id: "system.battery", title: "Battery & power",
                          summary: "Charge, charging state, time remaining, cycle count, health, and the power source (IOKit + pmset).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .native { _, _, _ in NativeTools.batteryReport() }),
            OperationSpec(id: "system.power_assertions", title: "Sleep blockers",
                          summary: "Which processes are preventing sleep or display sleep (pmset -g assertions).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/bin/pmset", sandbox: .readOnlyNoNetwork) { _, _ in ["-g", "assertions"] }),
            OperationSpec(id: "system.reboots", title: "Recent reboots & shutdowns",
                          summary: "Reboot and shutdown history from the login records (last).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/bin/last", sandbox: .readOnlyNoNetwork) { _, _ in ["reboot", "shutdown"] }),
            OperationSpec(id: "system.management_profiles", title: "Device management status",
                          summary: "Whether the Mac is enrolled in MDM / DEP (profiles status).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/bin/profiles", sandbox: .readOnlyNoNetwork) { _, _ in ["status", "-type", "enrollment"] }),
            OperationSpec(id: "disk.boot_volume_info", title: "Boot volume details",
                          summary: "File system, encryption, SMART status and capacity of the boot volume (diskutil info /).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/sbin/diskutil", sandbox: .readOnlyNoNetwork) { _, _ in ["info", "/"] },
                          outputFilter: hideIdentifiers),
            OperationSpec(id: "diagnostics.crash_reports", title: "Recent crash reports",
                          summary: "Lists the newest crash, hang and panic reports (yours and system-wide).",
                          parameters: [ParameterSpec("limit", .integer(1...60), default: .integer(20), help: "number of reports")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only",
                          action: .native { args, ctx, _ in NativeTools.crashReports(home: ctx.homeDirectory, limit: args.int("limit") ?? 20) }),
            OperationSpec(id: "diagnostics.crash_report", title: "Read crash report",
                          summary: "Shows the header and crashed-thread section of one crash report by file name (from diagnostics.crash_reports).",
                          parameters: [ParameterSpec("name", .token(pattern: fileNamePattern, maxLength: 200), required: true, help: "report file name")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads one report file",
                          maxOutputBytes: 64 * 1024,
                          action: .native { args, ctx, _ in try NativeTools.crashReport(name: args.string("name") ?? "", home: ctx.homeDirectory) },
                          outputFilter: hideIdentifiers),
            OperationSpec(id: "logs.system_errors", title: "Recent system-wide errors",
                          summary: "Unified-log faults and errors from all processes over the last N minutes, newest last.",
                          parameters: [ParameterSpec("minutes", .integer(1...30), default: .integer(5), help: "look-back window")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 90, maxOutputBytes: 128 * 1024,
                          action: .process(executable: "/usr/bin/log", sandbox: .none(reason: "the log tool refuses to run inside a sandbox; it is read-only")) { args, _ in
                              ["show", "--last", "\(args.int("minutes") ?? 5)m", "--style", "compact", "--predicate", "messageType == fault OR messageType == error"]
                          }),

            // ---------------- Processes & apps ----------------
            OperationSpec(id: "process.open_files", title: "Open files & sockets of a process",
                          summary: "Files, sockets and pipes one of your processes has open (lsof -p).",
                          parameters: [pid], baseRisk: .informational, isReadOnly: true, sideEffects: "none", maxOutputBytes: 128 * 1024,
                          action: .process(executable: "/usr/sbin/lsof", sandbox: .readOnlyNoNetwork) { args, _ in ["-nP", "-p", String(args.int("pid") ?? 0)] }),
            OperationSpec(id: "process.tree", title: "Process tree",
                          summary: "A process with its parent chain and child processes.",
                          parameters: [pid], baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .native { args, _, _ in NativeTools.processTree(pid_t(args.int("pid") ?? 0)) }),
            OperationSpec(id: "apps.list", title: "Installed applications",
                          summary: "Apps in /Applications and ~/Applications with version and bundle identifier.",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads app metadata only",
                          action: .native { _, ctx, _ in NativeTools.appsList(home: ctx.homeDirectory) }),
            OperationSpec(id: "app.quit", title: "Quit app gracefully",
                          summary: "Asks a running app (one of yours, with a user interface) to quit normally, so it can prompt to save documents.",
                          parameters: [pid], baseRisk: .elevated, isReadOnly: false, isReversible: false,
                          sideEffects: "the app quits after it finishes or asks you to save", timeoutSeconds: 15,
                          action: .native { args, _, _ in try await NativeTools.quitApp(pid: pid_t(args.int("pid") ?? 0), pinnedStart: args.pinnedStart("pid")) },
                          riskEvaluator: { args, ctx in
                              let p = pid_t(args.int("pid") ?? 0)
                              if p == ctx.ownPID { return RiskAssessment(.critical, ["HackCode will not quit itself this way."]) }
                              if ProcessSampler.owner(of: p) != ctx.currentUID { return RiskAssessment(.critical, ["pid \(p) is not your process."]) }
                              let name = ProcessSampler.name(for: p)
                              if protectedProcessNames.contains(name) { return RiskAssessment(.critical, ["\(name) is a protected system process."]) }
                              return RiskAssessment(.elevated, ["Asks \(name) (pid \(p)) to quit; it may prompt to save."])
                          }),

            // ---------------- Files ----------------
            OperationSpec(id: "files.find", title: "Find files by name",
                          summary: "Finds files whose names match a glob pattern (e.g. *.dmg) inside a folder.",
                          parameters: [path("folder to search"),
                                       ParameterSpec("pattern", .token(pattern: globPattern, maxLength: 64), required: true, help: "glob such as *.dmg or report*"),
                                       ParameterSpec("limit", .integer(1...200), default: .integer(50), help: "max results")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only", timeoutSeconds: 60,
                          action: .native { args, ctx, _ in
                              try NativeTools.find(root: args.string("path") ?? "", pattern: args.string("pattern") ?? "*",
                                                   limit: args.int("limit") ?? 50, excluded: ctx.excludedPrefixes)
                          }),
            OperationSpec(id: "files.stale", title: "Old files (cleanup candidates)",
                          summary: "Large files in a folder not modified for at least N days, biggest first.",
                          parameters: [path("folder to inspect, e.g. ~/Downloads"),
                                       ParameterSpec("days", .integer(7...3650), default: .integer(90), help: "minimum age in days"),
                                       ParameterSpec("limit", .integer(1...100), default: .integer(25), help: "max results")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only", timeoutSeconds: 60,
                          action: .native { args, ctx, _ in
                              try NativeTools.stale(root: args.string("path") ?? "", days: args.int("days") ?? 90,
                                                    limit: args.int("limit") ?? 25, excluded: ctx.excludedPrefixes)
                          }),
            OperationSpec(id: "files.duplicates", title: "Duplicate files",
                          summary: "Finds identical files (same size and SHA-256) of at least 1 MB inside a folder and reports wasted space.",
                          parameters: [path("folder to inspect"),
                                       ParameterSpec("limit", .integer(1...100), default: .integer(20), help: "max duplicate groups")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads file contents to hash them (nothing is changed)",
                          timeoutSeconds: 180,
                          action: .native { args, ctx, sink in
                              try await NativeTools.duplicates(root: args.string("path") ?? "", limit: args.int("limit") ?? 20,
                                                               excluded: ctx.excludedPrefixes, sink: sink)
                          }),
            OperationSpec(id: "files.hash", title: "File checksum",
                          summary: "SHA-256 of a file, e.g. to compare a download against a published checksum.",
                          parameters: [path("file to hash")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads the file", timeoutSeconds: 120,
                          action: .native { args, _, _ in try NativeTools.hash(args.string("path") ?? "") }),
            OperationSpec(id: "files.cache_sizes", title: "Cache folder sizes",
                          summary: "Size of each folder in ~/Library/Caches (du). Caches are safe to remove but apps will rebuild them.",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only", timeoutSeconds: 90,
                          action: .process(executable: "/usr/bin/du", sandbox: .readOnlyNoNetwork) { _, ctx in
                              ["-d", "1", "-k", "-x", "--", (ctx.homeDirectory as NSString).appendingPathComponent("Library/Caches")]
                          }),

            // ---------------- Security tools ----------------
            OperationSpec(id: "security.assess_app", title: "Gatekeeper assessment",
                          summary: "Asks Gatekeeper whether an app or file would be allowed to run, and why (spctl --assess).",
                          parameters: [path("app or file to assess")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 60,
                          action: .process(executable: "/usr/sbin/spctl", sandbox: .readOnlyNoNetwork) { args, _ in
                              ["--assess", "--type", "execute", "-vv", args.string("path") ?? ""]
                          }),
            OperationSpec(id: "security.file_signature", title: "Code signature of a file",
                          summary: "Signing identity, team and hardened-runtime flags of an app or binary (codesign -dv).",
                          parameters: [path("app or binary")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 30,
                          action: .process(executable: "/usr/bin/codesign", sandbox: .readOnlyNoNetwork) { args, _ in
                              ["-dv", "--verbose=2", "--", args.string("path") ?? ""]
                          }),
            OperationSpec(id: "security.quarantine_info", title: "Download origin (quarantine)",
                          summary: "Whether a file carries the macOS quarantine flag, which app downloaded it and when.",
                          parameters: [path("downloaded file")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .native { args, _, _ in NativeTools.quarantine(args.string("path") ?? "") }),
            OperationSpec(id: "security.firewall_apps", title: "Firewall app rules",
                          summary: "Apps with explicit Application Firewall rules (allowed or blocked incoming connections).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw", sandbox: .readOnlyNoNetwork) { _, _ in ["--listapps"] }),
            OperationSpec(id: "security.admin_accounts", title: "Administrator accounts",
                          summary: "Members of the admin group (dscl).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/bin/dscl", sandbox: .readOnlyNoNetwork) { _, _ in [".", "-read", "/Groups/admin", "GroupMembership"] }),

            // ---------------- Network diagnostics ----------------
            OperationSpec(id: "network.connections", title: "Established connections",
                          summary: "Your processes' open TCP connections and their remote endpoints (lsof).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none", maxOutputBytes: 128 * 1024,
                          action: .process(executable: "/usr/sbin/lsof", sandbox: .readOnlyNoNetwork) { _, _ in ["-nP", "-iTCP", "-sTCP:ESTABLISHED"] }),
            OperationSpec(id: "network.port_owner", title: "What is using a port",
                          summary: "Which of your processes is listening on a TCP port on this Mac (lsof) — e.g. why a dev server cannot bind port 3000.",
                          parameters: [ParameterSpec("port", .integer(1...65535), required: true, help: "TCP port number")],
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          requiredPermissions: ["Other users' sockets are only visible to administrators"],
                          action: .process(executable: "/usr/sbin/lsof", sandbox: .readOnlyNoNetwork) { args, _ in
                              ["-nP", "-iTCP:\(args.int("port") ?? 0)", "-sTCP:LISTEN"]
                          },
                          outputFilter: { out in
                              out.isEmpty ? "Nothing visible to you is listening on that TCP port. (If a server still reports it is in use, another user's or a system process may own it.)" : out
                          }),
            OperationSpec(id: "network.dns_config", title: "DNS configuration",
                          summary: "Resolvers, search domains and scoped DNS (scutil --dns).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/sbin/scutil", sandbox: .readOnlyNoNetwork) { _, _ in ["--dns"] }),
            OperationSpec(id: "network.routes", title: "Routing table",
                          summary: "IPv4 routes and default gateway (netstat -rn).",
                          baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                          action: .process(executable: "/usr/sbin/netstat", sandbox: .readOnlyNoNetwork) { _, _ in ["-rn", "-f", "inet"] }),
            OperationSpec(id: "network.dns_lookup", title: "DNS lookup",
                          summary: "Resolves a hostname through the system resolver (dscacheutil).",
                          parameters: [host], baseRisk: .low, isReadOnly: true, sideEffects: "sends a DNS query", timeoutSeconds: 15,
                          action: .process(executable: "/usr/bin/dscacheutil", sandbox: .readOnlyWithNetwork) { args, _ in
                              ["-q", "host", "-a", "name", args.string("host") ?? ""]
                          }),
            OperationSpec(id: "network.reachability", title: "Ping a host",
                          summary: "Sends up to 5 ICMP echo requests to one host to check reachability and latency. Not a scan.",
                          parameters: [host, ParameterSpec("count", .integer(1...5), default: .integer(3), help: "packets")],
                          baseRisk: .low, isReadOnly: true, sideEffects: "sends a few ping packets to that host", timeoutSeconds: 20,
                          action: .process(executable: "/sbin/ping", sandbox: .readOnlyWithNetwork) { args, _ in
                              ["-c", String(args.int("count") ?? 3), "-t", "10", "--", args.string("host") ?? ""]
                          }),

            // ---------------- Remediation (scoped) ----------------
            OperationSpec(id: "security.fix_ssh_permissions", title: "Restrict SSH key permissions",
                          summary: "Sets ~/.ssh to 700 and private keys (id_*, no .pub) to 600. Only changes permission bits on your own files.",
                          baseRisk: .elevated, isReadOnly: false, isReversible: true,
                          sideEffects: "other local users lose read access to ~/.ssh", timeoutSeconds: 10,
                          action: .native { _, ctx, _ in try NativeTools.fixSSHPermissions(home: ctx.homeDirectory) }),
            OperationSpec(id: "network.flush_dns_cache", title: "Flush DNS cache",
                          summary: "Clears the macOS DNS cache (dscacheutil -flushcache; killall -HUP mDNSResponder). Requires your administrator password.",
                          baseRisk: .critical, isReadOnly: false, isReversible: true,
                          sideEffects: "cached DNS answers are discarded and re-resolved", requiredPermissions: ["Administrator password (macOS prompt)"],
                          timeoutSeconds: 120,
                          action: .privilegedFixedCommand("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")),
            OperationSpec(id: "security.enable_gatekeeper", title: "Enable Gatekeeper",
                          summary: "Re-enables Gatekeeper assessments (spctl --global-enable). Requires your administrator password.",
                          baseRisk: .critical, isReadOnly: false, isReversible: true,
                          sideEffects: "apps that are not signed/notarized are blocked again", requiredPermissions: ["Administrator password (macOS prompt)"],
                          timeoutSeconds: 120,
                          action: .privilegedFixedCommand("/usr/sbin/spctl --global-enable")),
            OperationSpec(id: "security.disable_guest_account", title: "Disable guest account",
                          summary: "Turns off the guest user (sysadminctl -guestAccount off). Requires your administrator password.",
                          baseRisk: .critical, isReadOnly: false, isReversible: true,
                          sideEffects: "the Guest User can no longer log in", requiredPermissions: ["Administrator password (macOS prompt)"],
                          timeoutSeconds: 120,
                          action: .privilegedFixedCommand("/usr/sbin/sysadminctl -guestAccount off")),
            OperationSpec(id: "security.enable_security_updates", title: "Enable automatic security updates",
                          summary: "Turns on automatic update checks, Rapid Security Responses and system data files (XProtect). Requires your administrator password.",
                          baseRisk: .critical, isReadOnly: false, isReversible: true,
                          sideEffects: "macOS installs security responses and XProtect data automatically", requiredPermissions: ["Administrator password (macOS prompt)"],
                          timeoutSeconds: 120,
                          action: .privilegedFixedCommand("/usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true; /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true; /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true")),
            OperationSpec(id: "security.disable_remote_login", title: "Turn off Remote Login (SSH)",
                          summary: "Disables the SSH server (systemsetup -f -setremotelogin off). Requires your administrator password; macOS may also require Full Disk Access.",
                          baseRisk: .critical, isReadOnly: false, isReversible: true,
                          sideEffects: "SSH connections to this Mac are refused", requiredPermissions: ["Administrator password (macOS prompt)", "Possibly Full Disk Access"],
                          timeoutSeconds: 120,
                          action: .privilegedFixedCommand("/usr/sbin/systemsetup -f -setremotelogin off")),
        ]
    }
}
