import Foundation
import Darwin
import CryptoKit
import AppKit

/// In-process implementations of operations (no shell, no external tools).
enum NativeTools {
    // MARK: Power

    static func batteryReport() -> String {
        var lines: [String] = []
        if let b = PowerMetrics.battery() {
            lines.append("Charge: \(b.percent)% — \(b.isCharging ? "charging" : (b.onAC ? "on AC, not charging" : "discharging"))")
            if let m = b.minutesRemaining { lines.append("Time \(b.isCharging ? "to full" : "remaining"): \(m / 60) h \(m % 60) min") }
            if let c = b.cycleCount { lines.append("Cycle count: \(c)") }
            if let h = b.health { lines.append(String(format: "Capacity vs design: %.0f%%", h * 100)) }
            if let cond = b.condition { lines.append("Condition: \(cond)") }
        } else {
            lines.append("No internal battery detected (desktop Mac or information unavailable).")
        }
        lines.append("Thermal state: \(PowerMetrics.thermalState)")
        lines.append("Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
        return lines.joined(separator: "\n")
    }

    // MARK: Crash reports

    static func crashDirectories(home: String) -> [String] {
        [(home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
    }

    static func crashReports(home: String, limit: Int) -> String {
        var items: [(Date, String, String, Int64)] = []
        for dir in crashDirectories(home: home) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where [".ips", ".crash", ".hang", ".panic", ".diag", ".spin"].contains(where: n.hasSuffix) {
                let p = (dir as NSString).appendingPathComponent(n)
                guard let a = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
                items.append((a[.modificationDate] as? Date ?? .distantPast, n, dir.hasPrefix("/Library") ? "system" : "user", (a[.size] as? Int64) ?? 0))
            }
        }
        guard !items.isEmpty else { return "No crash, hang or panic reports found." }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = items.sorted { $0.0 > $1.0 }.prefix(limit).map { "\(f.string(from: $0.0))  \($0.2.padding(toLength: 6, withPad: " ", startingAt: 0))  \($0.1)" }
        return rows.joined(separator: "\n") + "\n\n\(items.count) reports total. Read one with diagnostics.crash_report name=<file name>."
    }

    static func crashReport(name: String, home: String) throws -> String {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw HackCodeError.invalidArgument(operation: "diagnostics.crash_report", argument: "name", reason: "must be a plain file name") }
        for dir in crashDirectories(home: home) {
            let p = (dir as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: p) else { continue }
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { throw HackCodeError.permissionDenied("cannot read \(name)") }
            return summarizeCrash(text)
        }
        throw HackCodeError.invalidArgument(operation: "diagnostics.crash_report", argument: "name", reason: "no report with that name in DiagnosticReports")
    }

    /// Keeps the useful parts of a crash report: header, exception info and the crashed thread.
    static func summarizeCrash(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasPrefix("{"), let first = lines.first, let data = first.data(using: .utf8),
           let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // .ips: JSON header line + JSON body.
            var out = header.filter { ["app_name", "app_version", "bug_type", "timestamp", "os_version", "name", "incident_id"].contains($0.key) }
                .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            let body = lines.dropFirst().joined(separator: "\n")
            if let bd = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: bd) as? [String: Any] {
                if let exc = obj["exception"] { out.append("exception: \(exc)") }
                if let term = obj["termination"] { out.append("termination: \(term)") }
                if let asi = obj["asi"] { out.append("diagnostic messages: \(asi)") }
                if let threads = obj["threads"] as? [[String: Any]], let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }) {
                    out.append("crashed thread: \(crashed["name"] ?? crashed["queue"] ?? "unnamed")")
                    if let frames = crashed["frames"] as? [[String: Any]] {
                        let images = (obj["usedImages"] as? [[String: Any]]) ?? []
                        for (i, fr) in frames.prefix(20).enumerated() {
                            let img = (fr["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                            out.append("  \(i)  \(img)  \(fr["symbol"] as? String ?? "?")")
                        }
                    }
                }
            }
            return out.joined(separator: "\n")
        }
        return lines.prefix(150).joined(separator: "\n")
    }

    // MARK: Processes & apps

    static func processTree(_ pid: pid_t) -> String {
        var chain: [String] = []
        var cursor = pid
        var guardCount = 0
        while cursor > 0, guardCount < 30 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cursor]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            chain.append("\(cursor) \(ProcessSampler.name(for: cursor).isEmpty ? "?" : ProcessSampler.name(for: cursor))")
            let parent = info.kp_eproc.e_ppid
            if parent == cursor { break }
            cursor = parent
            guardCount += 1
        }
        var out = "Ancestry (process → launchd):\n" + chain.enumerated().map { String(repeating: "  ", count: $0.offset) + "└ " + $0.element }.joined(separator: "\n")
        let kids = ProcessSampler.children(of: pid)
        out += "\n\nChildren (\(kids.count)):\n" + (kids.isEmpty ? "  none" : kids.prefix(100).map { "  \($0) \(ProcessSampler.name(for: $0))" }.joined(separator: "\n"))
        return out
    }

    static func appsList(home: String) -> String {
        var rows: [String] = []
        for dir in ["/Applications", (home as NSString).appendingPathComponent("Applications")] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names.sorted() where n.hasSuffix(".app") {
                let info = NSDictionary(contentsOfFile: "\(dir)/\(n)/Contents/Info.plist") as? [String: Any]
                let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
                let bundle = (info?["CFBundleIdentifier"] as? String) ?? "?"
                rows.append("\(n.replacingOccurrences(of: ".app", with: "").padding(toLength: 34, withPad: " ", startingAt: 0)) \(version.padding(toLength: 14, withPad: " ", startingAt: 0)) \(bundle)")
            }
        }
        return rows.isEmpty ? "No applications found." : rows.joined(separator: "\n") + "\n\n\(rows.count) apps."
    }

    static func quitApp(pid: pid_t, pinnedStart: String?) async throws -> String {
        guard ProcessSampler.startTime(of: pid) == pinnedStart else {
            throw HackCodeError.operationDenied(operation: "app.quit", reason: "pid \(pid) is no longer the approved process")
        }
        let requested: Bool = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.terminate()
        }
        guard requested else {
            throw HackCodeError.operationDenied(operation: "app.quit", reason: "pid \(pid) is not an app with a user interface (use process.terminate instead)")
        }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !ProcessSampler.exists(pid) { return "The app quit." }
        }
        return "Quit requested; the app is still running (it may be asking you to save)."
    }

    // MARK: Files

    static func enumerate(_ root: String, excluded: [String], keys: [URLResourceKey], cap: Int = 300_000,
                          visit: (URL, URLResourceValues) throws -> Bool) throws -> (scanned: Int, skipped: Int) {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else {
            throw HackCodeError.permissionDenied("cannot enumerate \(root)")
        }
        var scanned = 0, skipped = 0
        while let url = e.nextObject() as? URL {
            if excluded.contains(where: { PathPolicy.isWithin(url.path, root: $0, allowRootItself: true) }) {
                e.skipDescendants(); skipped += 1; continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            scanned += 1
            if try !visit(url, v) || scanned >= cap { break }
        }
        return (scanned, skipped)
    }

    static func find(root: String, pattern: String, limit: Int, excluded: [String]) throws -> String {
        var hits: [String] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
        let r = try enumerate(root, excluded: excluded, keys: keys) { url, v in
            try Task.checkCancellation()
            if fnmatch(pattern, url.lastPathComponent, FNM_CASEFOLD) == 0 {
                let size = v.isRegularFile == true ? ByteFormat.string(Int64(v.totalFileAllocatedSize ?? 0), .file) : "dir"
                hits.append(String(format: "%10@  %@", size, url.path))
            }
            return hits.count < limit
        }
        return (hits.isEmpty ? "No matches for \(pattern)." : hits.joined(separator: "\n")) + "\n\nScanned \(r.scanned) items" + (r.skipped > 0 ? "; protected locations skipped: \(r.skipped)." : ".")
    }

    static func stale(root: String, days: Int, limit: Int, excluded: [String]) throws -> String {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var found: [(Int64, Date, String)] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        let r = try enumerate(root, excluded: excluded, keys: keys) { url, v in
            try Task.checkCancellation()
            guard v.isRegularFile == true, let mod = v.contentModificationDate, mod < cutoff else { return true }
            found.append((Int64(v.totalFileAllocatedSize ?? 0), mod, url.path))
            return true
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let top = found.sorted { $0.0 > $1.0 }.prefix(limit)
        let total = found.reduce(Int64(0)) { $0 + $1.0 }
        guard !top.isEmpty else { return "No files older than \(days) days." }
        return top.map { String(format: "%10@  %@  %@", ByteFormat.string($0.0, .file), f.string(from: $0.1), $0.2) }.joined(separator: "\n")
            + "\n\n\(found.count) files older than \(days) days use \(ByteFormat.string(total, .file)) (scanned \(r.scanned)). Move items you no longer need with files.move_to_trash."
    }

    static func duplicates(root: String, limit: Int, excluded: [String], sink: OutputSink) async throws -> String {
        var bySize: [Int64: [String]] = [:]
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let r = try enumerate(root, excluded: excluded, keys: keys, cap: 50_000) { url, v in
            try Task.checkCancellation()
            if v.isRegularFile == true, let s = v.fileSize, s >= 1_048_576 { bySize[Int64(s), default: []].append(url.path) }
            return true
        }
        var groups: [(Int64, [String])] = []
        var hashedBytes: Int64 = 0
        let budget: Int64 = 8 * 1024 * 1024 * 1024
        for (size, paths) in bySize where paths.count > 1 {
            try Task.checkCancellation()
            if hashedBytes > budget { break }
            var byHash: [String: [String]] = [:]
            for p in paths {
                guard let h = try? sha256(p) else { continue }
                hashedBytes += size
                byHash[h, default: []].append(p)
            }
            for (_, same) in byHash where same.count > 1 { groups.append((size, same.sorted())) }
            sink.emit(.info, "")
        }
        guard !groups.isEmpty else { return "No duplicate files ≥ 1 MB found (scanned \(r.scanned) files)." }
        let sorted = groups.sorted { $0.0 * Int64($0.1.count - 1) > $1.0 * Int64($1.1.count - 1) }
        let wasted = groups.reduce(Int64(0)) { $0 + $1.0 * Int64($1.1.count - 1) }
        var out = sorted.prefix(limit).map { g in
            "\(ByteFormat.string(g.0, .file)) × \(g.1.count)\n" + g.1.map { "    \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n")
        out += "\n\n\(groups.count) duplicate groups; \(ByteFormat.string(wasted, .file)) could be reclaimed by keeping one copy of each."
        if hashedBytes > budget { out += " Stopped hashing after 8 GB; results may be incomplete." }
        return out
    }

    static func sha256(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw HackCodeError.permissionDenied("cannot open \(path)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ path: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw HackCodeError.invalidArgument(operation: "files.hash", argument: "path", reason: "must be a file, not a folder")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return "SHA-256  \(try sha256(path))\nFile     \(path)\nSize     \(ByteFormat.string(size, .file))"
    }

    static func quarantine(_ path: String) -> String {
        let name = "com.apple.quarantine"
        let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return "No quarantine flag: \(path)\n(The file was not downloaded by a quarantine-aware app, or the flag was removed.)" }
        var buf = [UInt8](repeating: 0, count: len)
        _ = getxattr(path, name, &buf, len, 0, XATTR_NOFOLLOW)
        let raw = String(decoding: buf, as: UTF8.self)
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var out = ["Quarantined: yes", "File: \(path)"]
        if parts.count > 1, let ts = UInt64(parts[1], radix: 16) {
            out.append("Flagged: \(Date(timeIntervalSince1970: TimeInterval(ts)).formatted())")
        }
        if parts.count > 2, !parts[2].isEmpty { out.append("Downloaded by: \(parts[2])") }
        if let flags = parts.first, let f = UInt32(flags, radix: 16) {
            out.append("Gatekeeper has \((f & 0x40) != 0 ? "already approved" : "not yet approved") opening it")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Remediation

    static func fixSSHPermissions(home: String) throws -> String {
        let ssh = (home as NSString).appendingPathComponent(".ssh")
        var st = stat()
        guard lstat(ssh, &st) == 0 else { return "~/.ssh does not exist; nothing to change." }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw HackCodeError.operationDenied(operation: "security.fix_ssh_permissions", reason: "~/.ssh is not a directory you own")
        }
        var changes: [String] = []
        if st.st_mode & 0o077 != 0 {
            guard chmod(ssh, 0o700) == 0 else { throw HackCodeError.permissionDenied("chmod ~/.ssh: \(String(cString: strerror(errno)))") }
            changes.append(String(format: "~/.ssh %o → 700", st.st_mode & 0o777))
        }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: ssh)) ?? [] where f.hasPrefix("id_") && !f.hasSuffix(".pub") {
            let p = (ssh as NSString).appendingPathComponent(f)
            var fs = stat()
            // Regular files only (never follow symlinks), owned by you.
            guard lstat(p, &fs) == 0, (fs.st_mode & S_IFMT) == S_IFREG, fs.st_uid == getuid(), fs.st_mode & 0o077 != 0 else { continue }
            guard chmod(p, 0o600) == 0 else { throw HackCodeError.permissionDenied("chmod \(f): \(String(cString: strerror(errno)))") }
            changes.append(String(format: "~/.ssh/%@ %o → 600", f, fs.st_mode & 0o777))
        }
        return changes.isEmpty ? "Permissions were already restrictive; nothing changed." : "Changed:\n" + changes.joined(separator: "\n")
    }
}
