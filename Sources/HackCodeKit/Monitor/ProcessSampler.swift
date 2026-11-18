import Foundation
import Darwin

/// Where a process measurement came from, shown in the UI so restricted data is never presented as precise.
public enum ProcessDataSource: String, Sendable, Equatable {
    case libproc = "libproc"
    case ps = "ps (restricted process)"
    case unavailable = "unavailable"
}

public struct ProcessSample: Sendable, Equatable, Identifiable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public var ppid: pid_t?
    public var uid: uid_t?
    public var user: String?
    public var name: String
    public var path: String?
    /// Percent of one core (Activity Monitor convention: may exceed 100 on multi-core).
    public var cpuPercent: Double?
    public var residentBytes: UInt64?
    public var threadCount: Int?
    public var cpuTimeSeconds: Double?
    public var startTime: Date?
    public var source: ProcessDataSource
}

/// Collects per-process data. Never runs on the main actor.
public actor ProcessSampler {
    private struct Previous { let cpuTime: Double; let at: TimeInterval }
    private var previous: [pid_t: Previous] = [:]
    private let runner: ProcessRunning
    private var timebase: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private var userNames: [uid_t: String] = [:]
    /// Other users' processes are re-read with `ps` only every `psEvery` samples to save energy; in between the
    /// previous figures are reused (rows are marked as ps-sourced either way).
    private let psEvery: Int
    private var sampleCount = 0
    private var cachedRestricted: [pid_t: ProcessSample] = [:]

    public init(runner: ProcessRunning = SystemProcessRunner(), psEvery: Int = 3) {
        self.runner = runner
        self.psEvery = max(1, psEvery)
    }

    /// Takes one snapshot. CPU% is computed from the delta since the previous snapshot; the first call has no CPU%.
    public func sample(includeRestricted: Bool = true) async -> [ProcessSample] {
        let now = ProcessInfo.processInfo.systemUptime
        var samples: [ProcessSample] = []
        var restricted: [pid_t] = []
        for pid in Self.allPIDs() where pid > 0 {
            if let s = sampleLibproc(pid: pid, now: now) {
                samples.append(s)
            } else {
                restricted.append(pid)
            }
        }
        if includeRestricted, !restricted.isEmpty {
            let wanted = Set(restricted)
            let cachedHit = wanted.filter { cachedRestricted[$0] != nil }.count
            if sampleCount % psEvery == 0 || cachedRestricted.isEmpty || Double(cachedHit) < Double(wanted.count) * 0.9 {
                let fresh = await sampleWithPS(restricted: wanted, now: now)
                cachedRestricted = Dictionary(fresh.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            }
            samples.append(contentsOf: wanted.compactMap { cachedRestricted[$0] })
        }
        sampleCount += 1
        let alive = Set(samples.map(\.pid))
        previous = previous.filter { alive.contains($0.key) }
        return samples
    }

    private func sampleLibproc(pid: pid_t, now: TimeInterval) -> ProcessSample? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }
        var bsd = proc_bsdinfo()
        let bsdOK = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        let cpuTime = Double(task.pti_total_user + task.pti_total_system) * timebase / 1e9
        let cpu = cpuPercent(pid: pid, cpuTime: cpuTime, now: now)
        let path = Self.path(for: pid)
        var name = Self.name(for: pid)
        if name.isEmpty, let path { name = (path as NSString).lastPathComponent }
        let uid: uid_t? = bsdOK ? bsd.pbi_uid : nil
        return ProcessSample(pid: pid, ppid: bsdOK ? pid_t(bsd.pbi_ppid) : nil, uid: uid, user: uid.map(userName),
                             name: name.isEmpty ? "pid \(pid)" : name, path: path, cpuPercent: cpu,
                             residentBytes: task.pti_resident_size, threadCount: Int(task.pti_threadnum),
                             cpuTimeSeconds: cpuTime,
                             startTime: bsdOK ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6) : nil,
                             source: .libproc)
    }

    /// Restricted (other users') processes: a single `ps` call with a constant argument list.
    /// `/bin/ps` is setuid root, and the macOS sandbox refuses to launch setuid binaries ("Operation not permitted"),
    /// so it cannot run under the Seatbelt profile; nothing user- or model-supplied reaches its arguments.
    static let psRequest = ProcessRunRequest(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,uid=,rss=,time=,comm="],
                                             timeout: 10, maxOutputBytes: 2 * 1024 * 1024,
                                             sandbox: .none(reason: "ps is setuid root; the sandbox cannot launch setuid tools; arguments are constant"))

    private func sampleWithPS(restricted: Set<pid_t>, now: TimeInterval) async -> [ProcessSample] {
        let request = Self.psRequest
        guard let result = try? await runner.run(request, sink: .discard), result.exitCode == 0 else {
            return restricted.map { pid in
                ProcessSample(pid: pid, name: Self.name(for: pid).isEmpty ? "pid \(pid)" : Self.name(for: pid), source: .unavailable)
            }
        }
        return Self.parsePS(result.stdout).compactMap { row in
            guard restricted.contains(row.pid) else { return nil }
            let cpu = cpuPercent(pid: row.pid, cpuTime: row.cpuTime, now: now)
            let name = (row.command as NSString).lastPathComponent
            return ProcessSample(pid: row.pid, ppid: row.ppid, uid: row.uid, user: userName(row.uid), name: name,
                                 path: row.command.hasPrefix("/") ? row.command : nil, cpuPercent: cpu,
                                 residentBytes: row.rssKB * 1024, threadCount: nil, cpuTimeSeconds: row.cpuTime,
                                 startTime: nil, source: .ps)
        }
    }

    private func cpuPercent(pid: pid_t, cpuTime: Double, now: TimeInterval) -> Double? {
        defer { previous[pid] = Previous(cpuTime: cpuTime, at: now) }
        guard let prev = previous[pid], now > prev.at, cpuTime >= prev.cpuTime else { return nil }
        return (cpuTime - prev.cpuTime) / (now - prev.at) * 100
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name, encoding: .utf8) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    // MARK: - Static helpers

    public static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    public static func path(for pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? stringFromCBuffer(buf) : nil
    }

    public static func name(for pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? stringFromCBuffer(buf) : ""
    }

    public static func owner(of pid: pid_t) -> uid_t? {
        var bsd = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { return bsd.pbi_uid }
        // Fallback that works for other users' processes.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// Process start time ("seconds.microseconds") — works for any user's process. Used to detect pid reuse.
    public static func startTime(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return "\(tv.tv_sec).\(tv.tv_usec)"
    }

    /// Direct children of a process.
    public static func children(of parent: pid_t) -> [pid_t] {
        allPIDs().filter { pid in
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && info.kp_eproc.e_ppid == parent
        }
    }

    public static func exists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    struct PSRow: Equatable {
        let pid: pid_t, ppid: pid_t, uid: uid_t, rssKB: UInt64, cpuTime: Double, command: String
    }

    static func parsePS(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]), let uid = uid_t(parts[2]),
                  let rss = UInt64(parts[3]), let time = parseCPUTime(String(parts[4])) else { return nil }
            return PSRow(pid: pid, ppid: ppid, uid: uid, rssKB: rss, cpuTime: time, command: String(parts[5]))
        }
    }

    /// Parses ps TIME values such as "0:01.23", "12:34.56", "1:02:03" or "2-01:02:03".
    static func parseCPUTime(_ s: String) -> Double? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        var seconds = 0.0
        for v in values { seconds = seconds * 60 + v }
        return days * 86_400 + seconds
    }
}
