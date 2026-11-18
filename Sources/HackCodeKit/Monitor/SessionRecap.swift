import Foundation

/// "Since your last session" summary for the SYS.ADMIN banner, from local data only (trend samples, crash-report
/// listing, audit history). Shown only after a real gap, so reopening HackCode mid-task stays quiet.
public struct SessionRecap: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let key: String
        public let text: String
        public let warn: Bool
    }

    public static let minimumGap: TimeInterval = 6 * 3600
    public static let staleAuditAge: TimeInterval = 7 * 86_400
    public let since: Date
    public let lines: [Line]

    /// - Parameters:
    ///   - previous: trend samples recorded before this launch (the newest marks the last session).
    ///   - current: a sample taken now.
    public static func make(previous: [TrendSample], current: TrendSample, crashes: [CrashReportWatcher.Report],
                            lastAudit: AuditSummary?, now: Date = Date()) -> SessionRecap? {
        guard let last = previous.max(by: { $0.time < $1.time }), now.timeIntervalSince(last.time) >= minimumGap else { return nil }
        var lines = [Line(key: "away", text: "last session \(duration(now.timeIntervalSince(last.time))) ago (\(stamp(last.time)))", warn: false)]

        if let was = last.diskFreeBytes, let free = current.diskFreeBytes {
            let delta = free - was
            let lowNow = current.diskTotalBytes.map { $0 > 0 && Double(free) / Double($0) < 0.10 } ?? false
            if abs(delta) >= 500_000_000 || lowNow {
                let sign = delta >= 0 ? "+" : "−"
                lines.append(Line(key: "disk", text: "\(sign)\(ByteFormat.string(abs(delta))) free since then · \(ByteFormat.string(free)) free now",
                                  warn: delta < -5_000_000_000 || lowNow))
            }
        }

        var battery: [String] = []
        if let a = last.batteryHealth, let b = current.batteryHealth, abs(b - a) >= 0.002 {
            battery.append(String(format: "health %.1f%% (%+.1f pts)", b * 100, (b - a) * 100))
        }
        if let a = last.batteryCycles, let b = current.batteryCycles, b != a {
            battery.append("\(b) cycles (\(b > a ? "+" : "")\(b - a))")
        }
        if !battery.isEmpty { lines.append(Line(key: "battery", text: battery.joined(separator: " · "), warn: false)) }

        let fresh = crashes.filter { $0.date > last.time }
        if fresh.isEmpty {
            lines.append(Line(key: "crashes", text: "no new crash, hang or panic reports", warn: false))
        } else {
            var counts: [String: Int] = [:]
            var kinds: [String: String] = [:]
            for r in fresh { counts[r.app, default: 0] += 1; kinds[r.app] = r.kind }
            let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
                .map { "\($0.key)\($0.value > 1 ? " ×\($0.value)" : "") (\(kinds[$0.key] ?? "crash"))" }
            let more = counts.count > 3 ? " +\(counts.count - 3) more" : ""
            let panic = fresh.contains { $0.kind == "kernel panic" }
            lines.append(Line(key: "crashes", text: "\(fresh.count) new report\(fresh.count == 1 ? "" : "s"): \(top.joined(separator: ", "))\(more) · /run diagnostics.crash_reports lists them",
                              warn: panic || fresh.count >= 3))
        }

        if let audit = lastAudit {
            let age = now.timeIntervalSince(audit.date)
            let score = audit.score.map { " · score \($0)" } ?? ""
            lines.append(Line(key: "audit", text: age > staleAuditAge
                                ? "last security audit \(duration(age)) ago\(score) — consider re-running (⌘3)"
                                : "last security audit \(duration(age)) ago\(score)",
                              warn: age > staleAuditAge))
        } else {
            lines.append(Line(key: "audit", text: "no security audit on record — run one in SECURITY AUDIT (⌘3)", warn: true))
        }
        return SessionRecap(since: last.time, lines: lines)
    }

    /// "2 d 4 h", "7 h", "45 min".
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        let days = hours / 24, rest = hours % 24
        return rest == 0 || days >= 7 ? "\(days) d" : "\(days) d \(rest) h"
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm dd-MMM"
        return f.string(from: d)
    }
}
