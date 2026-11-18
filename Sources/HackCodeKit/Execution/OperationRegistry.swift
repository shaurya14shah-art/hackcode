import Foundation
import Darwin

/// The closed set of operations HackCode can perform. Anything not registered here cannot run.
public struct OperationRegistry: Sendable {
    private let specs: [String: OperationSpec]
    public let ordered: [OperationSpec]

    public init(_ specs: [OperationSpec]) {
        var map: [String: OperationSpec] = [:]
        for s in specs {
            precondition(map[s.id] == nil, "duplicate operation id \(s.id)")
            map[s.id] = s
        }
        self.specs = map
        self.ordered = specs
    }

    /// Exact, case-sensitive lookup. No fuzzy matching: an unknown id is rejected.
    public func spec(for id: String) -> OperationSpec? { specs[id] }

    /// Compact catalogue given to the model so it can only propose registered operations.
    public func catalogForModel() -> String {
        ordered.map { spec in
            let params = spec.parameters.isEmpty ? "none" : spec.parameters.map {
                "\($0.name)\($0.isRequired ? "" : "?"): \($0.kind.schemaDescription)\($0.defaultValue.map { " (default \($0))" } ?? "") — \($0.help)"
            }.joined(separator: "; ")
            return "- \(spec.id) [\(spec.baseRisk.label)\(spec.isReadOnly ? ", read-only" : "")]: \(spec.summary) Params: \(params)"
        }.joined(separator: "\n")
    }
}

// MARK: - Standard registry

public struct OperationDependencies: Sendable {
    public let sampler: ProcessSampler
    public let audit: SecurityAuditService
    public init(sampler: ProcessSampler, audit: SecurityAuditService) {
        self.sampler = sampler
        self.audit = audit
    }
}

extension OperationRegistry {
    static let processNamePattern = "^[A-Za-z0-9][A-Za-z0-9._ ()+-]{0,63}$"
    static let launchdLabelPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    /// Processes HackCode refuses to signal regardless of ownership.
    static let protectedProcessNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "securityd", "trustd", "opendirectoryd", "coreservicesd", "mds", "mds_stores", "logd", "syslogd",
        "cfprefsd", "distnoted", "UserEventAgent", "powerd", "configd", "notifyd", "hidd", "sandboxd", "tccd",
        "HackCode",
    ]

    public static func standard(_ deps: OperationDependencies) -> OperationRegistry {
        let sampler = deps.sampler
        let audit = deps.audit
        let limit = ParameterSpec("limit", .integer(1...50), default: .integer(10), help: "number of rows")
        let pid = ParameterSpec("pid", .processID, required: true, help: "process id")

        return OperationRegistry(coreOperations(sampler: sampler, audit: audit, limit: limit, pid: pid)
                                 + extendedOperations(deps, pid: pid))
    }

    static func coreOperations(sampler: ProcessSampler, audit: SecurityAuditService, limit: ParameterSpec, pid: ParameterSpec) -> [OperationSpec] {
        [
            // ---------------- Informational ----------------
            OperationSpec(
                id: "system.overview", title: "System overview",
                summary: "macOS version, hardware model, uptime, load averages, CPU count and physical memory.",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                action: .native { _, _, _ in Native.systemOverview() }),

            OperationSpec(
                id: "process.top_cpu", title: "Top processes by CPU",
                summary: "Samples all processes twice, one second apart, and lists the highest CPU consumers.",
                parameters: [limit], baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                timeoutSeconds: 20,
                action: .native { args, _, _ in try await Native.topProcesses(sampler: sampler, byCPU: true, limit: args.int("limit") ?? 10) }),

            OperationSpec(
                id: "process.top_memory", title: "Top processes by memory",
                summary: "Lists processes with the largest resident memory (RSS).",
                parameters: [limit], baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                timeoutSeconds: 20,
                action: .native { args, _, _ in try await Native.topProcesses(sampler: sampler, byCPU: false, limit: args.int("limit") ?? 10) }),

            OperationSpec(
                id: "process.inspect", title: "Inspect process",
                summary: "Metadata for one process: path, parent, owner, start time, threads, memory, CPU time.",
                parameters: [pid], baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 20,
                action: .native { args, _, _ in try await Native.inspect(pid: pid_t(args.int("pid") ?? 0), sampler: sampler) }),

            OperationSpec(
                id: "process.code_signature", title: "Verify process code signature",
                summary: "Shows the code-signing identity and team of a running process's executable (codesign -dv).",
                parameters: [pid], baseRisk: .informational, isReadOnly: true, sideEffects: "none", timeoutSeconds: 20,
                action: .process(executable: "/usr/bin/codesign", sandbox: .readOnlyNoNetwork) { args, _ in
                    let p = pid_t(args.int("pid") ?? 0)
                    guard let path = ProcessSampler.path(for: p) else {
                        throw HackCodeError.invalidArgument(operation: "process.code_signature", argument: "pid",
                                                            reason: "no executable path is visible for pid \(p) (it may have exited or belong to another user)")
                    }
                    return ["-dv", "--verbose=2", "--", path]
                }),

            OperationSpec(
                id: "memory.overview", title: "Memory overview",
                summary: "Physical memory, used/app/wired/compressed memory, swap and memory pressure level.",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                action: .native { _, _, _ in Native.memoryOverview() }),

            OperationSpec(
                id: "disk.volumes", title: "Disk volumes",
                summary: "Capacity and free space of mounted volumes.",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                action: .native { _, _, _ in Native.volumes() }),

            OperationSpec(
                id: "files.largest", title: "Largest files in a folder",
                summary: "Walks a folder (no symlink following, bounded) and lists the largest files.",
                parameters: [ParameterSpec("path", .readablePath, required: true, help: "folder to scan, e.g. ~/Downloads"),
                             ParameterSpec("limit", .integer(1...50), default: .integer(15), help: "number of files"),
                             ParameterSpec("depth", .integer(1...10), default: .integer(5), help: "maximum folder depth")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only",
                requiredPermissions: ["Some folders (Desktop, Documents, Downloads) may prompt for Files & Folders access"],
                timeoutSeconds: 60,
                action: .native { args, ctx, sink in
                    try await Native.largestFiles(root: args.string("path") ?? "", limit: args.int("limit") ?? 15,
                                                  depth: args.int("depth") ?? 5, excluded: ctx.excludedPrefixes, sink: sink)
                }),

            OperationSpec(
                id: "files.folder_sizes", title: "Folder sizes",
                summary: "Size of each immediate subfolder (du -d 1 -k -x).",
                parameters: [ParameterSpec("path", .readablePath, required: true, help: "folder to measure")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only",
                timeoutSeconds: 90, maxOutputBytes: 128 * 1024,
                action: .process(executable: "/usr/bin/du", sandbox: .readOnlyNoNetwork) { args, _ in
                    ["-d", "1", "-k", "-x", "--", args.string("path") ?? ""]
                }),

            OperationSpec(
                id: "files.list", title: "List folder",
                summary: "Lists entries in a folder with size, type and modification date (max 500 entries).",
                parameters: [ParameterSpec("path", .readablePath, required: true, help: "folder to list")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "reads file metadata only",
                action: .native { args, _, _ in try Native.listFolder(args.string("path") ?? "") }),

            OperationSpec(
                id: "network.interfaces", title: "Network interfaces",
                summary: "Interface addresses, link state and cumulative traffic counters.",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                action: .native { _, _, _ in Native.interfaces() }),

            OperationSpec(
                id: "network.listening", title: "Listening TCP services",
                summary: "TCP sockets in LISTEN state for processes visible to the current user (lsof).",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                requiredPermissions: ["Other users' sockets are only visible to administrators"],
                action: .process(executable: "/usr/sbin/lsof", sandbox: .readOnlyNoNetwork) { _, _ in ["-nP", "-iTCP", "-sTCP:LISTEN"] }),

            OperationSpec(
                id: "launchd.service_status", title: "launchd service status",
                summary: "Shows the state, PID, last exit status and program of a launchd service (launchctl print).",
                parameters: [ParameterSpec("label", .token(pattern: launchdLabelPattern, maxLength: 128), required: true, help: "service label, e.g. com.apple.Finder"),
                             ParameterSpec("domain", .choice(["user", "system"]), default: .string("user"), help: "user (gui session) or system")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                action: .process(executable: "/bin/launchctl", sandbox: .readOnlyNoNetwork) { args, ctx in
                    let domain = args.string("domain") == "system" ? "system" : "gui/\(ctx.currentUID)"
                    return ["print", "\(domain)/\(args.string("label") ?? "")"]
                }),

            OperationSpec(
                id: "logs.process_errors", title: "Recent errors from a process",
                summary: "Unified log entries of type error/fault for one process over the last N minutes (log show).",
                parameters: [ParameterSpec("process", .token(pattern: processNamePattern, maxLength: 64), required: true, help: "process name, e.g. Finder"),
                             ParameterSpec("minutes", .integer(1...60), default: .integer(10), help: "look-back window")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                timeoutSeconds: 60, maxOutputBytes: 96 * 1024,
                action: .process(executable: "/usr/bin/log", sandbox: .none(reason: "the log tool refuses to run inside a sandbox; it is read-only")) { args, _ in
                    // The process name is restricted to a safe character set, so it cannot break out of the quoted predicate.
                    let name = args.string("process") ?? ""
                    return ["show", "--last", "\(args.int("minutes") ?? 10)m", "--style", "compact",
                            "--predicate", "process == \"\(name)\" AND (messageType == error OR messageType == fault)"]
                }),

            OperationSpec(
                id: "security.audit", title: "Security audit",
                summary: "Runs all registered read-only macOS security checks (firewall, FileVault, Gatekeeper, SIP, updates, screen lock, sharing, listening services, launch items, permissions).",
                baseRisk: .informational, isReadOnly: true, sideEffects: "none (checks are read-only)",
                timeoutSeconds: 180, maxOutputBytes: 128 * 1024,
                action: .native { _, _, sink in
                    let run = await audit.runAudit { f in sink.emit(.info, "\(f.status.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(f.title)\n") }
                    return Native.formatAudit(run)
                }),

            OperationSpec(
                id: "security.check", title: "Single security check",
                summary: "Runs one registered security check and reports its evidence and finding.",
                parameters: [ParameterSpec("check", .choice(audit.registry.checks.map(\.id)), required: true, help: "check id")],
                baseRisk: .informational, isReadOnly: true, sideEffects: "none",
                timeoutSeconds: 130,
                action: .native { args, _, _ in
                    guard let f = await audit.runCheck(id: args.string("check") ?? "") else { return "Unknown check." }
                    return Native.formatFinding(f)
                }),

            // ---------------- Low ----------------
            OperationSpec(
                id: "finder.reveal", title: "Reveal in Finder",
                summary: "Selects a file or folder in a Finder window.",
                parameters: [ParameterSpec("path", .readablePath, required: true, help: "item to reveal")],
                baseRisk: .low, isReadOnly: false, isReversible: true, sideEffects: "opens a Finder window",
                action: .process(executable: "/usr/bin/open", sandbox: .none(reason: "needs to ask Finder to open a window")) { args, _ in
                    // Path is validated, absolute and resolved, so it can never be read as an option.
                    ["-R", args.string("path") ?? ""]
                }),

            // ---------------- Elevated ----------------
            OperationSpec(
                id: "process.terminate", title: "Terminate process",
                summary: "Sends SIGTERM (or SIGINT) to one of your own processes so it can quit cleanly. Never SIGKILL, never other users' or system processes.",
                parameters: [pid, ParameterSpec("signal", .choice(["TERM", "INT"]), default: .string("TERM"), help: "TERM (quit) or INT (interrupt)")],
                baseRisk: .elevated, isReadOnly: false, isReversible: false,
                sideEffects: "the target process quits; unsaved work in it may be lost",
                timeoutSeconds: 10,
                action: .native { args, ctx, _ in
                    let p = pid_t(args.int("pid") ?? 0)
                    let sig = args.string("signal") == "INT" ? SIGINT : SIGTERM
                    // Final identity check immediately before signalling: same pid AND same start time.
                    guard ProcessSampler.startTime(of: p) == args.pinnedStart("pid") else {
                        throw HackCodeError.operationDenied(operation: "process.terminate", reason: "pid \(p) is no longer the approved process")
                    }
                    guard ProcessSampler.owner(of: p) == ctx.currentUID else {
                        throw HackCodeError.operationDenied(operation: "process.terminate", reason: "pid \(p) is not owned by you")
                    }
                    if kill(p, sig) != 0 { throw HackCodeError.permissionDenied("kill(\(p)): \(String(cString: strerror(errno)))") }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    return ProcessSampler.exists(p) ? "Signal sent to pid \(p); it is still running (it may be saving or ignoring the signal)."
                        : "Signal sent; pid \(p) has exited."
                },
                riskEvaluator: { args, ctx in
                    let p = pid_t(args.int("pid") ?? 0)
                    let name = ProcessSampler.name(for: p)
                    if p <= 1 || p == ctx.ownPID { return RiskAssessment(.critical, ["Refusing to signal pid \(p)."]) }
                    if !ProcessSampler.exists(p) { return RiskAssessment(.critical, ["No process with pid \(p) exists."]) }
                    guard let owner = ProcessSampler.owner(of: p) else { return RiskAssessment(.critical, ["The owner of pid \(p) cannot be determined."]) }
                    if owner != ctx.currentUID { return RiskAssessment(.critical, ["pid \(p) (\(name)) belongs to another user or the system."]) }
                    if protectedProcessNames.contains(name) { return RiskAssessment(.critical, ["\(name) is a protected system process."]) }
                    return RiskAssessment(.elevated, ["Will quit \(name.isEmpty ? "pid \(p)" : name) (pid \(p)); unsaved work may be lost."])
                }),

            OperationSpec(
                id: "files.move_to_trash", title: "Move to Trash",
                summary: "Moves one file or folder from Downloads/Desktop/Documents/Movies/Music/Pictures to the Trash (recoverable until the Trash is emptied).",
                parameters: [ParameterSpec("path", .trashablePath, required: true, help: "item to move to the Trash")],
                baseRisk: .elevated, isReadOnly: false, isReversible: true,
                sideEffects: "the item moves to the Trash and can be restored from there",
                timeoutSeconds: 30,
                action: .native { args, _, _ in
                    let path = args.string("path") ?? ""
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                    return "Moved to Trash: \(path)\nNow at: \(resulting?.path ?? "Trash")"
                },
                riskEvaluator: { args, _ in
                    let path = args.string("path") ?? ""
                    let size = Native.allocatedSize(path)
                    return RiskAssessment(.elevated, ["Moves \(path) (\(ByteFormat.string(size, .file))) to the Trash."])
                }),

            // ---------------- Critical (scoped privileged flow) ----------------
            OperationSpec(
                id: "security.enable_firewall", title: "Enable Application Firewall",
                summary: "Turns on the macOS Application Firewall. Requires your administrator password in a macOS prompt.",
                baseRisk: .critical, isReadOnly: false, isReversible: true,
                sideEffects: "incoming connections to apps are filtered by the firewall",
                requiredPermissions: ["Administrator password (macOS authorization prompt)"],
                timeoutSeconds: 120,
                action: .privilegedFixedCommand("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on")),

            OperationSpec(
                id: "security.enable_stealth_mode", title: "Enable firewall stealth mode",
                summary: "Turns on firewall stealth mode. Requires your administrator password in a macOS prompt.",
                baseRisk: .critical, isReadOnly: false, isReversible: true,
                sideEffects: "the Mac stops responding to ICMP ping and probes of closed ports",
                requiredPermissions: ["Administrator password (macOS authorization prompt)"],
                timeoutSeconds: 120,
                action: .privilegedFixedCommand("/usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on")),
        ]
    }
}

// MARK: - Native implementations

enum Native {
    static func systemOverview() -> String {
        let pi = ProcessInfo.processInfo
        var lines = ["macOS \(pi.operatingSystemVersionString)"]
        if let model = SystemMetrics.sysctlString("hw.model") { lines.append("Model: \(model)") }
        if let cpu = SystemMetrics.sysctlString("machdep.cpu.brand_string") { lines.append("CPU: \(cpu)") }
        lines.append("Logical CPUs: \(pi.processorCount) (\(pi.activeProcessorCount) active)")
        lines.append("Physical memory: \(MonitorObservations.bytes(pi.physicalMemory))")
        if let boot = SystemMetrics.bootTime() {
            let f = DateComponentsFormatter()
            f.allowedUnits = [.day, .hour, .minute]
            f.unitsStyle = .abbreviated
            lines.append("Uptime: \(f.string(from: Date().timeIntervalSince(boot)) ?? "?") (booted \(boot.formatted()))")
        }
        if let l = SystemMetrics.loadAverages() { lines.append(String(format: "Load averages: %.2f %.2f %.2f", l[0], l[1], l[2])) }
        lines.append("Thermal state: \(["nominal", "fair", "serious", "critical"][min(pi.thermalState.rawValue, 3)])")
        return lines.joined(separator: "\n")
    }

    static func topProcesses(sampler: ProcessSampler, byCPU: Bool, limit: Int) async throws -> String {
        _ = await sampler.sample()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let samples = await sampler.sample()
        let sorted = byCPU
            ? samples.filter { $0.cpuPercent != nil }.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
            : samples.filter { $0.residentBytes != nil }.sorted { ($0.residentBytes ?? 0) > ($1.residentBytes ?? 0) }
        var out = String(format: "%7@  %6@  %10@  %-10@  %@\n", "PID", "CPU%", "RSS", "USER", "NAME")
        for p in sorted.prefix(limit) {
            out += String(format: "%7d  %6.1f  %10@  %-10@  %@%@\n", p.pid, p.cpuPercent ?? 0,
                          MonitorObservations.bytes(p.residentBytes ?? 0), String((p.user ?? "?").prefix(10)), p.name,
                          p.source == .ps ? "  (ps)" : "")
        }
        out += "\n\(samples.count) processes sampled over 1 s. CPU% is percent of one core."
        let viaPS = samples.filter { $0.source == .ps }.count
        let unavailable = samples.filter { $0.source == .unavailable }.count
        if viaPS > 0 { out += " \(viaPS) processes owned by other users were measured with ps (lower precision)." }
        if unavailable > 0 { out += " \(unavailable) processes could not be measured." }
        return out
    }

    static func inspect(pid: pid_t, sampler: ProcessSampler) async throws -> String {
        _ = await sampler.sample()
        try await Task.sleep(nanoseconds: 500_000_000)
        guard let p = await sampler.sample().first(where: { $0.pid == pid }) else {
            return "No process with pid \(pid) is visible."
        }
        var lines = ["PID: \(p.pid)", "Name: \(p.name)", "Path: \(p.path ?? "unavailable")",
                     "Parent PID: \(p.ppid.map(String.init) ?? "unavailable")",
                     "Parent name: \(p.ppid.map { ProcessSampler.name(for: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "unavailable")",
                     "User: \(p.user ?? "unavailable")"]
        lines.append("CPU (last 0.5 s): \(p.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "unavailable")")
        lines.append("Total CPU time: \(p.cpuTimeSeconds.map { String(format: "%.1f s", $0) } ?? "unavailable")")
        lines.append("Resident memory: \(p.residentBytes.map(MonitorObservations.bytes) ?? "unavailable")")
        lines.append("Threads: \(p.threadCount.map(String.init) ?? "unavailable")")
        lines.append("Started: \(p.startTime?.formatted() ?? "unavailable")")
        lines.append("Data source: \(p.source.rawValue)")
        return lines.joined(separator: "\n")
    }

    static func memoryOverview() -> String {
        guard let m = SystemMetrics.memory() else { return "Memory statistics are unavailable." }
        let b = MonitorObservations.bytes
        return """
        Physical: \(b(m.physicalBytes))
        Used: \(b(m.usedBytes))  (app \(b(m.appBytes)), wired \(b(m.wiredBytes)), compressed \(b(m.compressedBytes)))
        Cached files: \(b(m.cachedBytes))
        Swap: \(m.swapUsedBytes.map(b) ?? "unknown") used of \(m.swapTotalBytes.map(b) ?? "unknown")
        Memory pressure: \(m.pressureLabel)
        """
    }

    static func volumes() -> String {
        let vols = SystemMetrics.volumes()
        guard !vols.isEmpty else { return "No volume information is available." }
        return vols.map { v in
            let used = v.totalBytes - v.availableBytes
            let pct = Double(used) / Double(max(v.totalBytes, 1)) * 100
            return String(format: "%@ (%@): %@ free of %@ (%.0f%% used)", v.name, v.mountPoint,
                          ByteFormat.string(v.availableBytes, .file),
                          ByteFormat.string(v.totalBytes, .file), pct)
        }.joined(separator: "\n")
    }

    static func interfaces() -> String {
        var addrs: [String: [String]] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let p = ptr {
                let name = String(cString: p.pointee.ifa_name)
                if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addrs[name, default: []].append(stringFromCBuffer(host))
                    }
                }
                ptr = p.pointee.ifa_next
            }
            freeifaddrs(first)
        }
        let counters = SystemMetrics.interfaceCounters().filter { $0.bytesIn + $0.bytesOut > 0 || addrs[$0.name] != nil }
        guard !counters.isEmpty else { return "No interface information is available." }
        var seen = Set<String>()
        return counters.filter { seen.insert($0.name).inserted }.map { c in
            "\(c.name) [\(c.isUp ? "up" : "down")] in \(MonitorObservations.bytes(c.bytesIn)) / out \(MonitorObservations.bytes(c.bytesOut))"
                + (addrs[c.name].map { "  addr " + $0.joined(separator: ", ") } ?? "")
        }.joined(separator: "\n")
    }

    static func largestFiles(root: String, limit: Int, depth: Int, excluded: [String] = [], sink: OutputSink) async throws -> String {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else {
            throw HackCodeError.permissionDenied("cannot enumerate \(root)")
        }
        let baseDepth = rootURL.pathComponents.count
        var top: [(Int64, String)] = []
        var scanned = 0
        var skippedProtected = 0
        let cap = 300_000
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if url.pathComponents.count - baseDepth >= depth { enumerator.skipDescendants() }
            // Never descend into protected locations (e.g. ~/.ssh, ~/Library/Mail) even when scanning a parent folder.
            // The enumerator starts from the resolved root and does not follow symlinks, so url.path is already real.
            // (URL.resolvingSymlinksInPath would strip /private and break the comparison.)
            if excluded.contains(where: { PathPolicy.isWithin(url.path, root: $0, allowRootItself: true) }) {
                enumerator.skipDescendants()
                skippedProtected += 1
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            scanned += 1
            let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            if top.count < limit { top.append((size, url.path)); top.sort { $0.0 > $1.0 } }
            else if let last = top.last, size > last.0 { top[top.count - 1] = (size, url.path); top.sort { $0.0 > $1.0 } }
            if scanned % 20_000 == 0 { sink.emit(.info, "scanned \(scanned) files…\n") }
            if scanned >= cap { break }
        }
        var out = top.map { String(format: "%10@  %@", ByteFormat.string($0.0, .file), $0.1) }.joined(separator: "\n")
        out += "\n\nScanned \(scanned) files (depth ≤ \(depth), symlinks not followed)" + (scanned >= cap ? "; stopped at the \(cap)-file limit." : ".")
            + (skippedProtected > 0 ? " Protected locations skipped: \(skippedProtected)." : "")
        return out
    }

    static func listFolder(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw HackCodeError.permissionDenied("cannot list \(path): \(error.localizedDescription)")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(500).map { u -> String in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let kind = v?.isSymbolicLink == true ? "link" : (v?.isDirectory == true ? "dir " : "file")
            let size = v?.isDirectory == true ? "-" : ByteFormat.string(Int64(v?.totalFileAllocatedSize ?? 0), .file)
            return String(format: "%@  %10@  %@  %@", kind, size, v?.contentModificationDate.map { f.string(from: $0) } ?? "?", u.lastPathComponent)
        }
        return rows.joined(separator: "\n") + "\n\n\(items.count) entries" + (items.count > 500 ? " (first 500 shown)" : "")
    }

    static func allocatedSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        var n = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: nil)
        while let u = e?.nextObject() as? URL, n < 50_000 {
            n += 1
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func formatFinding(_ f: Finding) -> String {
        var s = "[\(f.status.rawValue)] \(f.title) — severity \(f.severity.label), confidence \(f.confidence.rawValue)\n"
        if let note = f.statusNote { s += "  \(note)\n" }
        for e in f.evidence {
            s += "  evidence (\(e.source)):\n"
            s += e.output.split(separator: "\n", omittingEmptySubsequences: false).prefix(15).map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        if let r = f.remediation { s += "  remediation: \(r.summary)\n" }
        return s
    }

    static func formatAudit(_ run: AuditRun) -> String {
        var s = "Security audit: \(run.findings.count) checks, \(run.issues.count) issue(s), \(run.failedChecks.count) could not run"
        if let score = run.score { s += ", posture score \(score)/100" }
        s += run.cancelled ? " (cancelled)\n\n" : "\n\n"
        for f in run.findings.sorted(by: { ($0.isActionable ? 1 : 0, $0.severity) > ($1.isActionable ? 1 : 0, $1.severity) }) {
            s += "[\(f.status.rawValue)] \(f.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f.title): \(f.statusNote ?? "")\n"
        }
        s += "\nOpen SECURITY AUDIT (⌘3) for evidence and remediation."
        return s
    }
}
