import Testing
import Foundation
@testable import HackCodeKit

@Suite("Monitor")
struct MonitorTests {
    @Test func cpuTimeParsing() {
        #expect(ProcessSampler.parseCPUTime("0:01.50") == 1.5)
        #expect(abs(ProcessSampler.parseCPUTime("12:34.56")! - 754.56) < 0.001)
        #expect(ProcessSampler.parseCPUTime("1:02:03") == 3723)
        #expect(abs(ProcessSampler.parseCPUTime("2-01:00:00")! - 176_400) < 0.001)
        #expect(ProcessSampler.parseCPUTime("abc") == nil)
    }

    @Test func psParsingKeepsCommandsWithSpaces() {
        let rows = ProcessSampler.parsePS("  1     0     0  16912   4:12.34 /sbin/launchd\n 900   1   501  2048   0:00.10 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\nbad line\n")
        #expect(rows.count == 2)
        #expect(rows[1].command == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        #expect(rows[1].rssKB == 2048)
    }

    @Test func byteFormatNeverSaysZero() {
        #expect(!ByteFormat.string(0).lowercased().contains("zero"))
        #expect(!ByteFormat.rate(0).lowercased().contains("zero"))
        #expect(ByteFormat.rate(-5) == ByteFormat.rate(0))
    }

    @Test func ringBufferBounded() {
        var r = RingBuffer<Int>(capacity: 3)
        (1...10).forEach { r.append($0) }
        #expect(r.elements == [8, 9, 10])
        r.resize(2)
        #expect(r.elements == [9, 10])
    }

    @Test func trendDetection() {
        let steady = MonitorObservations.trend(pid: 1, name: "a", history: [5, 6, 5, 4, 5, 6, 5, 5])
        #expect(steady?.sustainedAboveBaseline == false)
        let spike = MonitorObservations.trend(pid: 2, name: "b", history: [5, 6, 5, 4, 5, 90, 95, 99])
        #expect(spike?.sustainedAboveBaseline == true)
        #expect(MonitorObservations.trend(pid: 3, name: "c", history: [1, 2]) == nil)
    }

    /// Regression: /bin/ps is setuid and cannot run sandboxed; other users' processes must still be measured.
    @Test func otherUsersProcessesAreMeasuredWithPS() async {
        #expect(ProcessSampler.psRequest.sandbox.isSandboxed == false)
        #expect(ProcessSampler.psRequest.arguments == ["-axo", "pid=,ppid=,uid=,rss=,time=,comm="])
        let samples = await ProcessSampler().sample()
        let others = samples.filter { $0.source != .libproc }
        guard !others.isEmpty else { return }   // nothing restricted on this machine
        let measured = others.filter { $0.source == .ps }
        #expect(Double(measured.count) >= Double(others.count) * 0.9, "most restricted processes should come from ps")
        #expect(measured.contains { !$0.name.hasPrefix("pid ") && $0.residentBytes != nil })
        #expect(samples.contains { $0.name == "launchd" && $0.pid == 1 })
    }

    @Test func liveCollectionReturnsRealData() async {
        let monitor = SystemMonitor(historyLength: 5)
        _ = await monitor.collect()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let s = await monitor.collect()
        #expect(s.processes.count > 10)
        #expect(s.memory.value != nil)
        #expect(s.cpu.value != nil)
        #expect(s.processes.contains { $0.pid == getpid() && $0.source == .libproc })
        #expect(s.history.count == 2)
        // Per-interface rate history: present for every reported interface and bounded by the history length.
        #expect(Set(s.interfaceHistory.keys) == Set(s.interfaces.map(\.name)))
        #expect(s.interfaceHistory.values.allSatisfy { $0.count <= 5 })
        #expect(s.interfaceAddresses["lo0"]?.contains("127.0.0.1") == true)
        let summary = MonitorObservations.summary(s, trends: [])
        #expect(summary.contains("Top processes by CPU"))
        #expect(!summary.contains(NSHomeDirectory()))
    }
}

@Suite("Redaction & audit log")
struct RedactionTests {
    let r = Redactor(homeDirectory: "/Users/alice")

    @Test func secretsRemoved() {
        let text = """
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456
        NVIDIA_API_KEY=nvapi-AbCdEfGhIjKlMnOpQrStUv
        password: hunter2hunter2
        aws AKIAABCDEFGHIJKLMNOP
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        path /Users/alice/Documents/x
        """
        let out = r.redact(text)
        for leaked in ["abcdefghijklmnopqrstuvwxyz123456", "nvapi-AbCd", "hunter2", "AKIAABCDEFGHIJKLMNOP", "b3BlbnNzaC1rZXkt", "/Users/alice"] {
            #expect(!out.contains(leaked), "\(leaked) leaked")
        }
        #expect(out.contains("~/Documents/x"))
    }

    @Test func promptSanitizerStripsControlAndBounds() {
        let s = Redactor.sanitizeForPrompt("ok\u{1B}[31m\u{0007}" + String(repeating: "a", count: 100), maxCharacters: 20)
        #expect(!s.contains("\u{1B}"))
        #expect(s.contains("TRUNCATED"))
    }

    @Test func auditLogRedactsAndRestrictsFile() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hc-log-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("audit.jsonl")
        let log = AuditLogService(fileURL: url, maxFileBytes: 2_000)
        await log.record(AuditEvent(kind: .executionFinished, operation: "x", outcome: "ok",
                                    detail: "token=nvapi-SECRETSECRETSECRET1 " + String(repeating: "z", count: 2000)))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("SECRETSECRET"))
        #expect(contents.count < 1_500)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        for i in 0..<20 { await log.record(AuditEvent(kind: .historyCleared, outcome: "\(i)")) }
        #expect(FileManager.default.fileExists(atPath: url.path + ".1"))   // rotated
        await log.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(atPath: dir)
    }
}
