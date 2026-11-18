import Testing
import Foundation
@testable import HackCodeKit

@Suite("Registry invariants")
struct RegistryInvariantTests {
    let registry = makeRegistry()

    @Test func everyModifyingOperationNeedsApproval() throws {
        let policy = makePolicy()
        for spec in registry.ordered where !spec.isReadOnly && spec.parameters.allSatisfy({ !$0.isRequired }) {
            if spec.baseRisk == .low { continue }   // e.g. finder.reveal (opens a window)
            let op = try policy.validate(OperationRequest(operationID: spec.id, provenance: .model))
            #expect(op.requiresConfirmation, "\(spec.id) must require confirmation")
        }
        for spec in registry.ordered where !spec.isReadOnly {
            #expect(spec.baseRisk >= .low, "\(spec.id)")
            if spec.baseRisk != .low { #expect(spec.baseRisk >= .elevated, "\(spec.id) modifies state but is not elevated") }
        }
    }

    @Test func privilegedCommandsAreCriticalConstantsWithoutParameters() {
        for spec in registry.ordered where spec.isPrivileged {
            #expect(spec.baseRisk == .critical, "\(spec.id)")
            #expect(spec.parameters.isEmpty, "\(spec.id) must not take parameters")
            if case .privilegedFixedCommand(let cmd) = spec.action {
                #expect(!cmd.contains("\""), "\(spec.id) command must not contain quotes (embedded in AppleScript)")
                #expect(cmd.hasPrefix("/"), "\(spec.id) must use absolute paths")
            }
        }
    }

    @Test func processOperationsUseAbsoluteSystemExecutables() {
        let allowedPrefixes = ["/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/", "/usr/libexec/"]
        for spec in registry.ordered {
            if case .process(let exe, let sandbox, _) = spec.action {
                #expect(allowedPrefixes.contains { exe.hasPrefix($0) }, "\(spec.id) uses \(exe)")
                if case .none(let reason) = sandbox { #expect(!reason.isEmpty, "\(spec.id) unsandboxed without reason") }
            }
        }
    }

    @Test func noOperationAcceptsFreeFormText() {
        for spec in registry.ordered {
            for p in spec.parameters {
                if case .token(let pattern, _) = p.kind {
                    #expect(pattern.hasPrefix("^") && pattern.hasSuffix("$"), "\(spec.id).\(p.name) pattern must be anchored")
                    for bad in [";", "|", "`", "$(", "\"", "'", "\n", "/"] {
                        #expect(("x" + bad + "y").range(of: pattern, options: .regularExpression) == nil, "\(spec.id).\(p.name) accepts \(bad)")
                    }
                }
            }
        }
    }

    @Test func runbooksValidateAndAreReadOnly() throws {
        let policy = makePolicy()
        for book in Runbook.all {
            for request in book.requests() {
                guard let spec = registry.spec(for: request.operationID) else { Issue.record("\(book.id): unknown \(request.operationID)"); continue }
                #expect(spec.isReadOnly, "\(book.id) contains modifying \(spec.id)")
                if spec.parameters.contains(where: { if case .readablePath = $0.kind { return true }; return false }),
                   !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Downloads") { continue }
                #expect(throws: Never.self, "\(book.id) → \(request.operationID)") { try policy.validate(request) }
            }
        }
    }
}

@Suite("Process identity & hosts")
struct IdentityTests {
    @Test func reusedPidIsRejectedAtExecution() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let policy = makePolicy()
        let op = try policy.validate(OperationRequest(operationID: "process.terminate", arguments: ["pid": .integer(Int(child.processIdentifier))], provenance: .user))
        #expect(op.arguments.pinnedStart("pid") != nil)
        // Simulate pid reuse: same pid, different start time.
        var tampered = op.arguments.values
        tampered["pid.start"] = .string("1.0")
        let forged = ValidatedOperation(spec: op.spec, arguments: ValidatedArguments(tampered), risk: op.risk, requiresConfirmation: true,
                                        displayCommand: op.displayCommand, provenance: .user, claimedRisk: nil, rationale: nil)
        let executor = CommandExecutor(policy: policy, runner: MockRunner(), auditLog: AuditLogService(fileURL: nil))
        let record = await executor.execute(forged, approval: ApprovalGate.approve(forged))
        #expect(record.status == .rejected)
        #expect(record.errorOutput.contains("process changed"))
        #expect(child.isRunning)
        // The genuine operation still works.
        let ok = await executor.execute(op, approval: ApprovalGate.approve(op))
        #expect(ok.status == .succeeded)
    }

    @Test func modelCannotSupplyPinnedStart() {
        #expect(throws: HackCodeError.self) {
            try makePolicy().validate(OperationRequest(operationID: "process.inspect", arguments: ["pid": .integer(1), "pid.start": .string("0.0")], provenance: .model))
        }
    }

    @Test func hostValidation() {
        for good in ["apple.com", "a.b-c.example.org", "192.168.1.1", "localhost"] { #expect(ExecutionPolicy.isValidHost(good), "\(good)") }
        for bad in ["-c100", "apple.com;ls", "a b", "", "a..b", "http://x", "x/../y", "apple.com.", "$(id)", "--help"] {
            #expect(!ExecutionPolicy.isValidHost(bad), "\(bad)")
        }
        let op = try? makePolicy().validate(OperationRequest(operationID: "network.reachability", arguments: ["host": .string("Apple.COM")], provenance: .model))
        #expect(op?.displayCommand == "/sbin/ping -c 3 -t 10 -- apple.com")
        #expect(op?.risk.tier == .low)
    }

    @Test func identifiersHiddenFromHardwareOutput() {
        let out = OperationRegistry.hideIdentifiers("Model Name: MacBook Pro\nSerial Number (system): C02XYZ\nHardware UUID: 1234-ABCD\nMemory: 16 GB")
        #expect(!out.contains("C02XYZ"))
        #expect(!out.contains("1234-ABCD"))
        #expect(out.contains("MacBook Pro") && out.contains("16 GB"))
    }

    @Test func privilegedRemediationRunsFixedAppleScriptOnly() async throws {
        let runner = MockRunner { _ in MockRunner.ok("") }
        let policy = makePolicy()
        let executor = CommandExecutor(policy: policy, runner: runner, auditLog: AuditLogService(fileURL: nil))
        let op = try policy.validate(OperationRequest(operationID: "security.enable_firewall", provenance: .securityAudit))
        #expect(await executor.execute(op, approval: nil).status == .rejected)
        let record = await executor.execute(op, approval: ApprovalGate.approve(op))
        #expect(record.status == .succeeded)
        let req = try #require(runner.requests.first)
        #expect(req.executable == "/usr/bin/osascript")
        #expect(req.arguments == ["-e", "do shell script \"/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on\" with administrator privileges"])
    }

    @Test func cancelledAdminPromptIsReported() async throws {
        let runner = MockRunner { _ in MockRunner.ok("", stderr: "execution error: User canceled. (-128)", exit: 1) }
        let policy = makePolicy()
        let executor = CommandExecutor(policy: policy, runner: runner, auditLog: AuditLogService(fileURL: nil))
        let op = try policy.validate(OperationRequest(operationID: "network.flush_dns_cache", provenance: .user))
        let record = await executor.execute(op, approval: ApprovalGate.approve(op))
        #expect(record.status == .failed)
        #expect(record.note?.contains("cancelled the macOS administrator prompt") == true)
    }
}

@Suite("Native file tools")
struct NativeToolTests {
    @Test func findStaleHashDuplicates() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/a/b")
        let blob = String(repeating: "z", count: 1_100_000)
        try t.write("read/a/one.dmg", blob)
        try t.write("read/a/b/copy.dmg", blob)
        try t.write("read/a/notes.txt", "hello")
        try t.mkdir("read/secret")
        try t.write("read/secret/key.dmg", blob)
        let old = Date().addingTimeInterval(-200 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: t.path("read/a/one.dmg"))

        let found = try NativeTools.find(root: t.path("read"), pattern: "*.DMG", limit: 10, excluded: [t.path("read/secret")])
        #expect(found.contains("one.dmg") && found.contains("copy.dmg") && !found.contains("key.dmg"))
        #expect(found.contains("protected locations skipped: 1"))

        let stale = try NativeTools.stale(root: t.path("read"), days: 90, limit: 10, excluded: [])
        #expect(stale.contains("one.dmg") && !stale.contains("copy.dmg"))

        let dupes = try await NativeTools.duplicates(root: t.path("read"), limit: 5, excluded: [t.path("read/secret")], sink: .discard)
        #expect(dupes.contains("× 2"))
        #expect(!dupes.contains("key.dmg"))

        let hash = try NativeTools.hash(t.path("read/a/notes.txt"))
        #expect(hash.contains("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        #expect(throws: HackCodeError.self) { try NativeTools.hash(t.path("read/a")) }
    }

    @Test func quarantineParsing() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.write("f.zip")
        #expect(NativeTools.quarantine(t.path("f.zip")).contains("No quarantine flag"))
        let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
        setxattr(t.path("f.zip"), "com.apple.quarantine", value, value.utf8.count, 0, 0)
        let info = NativeTools.quarantine(t.path("f.zip"))
        #expect(info.contains("Quarantined: yes") && info.contains("Safari"))
    }

    @Test func sshPermissionFixOnlyTouchesPrivateKeys() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir(".ssh")
        try t.write(".ssh/id_ed25519")
        try t.write(".ssh/id_ed25519.pub")
        try t.write(".ssh/config")
        chmod(t.path(".ssh"), 0o755)
        chmod(t.path(".ssh/id_ed25519"), 0o644)
        chmod(t.path(".ssh/id_ed25519.pub"), 0o644)
        chmod(t.path(".ssh/config"), 0o644)
        let out = try NativeTools.fixSSHPermissions(home: t.root)
        func mode(_ p: String) -> mode_t { var s = stat(); lstat(t.path(p), &s); return s.st_mode & 0o777 }
        #expect(mode(".ssh") == 0o700)
        #expect(mode(".ssh/id_ed25519") == 0o600)
        #expect(mode(".ssh/id_ed25519.pub") == 0o644)
        #expect(mode(".ssh/config") == 0o644)
        #expect(out.contains("→ 600"))
        #expect(try NativeTools.fixSSHPermissions(home: t.root).contains("nothing changed"))
    }

    @Test func crashReportNameCannotTraverse() {
        #expect(throws: HackCodeError.self) { try NativeTools.crashReport(name: "../../etc/passwd", home: NSHomeDirectory()) }
        #expect(throws: HackCodeError.self) {
            try makePolicy().validate(OperationRequest(operationID: "diagnostics.crash_report", arguments: ["name": .string("../x.ips")], provenance: .model))
        }
    }

    @Test func ipsSummary() {
        let ips = #"{"app_name":"Demo","app_version":"1.0","bug_type":"309","timestamp":"2026-10-21"}"# + "\n" +
            #"{"exception":{"type":"EXC_BAD_ACCESS"},"threads":[{"triggered":true,"queue":"main","frames":[{"imageIndex":0,"symbol":"crashHere"}]}],"usedImages":[{"name":"Demo"}]}"#
        let s = NativeTools.summarizeCrash(ips)
        #expect(s.contains("app_name: Demo") && s.contains("EXC_BAD_ACCESS") && s.contains("crashHere"))
    }
}

@Suite("Alerts & posture history")
struct AlertTests {
    func snapshot(cpu: Double, rss: UInt64 = 100_000_000, pressure: Int = 1, battery: BatteryStatus? = nil, at t: TimeInterval) -> MonitorSnapshot {
        let p = ProcessSample(pid: 4242, ppid: 1, uid: 501, user: "me", name: "busyd", path: nil, cpuPercent: cpu, residentBytes: rss,
                              threadCount: 4, cpuTimeSeconds: nil, startTime: nil, source: .libproc)
        let mem = MemoryStats(physicalBytes: 16 << 30, usedBytes: 8 << 30, wiredBytes: 0, compressedBytes: 0, appBytes: 0, cachedBytes: 0,
                              swapUsedBytes: 0, swapTotalBytes: 0, pressureLevel: pressure)
        return MonitorSnapshot(time: Date(timeIntervalSince1970: t), cpu: .unavailable("x"), memory: .value(mem), loadAverages: nil,
                               volumes: [VolumeStats(name: "HD", mountPoint: "/", totalBytes: 100, availableBytes: 50, isInternal: true)],
                               interfaces: [], processes: [p], restrictedProcessCount: 0, unavailableProcessCount: 0,
                               collectionDuration: 0, history: [], bootTime: nil, battery: battery, thermalState: "NOMINAL")
    }

    @Test func sustainedCPUAlertsOnceAndRearms() {
        var d = AnomalyDetector()
        var fired: [MonitorAlert] = []
        for i in 0..<8 { fired += d.evaluate(snapshot(cpu: 150, at: Double(i))) }
        #expect(fired.filter { $0.key == "cpu.4242" }.count == 1)
        #expect(fired.first?.detail.contains("before drawing conclusions") == true)
        _ = d.evaluate(snapshot(cpu: 1, at: 9))
        var again: [MonitorAlert] = []
        for i in 10..<16 { again += d.evaluate(snapshot(cpu: 150, at: Double(i))) }
        #expect(again.filter { $0.key == "cpu.4242" }.count == 1)
    }

    @Test func memoryPressureGrowthAndBattery() {
        var d = AnomalyDetector()
        _ = d.evaluate(snapshot(cpu: 1, rss: 200_000_000, at: 0))
        let a = d.evaluate(snapshot(cpu: 1, rss: 1_200_000_000, pressure: 4,
                                    battery: BatteryStatus(percent: 5, isCharging: false, onAC: false, minutesRemaining: 10), at: 1))
        #expect(a.contains { $0.key == "mem.4242" })
        #expect(a.contains { $0.key == "pressure" && $0.level == .critical })
        #expect(a.contains { $0.key == "battery" })
        #expect(!a.contains { $0.title.lowercased().contains("malware") || $0.detail.lowercased().contains("malicious") })
    }

    @Test func postureDrift() async {
        func f(_ id: String, _ s: FindingStatus) -> Finding {
            Finding(id: id, checkID: id, title: id, severity: .medium, confidence: .high, component: "", evidence: [], collectedAt: Date(),
                    whyItMatters: "", limitations: [], remediation: nil, verificationSteps: [], status: s, statusNote: nil)
        }
        let store = AuditHistoryStore(url: nil)
        let first = await store.record(AuditSummary(run: AuditRun(startedAt: Date(), findings: [f("firewall", .pass), f("sip", .pass)], cancelled: false)))
        #expect(first.isEmpty)
        let changes = await store.record(AuditSummary(run: AuditRun(startedAt: Date(), findings: [f("firewall", .issue), f("sip", .remediated)], cancelled: false)))
        #expect(changes.count == 1)
        #expect(changes[0].checkID == "firewall" && changes[0].isRegression)
    }
}

@Suite("New security checks")
struct NewCheckTests {
    let registry = SecurityToolRegistry.standard()
    func eval(_ id: String, _ raw: String) -> Evaluation { registry.check(id: id)!.evaluate(CollectedEvidence(items: [], raw: raw)) }

    @Test func evaluators() {
        #expect(eval("backups", "tmutil: No destinations configured.").status == .issue)
        #expect(eval("backups", "====\nName : Backup\nKind : Local").status == .pass)
        #expect(eval("xprotect", "version = 5300\nageDays = 12").status == .pass)
        #expect(eval("xprotect", "version = 5300\nageDays = 200").severity == .medium)
        #expect(eval("admin-accounts", "GroupMembership: root alice _mbsetupuser").status == .observed)
        #expect(eval("device-management", "Enrolled via DEP: No\nMDM enrollment: No").note == "Not enrolled in MDM.")
        #expect(eval("system-extensions", "0 extension(s)").status == .observed)
        #expect(eval("app-signatures", "verified 40 apps\nall signatures valid").status == .pass)
        #expect(eval("app-signatures", "verified 40 apps\nINVALID  /Applications/X.app").status == .issue)
        #expect(eval("firewall-apps", "Total number of apps = 2\n1 : /A.app\n (Allow incoming connections)\n2 : /B.app\n (Block incoming connections)").note == "1 app(s) allowed and 1 blocked for incoming connections.")
        #expect(eval("auto-login", "autoLoginUser = (set)").severity == .high)
        #expect(eval("auto-login", "autoLoginUser = (not set)").status == .pass)
        #expect(eval("guest-account", "GuestEnabled = 1").status == .issue)
        #expect(eval("guest-account", "GuestEnabled = 0").status == .pass)
    }

    @Test func remediationOperationsExistInRegistry() {
        let ops = makeRegistry()
        for check in registry.checks {
            if let id = check.remediation?.operationID { #expect(ops.spec(for: id) != nil, "\(check.id) → \(id)") }
        }
        #expect(registry.checks.count == 24)
        #expect(Set(registry.checks.map(\.id)).count == registry.checks.count)
    }
}

@Suite("Review fixes")
struct ReviewFixTests {
    @Test func staleProcessReadingsDoNotTriggerSustainedCPU() {
        var d = AnomalyDetector()
        var fired: [MonitorAlert] = []
        for i in 0..<10 {
            let p = ProcessSample(pid: 99, ppid: 1, uid: 0, user: "root", name: "rootd", path: nil, cpuPercent: 300, residentBytes: 1,
                                  threadCount: nil, cpuTimeSeconds: nil, startTime: nil, source: .ps)
            let s = MonitorSnapshot(time: Date(timeIntervalSince1970: Double(i)), cpu: .unavailable("x"), memory: .unavailable("x"), loadAverages: nil,
                                    volumes: [], interfaces: [], processes: [p], restrictedProcessCount: 1, unavailableProcessCount: 0,
                                    collectionDuration: 0, history: [], bootTime: nil)
            fired += d.evaluate(s)
        }
        #expect(!fired.contains { $0.key.hasPrefix("cpu.") })
    }

    @Test func urlTimeoutReportsConfiguredSeconds() {
        let e = LLMService.map(URLError(.timedOut), timeout: 60) as? HackCodeError
        #expect(e == .timeout(seconds: 60))
        #expect(HackCodeError.timeout(seconds: 0).localizedDescription == "The operation timed out.")
    }
}

@Suite("Appearance settings")
struct AppearanceSettingsTests {
    @Test func oldDimRainDefaultIsUpgraded() throws {
        let old = try JSONDecoder().decode(HackCodeSettings.self, from: Data(#"{"matrixRain":true,"matrixRainIntensity":0.45}"#.utf8))
        #expect(old.matrixRainIntensity == 0.85)
        let chosen = try JSONDecoder().decode(HackCodeSettings.self, from: Data(#"{"matrixRainIntensity":0.3,"appearanceRevision":2}"#.utf8))
        #expect(chosen.matrixRainIntensity == 0.3)
    }
}

@Suite("Command history")
struct CommandHistoryTests {
    @Test func recordsRedactsAndBounds() {
        var h = CommandHistory()
        h.record("export TOKEN=nvapi-ABCDEFGHIJKLMNOPQRST")
        h.record("why is my mac slow")
        h.record("why is my mac slow")
        #expect(h.entries.count == 2)
        #expect(!h.entries[0].contains("ABCDEFGHIJ"))
        for i in 0..<600 { h.record("cmd \(i)") }
        #expect(h.entries.count == CommandHistory.maxEntries)
        #expect(h.entries.last == "cmd 599")
    }

    @Test func reverseSearchWalksOlderMatches() {
        var h = CommandHistory()
        ["/files.largest path=~/Downloads", "top cpu please", "/files.stale path=~/Downloads", "hello"].forEach { h.record($0) }
        let first = h.search("files")
        #expect(first?.line == "/files.stale path=~/Downloads")
        let older = h.search("FILES", before: first?.index)
        #expect(older?.line == "/files.largest path=~/Downloads")
        #expect(h.search("files", before: older?.index) == nil)
        #expect(h.search("") == nil)
    }

    @Test func slashUsageRanking() {
        var h = CommandHistory()
        h.record("/run files.largest path=~/x")
        h.record("/runbook health")
        h.record("/files.largest path=~/y")
        h.record("plain question")
        #expect(h.recentSlash == ["/files.largest", "/runbook health"])
    }

    @Test func storePersistsWithOwnerOnlyPermissions() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hc-hist-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("h.json")
        let store = CommandHistoryStore(url: url)
        var h = CommandHistory()
        h.record("/ops")
        await store.save(h)
        #expect(await store.load() == h)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        await store.clear()
        #expect(await store.load().entries.isEmpty)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

@Suite("Output diff")
struct OutputDiffTests {
    @Test func detectsChangedAddedAndRemovedLines() {
        let old = "a\nb\nc\n"
        let new = "a\nB\nc\nd  \n"
        #expect(OutputDiff.changedLines(old: old, new: new) == [1, 3])
        #expect(OutputDiff.removedLineCount(old: old, new: new) == 1)
        #expect(OutputDiff.changedLines(old: new, new: new).isEmpty)
    }

    @Test func duplicatesCountedAsMultiset() {
        #expect(OutputDiff.changedLines(old: "x\ny", new: "x\nx\ny") == [1])
        #expect(OutputDiff.changedLines(old: "", new: "first") == [0])
    }
}


@Suite("Port owner")
struct PortOwnerTests {
    @Test func portIsValidatedAndPassedAsSingleArgument() throws {
        let policy = makePolicy()
        let op = try policy.validate(OperationRequest(operationID: "network.port_owner", arguments: ["port": .integer(3000)], provenance: .model))
        #expect(op.displayCommand == "/usr/sbin/lsof -nP -iTCP:3000 -sTCP:LISTEN")
        #expect(op.risk.tier == .informational && !op.requiresConfirmation)
        for bad: ArgumentValue in [.integer(0), .integer(70000), .string("3000;id"), .string("3000")] {
            #expect(throws: HackCodeError.self) {
                try policy.validate(OperationRequest(operationID: "network.port_owner", arguments: ["port": bad], provenance: .model))
            }
        }
    }

    @Test func findsARealListenerOnThisMac() async throws {
        // Open a real listening socket in this test process on an ephemeral port, then look it up.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(listen(fd, 1) == 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let policy = makePolicy(runner: SystemProcessRunner())
        let executor = CommandExecutor(policy: policy, runner: SystemProcessRunner(), auditLog: AuditLogService(fileURL: nil))
        let op = try policy.validate(OperationRequest(operationID: "network.port_owner", arguments: ["port": .integer(port)], provenance: .user))
        let record = await executor.execute(op, approval: nil)
        #expect(record.output.contains("\(getpid())"))
        #expect(record.output.contains(":\(port) (LISTEN)"))
    }
}

@Suite("Folder sizer")
struct FolderSizerTests {
    @Test func sizesChildrenSkipsLinksAndProtected() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("root/big/deeper")
        try t.mkdir("root/small")
        try t.mkdir("root/secret")
        try t.write("root/big/deeper/a.bin", String(repeating: "a", count: 300_000))
        try t.write("root/big/b.bin", String(repeating: "b", count: 100_000))
        try t.write("root/small/c.txt", "c")
        try t.write("root/secret/key", String(repeating: "k", count: 500_000))
        try t.write("root/file.dat", String(repeating: "f", count: 50_000))
        try t.mkdir("outside")
        try t.write("outside/huge.bin", String(repeating: "h", count: 900_000))
        try t.symlink("root/link-to-outside", to: t.path("outside"))

        let sizer = FolderSizer()
        let seen = LockedBox(0)
        let scan = try await sizer.scan(t.path("root"), excluded: [t.path("root/secret")]) { _ in seen.mutate { $0 += 1 } }
        let byName = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.name, $0) })
        #expect(scan.entries.first?.name == "big")                       // sorted largest first
        #expect((byName["big"]?.bytes ?? 0) >= 400_000)
        #expect(byName["big"]?.itemCount == 3)                           // deeper/, a.bin, b.bin
        #expect(byName["secret"]?.isProtected == true && byName["secret"]?.bytes == 0)
        #expect(byName["link-to-outside"]?.bytes == 0)                   // symlink not followed
        #expect(scan.totalBytes < 900_000)                               // outside/huge.bin never counted
        #expect(seen.value == 5)
        #expect(await sizer.cached(t.path("root")) == scan)
    }

    @Test func unreadableFolderReported() async {
        let sizer = FolderSizer()
        await #expect(throws: HackCodeError.self) { try await sizer.scan("/nonexistent-\(UUID().uuidString)", excluded: []) }
    }
}

@Suite("Fuzzy match")
struct FuzzyMatchTests {
    @Test func subsequenceAndSpread() {
        #expect(FuzzyMatch.isSubsequence("flg", of: "files.largest"))
        #expect(!FuzzyMatch.isSubsequence("ftl", of: "files.largest"))   // order matters
        #expect(FuzzyMatch.isSubsequence("PTC", of: "process.top_cpu"))
        #expect(!FuzzyMatch.isSubsequence("zz", of: "files.largest"))
        #expect(FuzzyMatch.spread("files", in: "files.largest") == 0)
        #expect(FuzzyMatch.spread("fil", in: "files.largest") < FuzzyMatch.spread("fla", in: "files.largest"))
        #expect(FuzzyMatch.spread("xyz", in: "abc") == Int.max)
        // Word-start matches win: "flg" → files.largest before security.file_signature.
        let a = FuzzyMatch.score("flg", in: "files.largest"), b = FuzzyMatch.score("flg", in: "security.file_signature")
        #expect(a != nil && b != nil && a! < b!)
        #expect(FuzzyMatch.score("ptc", in: "process.top_cpu")! < FuzzyMatch.score("ptc", in: "process.tree_cpu_x")!)
        #expect(FuzzyMatch.score("zz", in: "files.largest") == nil)
        #expect(FuzzyMatch.score("", in: "x") == 0)
    }
}


@Suite("Pinned process alerts")
struct PinnedProcessTests {
    func snap(_ names: [String], _ t: Double) -> MonitorSnapshot {
        MonitorSnapshot(time: Date(timeIntervalSince1970: t), cpu: .unavailable("x"), memory: .unavailable("x"), loadAverages: nil,
                        volumes: [], interfaces: [],
                        processes: names.enumerated().map { i, n in
                            ProcessSample(pid: pid_t(100 + i), ppid: 1, uid: 501, user: "me", name: n, path: nil, cpuPercent: 1,
                                          residentBytes: 1, threadCount: 1, cpuTimeSeconds: 1, startTime: nil, source: .libproc)
                        },
                        restrictedProcessCount: 0, unavailableProcessCount: 0, collectionDuration: 0, history: [], bootTime: nil)
    }

    @Test func reportsStopAndStartTransitionsOnly() {
        var d = AnomalyDetector()
        d.watchedNames = ["node", "redis-server"]
        #expect(d.evaluate(snap(["node"], 0)).isEmpty)                 // initial state is never an alert
        #expect(d.evaluate(snap(["node"], 1)).isEmpty)
        let stopped = d.evaluate(snap([], 2))
        #expect(stopped.map(\.key) == ["pin.node.stop"])
        #expect(d.evaluate(snap([], 3)).isEmpty)
        let started = d.evaluate(snap(["node", "redis-server"], 4))
        #expect(Set(started.map(\.key)) == ["pin.node.start", "pin.redis-server.start"])
        #expect(started.allSatisfy { $0.level == .notice })
    }

    @Test func pinnedListIsBounded() {
        var s = HackCodeSettings()
        s.pinnedProcesses = (0..<20).map { "p\($0)" }
        s.clamp()
        #expect(s.pinnedProcesses.count == 12)
    }
}


@Suite("Aliases")
struct AliasTests {
    @Test func validation() {
        let reserved: Set<String> = ["help", "files.largest"]
        #expect(throws: Never.self) { try AliasBook.validate(name: "dl", expansion: "/files.largest path=~/Downloads", reserved: reserved, existing: [:]) }
        #expect(throws: AliasBook.AliasError.invalidName) { try AliasBook.validate(name: "Bad Name", expansion: "/ops", reserved: reserved, existing: [:]) }
        #expect(throws: AliasBook.AliasError.reservedName("help")) { try AliasBook.validate(name: "help", expansion: "/ops", reserved: reserved, existing: [:]) }
        #expect(throws: AliasBook.AliasError.emptyExpansion) { try AliasBook.validate(name: "x", expansion: "  ", reserved: reserved, existing: [:]) }
        #expect(throws: AliasBook.AliasError.selfReference) { try AliasBook.validate(name: "x", expansion: "/x limit=3", reserved: reserved, existing: [:]) }
        let full = Dictionary(uniqueKeysWithValues: (0..<50).map { ("a\($0)", "/ops") })
        #expect(throws: AliasBook.AliasError.tooMany) { try AliasBook.validate(name: "new", expansion: "/ops", reserved: reserved, existing: full) }
    }

    @Test func expansionIsSingleLevelAndAppendsArguments() {
        let aliases = ["dl": "/files.largest path=~/Downloads", "loop": "/dl"]
        #expect(AliasBook.expand("/dl", aliases: aliases) == "/files.largest path=~/Downloads")
        #expect(AliasBook.expand("/dl limit=5", aliases: aliases) == "/files.largest path=~/Downloads limit=5")
        #expect(AliasBook.expand("/loop", aliases: aliases) == "/dl")          // not expanded again
        #expect(AliasBook.expand("/ops", aliases: aliases) == nil)
        #expect(AliasBook.expand("dl", aliases: aliases) == nil)
    }
}

@Suite("Output pipeline")
struct OutputPipelineTests {
    let text = "PID NAME\n10 Google Chrome\n20 Safari\n30 google chrome helper\n20 Safari\n5 Finder\n"

    @Test func splitRespectsQuotes() {
        let (cmd, stages) = OutputPipeline.split(#"/process.top_cpu limit=20 | grep -i "google chrome" | head 2"#)
        #expect(cmd == "/process.top_cpu limit=20")
        #expect(stages == [#"grep -i "google chrome""#, "head 2"])
        #expect(OutputPipeline.split("/ops").stages.isEmpty)
    }

    @Test func stagesTransformText() throws {
        #expect(try OutputPipeline.parse([#"grep -i "google chrome""#]).apply(text) == "10 Google Chrome\n30 google chrome helper")
        #expect(try OutputPipeline.parse(["grep -v Safari", "tail 2"]).apply(text) == "30 google chrome helper\n5 Finder")
        #expect(try OutputPipeline.parse(["grep Safari", "uniq", "wc -l"]).apply(text) == "1")
        #expect(try OutputPipeline.parse(["tail -n 5", "sort -rn", "head -1"]).apply(text) == "30 google chrome helper")
        #expect(try OutputPipeline.parse(["head 1"]).apply(text) == "PID NAME")
        // sort -rn: non-numeric lines count as 0, so the header sinks to the bottom (like sort(1)).
        #expect(try OutputPipeline.parse(["sort -rn"]).apply(text).split(separator: "\n").last == "PID NAME")
    }

    @Test func rejectsAnythingThatIsNotAFilter() {
        for bad in [["sh -c id"], ["rm -rf ~"], ["grep"], ["head abc"], ["head 0"], ["sort -x"], ["wc -c"], ["xargs kill"], [""]] {
            #expect(throws: OutputPipeline.ParseError.self, "\(bad)") { try OutputPipeline.parse(bad) }
        }
        #expect(throws: OutputPipeline.ParseError.tooManyStages) { try OutputPipeline.parse(Array(repeating: "uniq", count: 9)) }
    }

    @Test func describesItself() throws {
        #expect(try OutputPipeline.parse(["grep -i x", "sort -rn", "head 3"]).description == "| grep -i x | sort -rn | head 3")
    }
}

@Suite("Crash report watcher")
struct CrashWatcherTests {
    @Test func reportsOnlyNewReports() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("user")
        try t.write("user/Old-2026-10-01-101010.ips")
        var w = CrashReportWatcher(directories: [t.path("user"), t.path("missing")])
        #expect(w.check().isEmpty)                                   // first call primes only
        try t.write("user/Safari-2026-10-21-111111.ips")
        try t.write("user/notes.txt")
        try t.write("user/Finder_2026-10-21-121212.hang")
        let fresh = w.check()
        #expect(fresh.map(\.app).sorted() == ["Finder", "Safari"])
        #expect(fresh.first { $0.app == "Finder" }?.kind == "hang")
        #expect(w.check().isEmpty)                                   // not reported twice
    }

    @Test func appNameParsing() {
        #expect(CrashReportWatcher.appName(from: "Google Chrome Helper-2026-10-21-101010.ips") == "Google Chrome Helper")
        #expect(CrashReportWatcher.appName(from: "ExcUserFault_Xcode-2026-10-21-101010.ips") == "Xcode")
        #expect(CrashReportWatcher.kind(from: "JetsamEvent-2026-10-21-101010.ips") == "memory-pressure kill")
    }
}

@Suite("Process tree")
struct ProcessTreeTests {
    func p(_ pid: pid_t, _ ppid: pid_t, _ name: String, cpu: Double = 1, rss: UInt64 = 10) -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, uid: 501, user: "me", name: name, path: nil, cpuPercent: cpu, residentBytes: rss,
                      threadCount: 1, cpuTimeSeconds: 1, startTime: nil, source: .libproc)
    }

    @Test func buildsHierarchyWithSubtreeTotals() {
        let samples = [p(1, 0, "launchd"), p(10, 1, "Chrome", cpu: 5), p(11, 10, "Helper", cpu: 20), p(12, 10, "Helper GPU", cpu: 3),
                       p(20, 1, "Finder"), p(99, 4242, "orphan")]
        let rows = ProcessTree.rows(samples) { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
        #expect(rows.map(\.sample.name) == ["launchd", "Chrome", "Helper", "Helper GPU", "Finder", "orphan"])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 0])
        let chrome = rows.first { $0.sample.pid == 10 }!
        #expect(chrome.subtreeCPU == 28 && chrome.subtreeCount == 3 && chrome.hasChildren)
        #expect(rows.first { $0.sample.pid == 12 }!.isLastSibling)
    }

    @Test func collapsingHidesDescendants() {
        let samples = [p(1, 0, "launchd"), p(10, 1, "Chrome"), p(11, 10, "Helper")]
        let rows = ProcessTree.rows(samples, collapsed: [10]) { $0.pid < $1.pid }
        #expect(rows.map(\.sample.pid) == [1, 10])
        #expect(rows[1].subtreeCount == 2)
    }

    @Test func survivesParentCycles() {
        let rows = ProcessTree.rows([p(5, 6, "a"), p(6, 5, "b")]) { $0.pid < $1.pid }
        #expect(Set(rows.map(\.sample.pid)) == [5, 6])
    }
}

@Suite("Audit log filter")
struct AuditLogFilterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func events() -> [AuditEvent] {
        [
            AuditEvent(kind: .approvalGranted, operation: "process.terminate", risk: .elevated, provenance: .user, outcome: "granted", timestamp: now.addingTimeInterval(-60)),
            AuditEvent(kind: .executionFinished, operation: "disk.usage", outcome: "exit 0", detail: "du ~/Downloads", timestamp: now.addingTimeInterval(-7200)),
            AuditEvent(kind: .monitorAlert, operation: "monitor.memory", outcome: "warning", detail: "Memory pressure WARNING", timestamp: now.addingTimeInterval(-3 * 86_400)),
            AuditEvent(kind: .settingsChanged, outcome: "saved", detail: "model=x", timestamp: now.addingTimeInterval(-30 * 86_400)),
        ]
    }

    @Test func categoryWindowAndTermsCombine() {
        let all = events()
        #expect(AuditLogFilter().apply(all, now: now).count == 4)
        #expect(AuditLogFilter(category: .approvals).apply(all, now: now).map(\.operation) == ["process.terminate"])
        #expect(AuditLogFilter(window: .hour).apply(all, now: now).count == 1)
        #expect(AuditLogFilter(window: .week).apply(all, now: now).count == 3)
        // Every term must match, case-insensitively, across fields; "-term" excludes.
        #expect(AuditLogFilter(query: "DISK exit").apply(all, now: now).count == 1)
        #expect(AuditLogFilter(query: "disk warning").apply(all, now: now).isEmpty)
        #expect(AuditLogFilter(query: "-monitor").apply(all, now: now).count == 3)
        #expect(AuditLogFilter(query: "elevated").apply(all, now: now).count == 1)
        #expect(!AuditLogFilter().isActive)
        #expect(AuditLogFilter(query: "x").isActive)
    }

    @Test func countsIgnoreCategoryButRespectOtherFilters() {
        let c = AuditLogFilter(category: .monitor, window: .week).counts(events(), now: now)
        #expect(c[.all] == 3)
        #expect(c[.monitor] == 1)
        #expect(c[.settings] == 0)
    }

    @Test func historyReadsPersistedEventsAcrossInstancesAndSkipsBadLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hc-auditlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audit-log.jsonl")
        let first = AuditLogService(fileURL: url)
        await first.record(AuditEvent(kind: .settingsChanged, outcome: "saved", detail: "one"))
        await first.record(AuditEvent(kind: .monitorAlert, outcome: "warning", detail: "two"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        let second = AuditLogService(fileURL: url)          // a later session: empty memory
        #expect(await second.recent(limit: 10).isEmpty)
        let h = await second.history(limit: 10)
        #expect(h.map(\.detail) == ["one", "two"])
        #expect(await second.history(limit: 1).map(\.detail) == ["two"])
        // In-memory logs (tests) fall back to the session list.
        let mem = AuditLogService(fileURL: nil)
        await mem.record(AuditEvent(kind: .historyCleared, outcome: "cleared"))
        #expect(await mem.history(limit: 5).count == 1)
    }

    @Test func csvEscapesAndGuardsFormulas() {
        let e = AuditEvent(kind: .executionFinished, operation: "files.find", outcome: "=HYPERLINK(\"x\")", detail: "a,b\nc", timestamp: now)
        let csv = AuditLogFilter.csv([e])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "timestamp,kind,operation,risk,provenance,outcome,detail")
        #expect(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""))
        #expect(csv.contains("\"a,b\nc\""))
        #expect(AuditLogFilter.csvCell("-1") == "'-1")
        #expect(AuditLogFilter.csvCell("plain") == "plain")
    }
}

@Suite("Settings change summary")
struct SettingsChangeSummaryTests {
    @Test func listsOnlyChangedKeyNames() {
        let old = HackCodeSettings()
        var new = old
        #expect(new.changedKeys(from: old).isEmpty)
        new.terminalTheme = "amber"
        new.aliases = ["ll": "/run files.list path=~"]
        new.alertThresholds.processCPUPercent += 5
        let keys = new.changedKeys(from: old)
        #expect(keys == ["alertThresholds", "aliases", "terminalTheme"])
        #expect(!keys.joined().contains("files.list"))     // values never leak into the summary
    }
}

@Suite("Trends")
struct TrendTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func logKeepsHourlySpacingAndRetention() {
        var log = TrendLog()
        let a = log.add(TrendSample(time: t0, diskFreeBytes: 100))
        let b = log.add(TrendSample(time: t0.addingTimeInterval(1800), diskFreeBytes: 99))   // < 1 h later
        let c = log.add(TrendSample(time: t0.addingTimeInterval(3600), diskFreeBytes: 98))
        #expect(a && !b && c)
        #expect(log.samples.count == 2)
        // A sample 200 days later prunes everything older than the 180-day retention.
        let d = log.add(TrendSample(time: t0.addingTimeInterval(200 * 86_400), diskFreeBytes: 50))
        #expect(d)
        #expect(log.samples.count == 1)
        #expect(log.within(days: 1, now: t0.addingTimeInterval(200 * 86_400)).count == 1)
    }

    @Test func forecastFindsLinearTrendAndRefusesThinData() {
        // 10 GB free, losing 1 GB/day over 4 days → 6 GB now → ~6 days to full.
        let gb = 1_000_000_000.0
        let pts = (0...4).map { (t0.addingTimeInterval(Double($0) * 86_400), 10 * gb - Double($0) * gb) }
        let slope = TrendForecast.slopePerDay(pts)
        #expect(slope.map { abs($0 + gb) < 1 } == true)
        #expect(TrendForecast.daysUntil(0, points: pts).map { abs($0 - 6) < 0.001 } == true)
        #expect(TrendForecast.daysUntil(20 * gb, points: pts) == nil)              // moving away from it
        #expect(TrendForecast.slopePerDay(Array(pts.prefix(2))) == nil)             // too few points
        let hours = (0..<10).map { (t0.addingTimeInterval(Double($0) * 3600), Double($0)) }
        #expect(TrendForecast.slopePerDay(hours) == nil)                            // span < 2 days
        let samples = pts.map { TrendSample(time: $0.0, diskFreeBytes: Int64($0.1)) }
        #expect(TrendForecast.diskSummary(samples).contains("full in about 6 days"))
        let at = t0.addingTimeInterval(4 * 86_400)
        #expect(TrendForecast.diskFullWithin(samples, now: at).map { abs($0 - 6) < 0.001 } == true)
        #expect(TrendForecast.diskFullWithin(samples, horizonDays: 5, now: at) == nil)
        #expect(TrendForecast.diskFullWithin(samples, now: at.addingTimeInterval(30 * 86_400)) == nil)   // samples outside the window
        #expect(TrendForecast.diskSummary([]).hasPrefix("Collecting data"))
        let report = TrendForecast.textReport(TrendLog(samples: samples), now: at)
        #expect(report.contains("samples   5 ·"))
        #expect(report.contains("disk      6 GB free"))
        #expect(report.contains("full in about 6 days"))
        #expect(TrendForecast.textReport(TrendLog()).hasPrefix("No trend samples yet"))
    }

    @Test func storeRoundTripsOwnerOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hc-trends-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trends.json")
        let store = TrendStore(url: url)
        await store.record(TrendSample(time: t0, diskFreeBytes: 5, batteryHealth: 0.9, batteryCycles: 100))
        await store.record(TrendSample(time: t0.addingTimeInterval(60), diskFreeBytes: 4))   // ignored (spacing)
        let log = await TrendStore(url: url).load()
        #expect(log.samples.count == 1)
        #expect(log.samples.first?.batteryCycles == 100)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(TrendSample.current().time <= Date())
    }
}

@Suite("Settings transfer")
struct SettingsTransferTests {
    let reserved: Set<String> = ["run", "alias", "help"]

    @Test func roundTripsWithoutEndpoint() throws {
        var s = HackCodeSettings()
        s.terminalTheme = "amber"
        s.aliases = ["dl": "/files.largest path=~/Downloads"]
        s.matrixRainIntensity = 0.4
        let data = try SettingsTransfer.export(s)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\" : \"hackcode-settings\""))
        #expect(!text.contains("baseURL"))
        let r = try SettingsTransfer.importSettings(data, into: HackCodeSettings(), reservedAliasNames: reserved)
        #expect(r.settings.terminalTheme == "amber")
        #expect(r.settings.aliases == ["dl": "/files.largest path=~/Downloads"])
        #expect(r.changedKeys == ["aliases", "matrixRainIntensity", "terminalTheme"])
        #expect(r.privacyWarnings.isEmpty && r.skippedAliases.isEmpty)
    }

    @Test func neverImportsEndpointAndRevalidates() throws {
        var current = HackCodeSettings()
        current.shareProcessSnapshotWithModel = false
        let evil: [String: Any] = ["format": "hackcode-settings", "version": 1, "settings": [
            "baseURL": "https://attacker.example/v1",
            "matrixRainIntensity": 9.0,
            "shareProcessSnapshotWithModel": true,
            "aliases": ["ok": "/process.top_cpu", "run": "/x", "BAD NAME": "/y", "loop": "/loop"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: evil)
        let r = try SettingsTransfer.importSettings(data, into: current, reservedAliasNames: reserved)
        #expect(r.settings.baseURL == current.baseURL)
        #expect(r.settings.matrixRainIntensity == 1.0)                    // clamped
        #expect(r.privacyWarnings == ["shareProcessSnapshotWithModel"])
        #expect(r.settings.aliases == ["ok": "/process.top_cpu"])
        #expect(Set(r.skippedAliases) == ["run", "BAD NAME", "loop"])     // reserved, invalid, self-reference
    }

    @Test func rejectsForeignOversizedFutureAndMistypedFiles() throws {
        let s = HackCodeSettings()
        func data(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
        #expect(throws: SettingsTransfer.ImportError.notASettingsFile) {
            try SettingsTransfer.importSettings(try data(["hello": 1]), into: s, reservedAliasNames: reserved)
        }
        #expect(throws: SettingsTransfer.ImportError.unsupportedVersion(9)) {
            try SettingsTransfer.importSettings(try data(["format": "hackcode-settings", "version": 9, "settings": [:]]), into: s, reservedAliasNames: reserved)
        }
        #expect(throws: SettingsTransfer.ImportError.tooLarge) {
            try SettingsTransfer.importSettings(Data(count: SettingsTransfer.maxBytes + 1), into: s, reservedAliasNames: reserved)
        }
        #expect(throws: SettingsTransfer.ImportError.self) {
            try SettingsTransfer.importSettings(try data(["format": "hackcode-settings", "version": 1, "settings": ["matrixRain": "yes"]]), into: s, reservedAliasNames: reserved)
        }
    }
}

@Suite("Session recap")
struct SessionRecapTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func report(_ app: String, _ kind: String, hoursAgo: Double) -> CrashReportWatcher.Report {
        CrashReportWatcher.Report(name: "\(app).ips", app: app, kind: kind, date: now.addingTimeInterval(-hoursAgo * 3600), systemWide: false)
    }

    @Test func quietAfterShortGapOrNoHistory() {
        let recent = [TrendSample(time: now.addingTimeInterval(-3600), diskFreeBytes: 100)]
        #expect(SessionRecap.make(previous: recent, current: TrendSample(time: now), crashes: [], lastAudit: nil, now: now) == nil)
        #expect(SessionRecap.make(previous: [], current: TrendSample(time: now), crashes: [], lastAudit: nil, now: now) == nil)
    }

    @Test func summarisesDiskBatteryCrashesAndAudit() throws {
        let gb: Int64 = 1_000_000_000
        let prev = [TrendSample(time: now.addingTimeInterval(-52 * 3600), diskFreeBytes: 170 * gb, diskTotalBytes: 500 * gb,
                                batteryHealth: 0.920, batteryCycles: 148)]
        let cur = TrendSample(time: now, diskFreeBytes: 160 * gb, diskTotalBytes: 500 * gb, batteryHealth: 0.915, batteryCycles: 150)
        let crashes = [report("Safari", "crash", hoursAgo: 10), report("Safari", "crash", hoursAgo: 5),
                       report("Xcode", "hang", hoursAgo: 2), report("Old", "crash", hoursAgo: 100)]   // "Old" predates the gap
        let audit = AuditSummary(date: now.addingTimeInterval(-9 * 86_400), score: 82)
        let r = try #require(SessionRecap.make(previous: prev, current: cur, crashes: crashes, lastAudit: audit, now: now))
        let byKey = Dictionary(uniqueKeysWithValues: r.lines.map { ($0.key, $0) })
        #expect(byKey["away"]?.text.hasPrefix("last session 2 d 4 h ago") == true)
        #expect(byKey["disk"]?.text.hasPrefix("−10 GB free since then") == true)
        #expect(byKey["disk"]?.warn == true)                                  // lost > 5 GB
        #expect(byKey["battery"]?.text == "health 91.5% (-0.5 pts) · 150 cycles (+2)")
        #expect(byKey["crashes"]?.text.hasPrefix("3 new reports: Safari ×2 (crash), Xcode (hang)") == true)
        #expect(byKey["crashes"]?.warn == true)
        #expect(byKey["audit"]?.text.contains("9 d ago · score 82 — consider re-running") == true)
        let quiet = try #require(SessionRecap.make(previous: prev, current: TrendSample(time: now, diskFreeBytes: 170 * gb), crashes: [],
                                                   lastAudit: AuditSummary(date: now.addingTimeInterval(-86_400), score: 90), now: now))
        #expect(quiet.lines.map(\.key) == ["away", "crashes", "audit"])     // unchanged disk, no battery data → omitted
        #expect(quiet.lines.allSatisfy { !$0.warn })
        #expect(SessionRecap.duration(45 * 60) == "45 min" && SessionRecap.duration(8 * 86_400) == "8 d")
    }
}

@Suite("Audit timeline")
struct AuditTimelineTests {
    @Test func buildsMatrixCountsFlipsAndSortsIssuesFirst() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ day: Double, _ checks: [String: String]) -> AuditSummary {
            AuditSummary(date: t0.addingTimeInterval(day * 86_400), score: 80,
                         checks: checks.mapValues { AuditSummary.Entry(status: $0, severity: "LOW", title: $0 == "x" ? "" : "T") })
        }
        let history = [
            run(2, ["fw": "ISSUE", "fv": "PASS", "ssh": "PASS"]),
            run(0, ["fw": "PASS", "fv": "PASS"]),
            run(1, ["fw": "REMEDIATED", "fv": "COULD NOT RUN"]),
        ]
        let t = AuditTimeline.make(history)
        #expect(t.runs.map(\.date) == history.map(\.date).sorted())
        #expect(t.rows.first?.id == "fw")                                   // current issue first
        let fw = t.rows.first { $0.id == "fw" }
        #expect(fw?.cells == [.pass, .pass, .issue])                         // REMEDIATED counts as pass
        #expect(fw?.flips == 1)
        let ssh = t.rows.first { $0.id == "ssh" }
        #expect(ssh?.cells == [nil, nil, .pass])                             // added in the latest run
        #expect(t.rows.first { $0.id == "fv" }?.flips == 2)
        #expect(AuditTimeline.issueCount(history[0]) == 1)
        #expect(AuditTimeline.make(history, lastRuns: 2).runs.count == 2)
    }
}

@Suite("Posture change markers")
struct PostureChangeMarkerTests {
    @Test func onlyIssueToPassIsAnImprovement() {
        #expect(PostureChange(checkID: "a", title: "A", from: "ISSUE", to: "PASS").marker == "▲")
        #expect(PostureChange(checkID: "a", title: "A", from: "PASS", to: "ISSUE").marker == "▼")
        #expect(PostureChange(checkID: "a", title: "A", from: "PASS", to: "COULD NOT RUN").marker == "•")
        #expect(PostureChange(checkID: "a", title: "A", from: "COULD NOT RUN", to: "PASS").marker == "•")
    }
}

@Suite("Treemap")
struct TreemapTests {
    @Test func tilesAreProportionalInBoundsAndDisjoint() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1, 0, 500, 0.5]
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let rects = Treemap.squarify(values, in: bounds)
        #expect(rects.count == values.count)
        #expect(rects[7] == .zero)
        let total = values.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        for (v, r) in zip(values, rects) where v > 0 {
            #expect(abs(Double(r.width * r.height) - v / total * area) < area * 0.001, "area for \(v)")
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(r), "bounds for \(v)")
        }
        for i in rects.indices { for j in rects.indices where i < j {
            let overlap = rects[i].intersection(rects[j])
            #expect(overlap.isNull || overlap.width * overlap.height < 0.01, "overlap \(i) \(j)")
        } }
        // Total coverage = whole rectangle.
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - area) < 1)
    }

    @Test func squarishTilesForEvenValues() {
        let rects = Treemap.squarify(Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 99
        #expect(worst < 1.8)
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(Treemap.squarify([1, 2], in: .zero) == [.zero, .zero])
    }
}

@Suite("Wi-Fi")
struct WiFiTests {
    func status(_ sec: WiFiSecurity, rssi: Int = -60, associated: Bool = true) -> WiFiStatus {
        WiFiStatus(interface: "en0", poweredOn: true, associated: associated, rssi: rssi, noise: -92, transmitRateMbps: 204,
                   security: sec, phyMode: "802.11ax (Wi-Fi 6/6E)", channel: 44, band: "5 GHz", channelWidthMHz: 160)
    }

    @Test func classifiesSecurityAndSignal() {
        #expect(WiFiSecurity(cwRawValue: 0) == .open)
        #expect(WiFiSecurity(cwRawValue: 6) == .wep)
        #expect(WiFiSecurity(cwRawValue: 11) == .wpa3)
        #expect(WiFiSecurity(cwRawValue: 99) == .unknown)
        #expect(WiFiSecurity.open.strength == .weak && WiFiSecurity.wpaMixed.strength == .fair)
        #expect(WiFiSecurity.wpa2.strength == .good && WiFiSecurity.wpa3.strength == .strong)
        #expect(SignalQuality(rssi: -50) == .excellent && SignalQuality(rssi: -67) == .good)
        #expect(SignalQuality(rssi: -71) == .fair && SignalQuality(rssi: -80) == .poor)
        #expect(status(.wpa3, rssi: -71).snr == 21)
    }

    @Test func auditCheckJudgesEncryptionFromEvidence() {
        func eval(_ s: WiFiStatus) -> Evaluation {
            SecurityToolRegistry.evaluateWiFi(CollectedEvidence(items: [], raw: s.evidenceText))
        }
        #expect(eval(status(.open)).status == .issue && eval(status(.open)).severity == .high)
        #expect(eval(status(.wpa)).severity == .medium)
        #expect(eval(status(.owe)).severity == .low)
        #expect(eval(status(.wpa2)).status == .pass)
        #expect(eval(status(.wpa3)).status == .pass)
        #expect(eval(status(.wpa3, associated: false)).status == .observed)
        #expect(eval(status(.unknown)).status == .couldNotRun)
        #expect(!status(.wpa3).evidenceText.lowercased().contains("ssid"))
    }
}

@Suite("Open Quickly")
struct QuickOpenTests {
    let items = [
        QuickItem(id: "m.monitor", kind: .module, title: "MONITOR", subtitle: "live activity"),
        QuickItem(id: "p.1", kind: .process, title: "kernel_task", subtitle: "pid 0 · root"),
        QuickItem(id: "p.2", kind: .process, title: "Google Chrome Helper", subtitle: "pid 812"),
        QuickItem(id: "f.fw", kind: .finding, title: "Application Firewall", subtitle: "ISSUE · MEDIUM"),
        QuickItem(id: "d.dl", kind: .folder, title: "Downloads", subtitle: "~/Downloads · 3 GB"),
        QuickItem(id: "o.top", kind: .operation, title: "process.top_cpu", subtitle: "Top CPU processes"),
        QuickItem(id: "c.trends", kind: .command, title: "/trends", subtitle: "Long-term trends"),
    ]

    @Test func ranksPrefixWordStartsAndSubtitles() {
        #expect(QuickOpen.rank(items, query: "mon").first?.id == "m.monitor")
        #expect(QuickOpen.rank(items, query: "kern").first?.id == "p.1")
        #expect(QuickOpen.rank(items, query: "gch").first?.id == "p.2")                 // word starts G… C… H…
        #expect(QuickOpen.rank(items, query: "app fire").first?.id == "f.fw")            // spaces ignored
        #expect(QuickOpen.rank(items, query: "issue").map(\.id) == ["f.fw"])            // subtitle-only match
        #expect(QuickOpen.rank(items, query: "/tr").first?.id == "c.trends")
        #expect(QuickOpen.rank(items, query: "zzz").isEmpty)
        let noisy = items + [QuickItem(id: "p.tg", kind: .process, title: "TGOnDeviceInferenceProviderService")]
        #expect(QuickOpen.rank(noisy, query: "trends").map(\.id) == ["c.trends"])        // scattered match rejected
        #expect(QuickOpen.rank(items, query: "", limit: 3).map(\.id) == ["m.monitor", "p.1", "p.2"])
        #expect(QuickOpen.rank(items, query: "o", limit: 2).count == 2)
    }
}

@Suite("Listener watch")
struct ListenerWatchTests {
    typealias Row = SecurityToolRegistry.ListenRow

    @Test func primesThenReportsNewListenersOnce() {
        var w = ListenerWatch()
        #expect(w.update([Row(command: "rapportd", pid: "500", address: "*", port: "49152")]).isEmpty)        // prime
        let fresh = w.update([Row(command: "rapportd", pid: "500", address: "*", port: "49152"),
                              Row(command: "python3", pid: "900", address: "127.0.0.1", port: "8000"),
                              Row(command: "node", pid: "901", address: "127.0.0.1", port: "3000"),
                              Row(command: "node", pid: "901", address: "[::]", port: "3000")])                  // IPv6 any → exposed
        #expect(fresh.map(\.key) == ["node:3000", "python3:8000"])
        #expect(fresh.first { $0.command == "node" }?.exposed == true)
        #expect(fresh.first { $0.command == "python3" }?.exposed == false)
        // Stops and restarts: not reported again.
        #expect(w.update([]).isEmpty)
        #expect(w.update([Row(command: "python3", pid: "950", address: "127.0.0.1", port: "8000")]).isEmpty)
    }

    @Test func parsesRealLsofOutput() {
        let text = """
        COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        ControlCe 612 shaurya   9u  IPv4 0x1234567890abcdef      0t0  TCP *:7000 (LISTEN)
        python3.1 900 shaurya   3u  IPv4 0x1234567890abcde0      0t0  TCP 127.0.0.1:8000 (LISTEN)
        """
        var w = ListenerWatch()
        _ = w.update([])
        let fresh = w.update(SecurityToolRegistry.parseLsofListen(text))
        #expect(fresh.map(\.key) == ["ControlCe:7000", "python3.1:8000"])
        #expect(fresh.first?.exposed == true)
    }
}

@Suite("App inventory")
struct AppInventoryTests {
    func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    @Test func readsThinAndFatHeaders() {
        let thinArm = Data(le(0xFEED_FACF) + le(0x0100_000C) + [UInt8](repeating: 0, count: 24))
        let thinIntel = Data(le(0xFEED_FACF) + le(0x0100_0007) + [UInt8](repeating: 0, count: 24))
        var fat = be(0xCAFE_BABE) + be(2)
        fat += be(0x0100_0007) + [UInt8](repeating: 0, count: 16)
        fat += be(0x0100_000C) + [UInt8](repeating: 0, count: 16)
        #expect(AppInventory.classify(AppInventory.architectures(ofHeader: thinArm)) == .appleSilicon)
        #expect(AppInventory.classify(AppInventory.architectures(ofHeader: thinIntel)) == .intel)
        #expect(AppInventory.classify(AppInventory.architectures(ofHeader: Data(fat))) == .universal)
        #expect(AppInventory.classify(AppInventory.architectures(ofHeader: Data("#!/bin/sh\n".utf8))) == .unknown)
        #expect(AppInventory.architectures(ofHeader: Data(be(0xCAFE_BABE) + be(9999))).isEmpty)       // absurd count rejected
        #expect(AppArchitecture.intel.needsRosetta && !AppArchitecture.universal.needsRosetta)
    }

    @Test func scansBundlesInAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hc-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let macos = dir.appendingPathComponent("Old Tool.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try (["CFBundleExecutable": "oldtool", "CFBundleName": "Old Tool", "CFBundleIdentifier": "com.example.old",
              "CFBundleShortVersionString": "1.2"] as NSDictionary).write(to: dir.appendingPathComponent("Old Tool.app/Contents/Info.plist"))
        try Data(le(0xFEED_FACF) + le(0x0100_0007) + [UInt8](repeating: 0, count: 24)).write(to: macos.appendingPathComponent("oldtool"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("NotAnApp"), withIntermediateDirectories: true)
        // A bundle whose executable is missing, and a script launcher.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Broken.app/Contents"), withIntermediateDirectories: true)
        try (["CFBundleExecutable": "stub", "CFBundleName": "Broken"] as NSDictionary).write(to: dir.appendingPathComponent("Broken.app/Contents/Info.plist"))
        let scriptDir = dir.appendingPathComponent("Script.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try (["CFBundleExecutable": "run", "CFBundleName": "Script"] as NSDictionary).write(to: dir.appendingPathComponent("Script.app/Contents/Info.plist"))
        try Data("#!/bin/sh\nexec java -jar x.jar\n".utf8).write(to: scriptDir.appendingPathComponent("run"))
        let all = AppInventory.scan(folders: [dir.path, dir.path])                                     // duplicates folded
        #expect(all.map(\.name) == ["Broken", "Old Tool", "Script"])
        #expect(all.map(\.architecture) == [.missing, .intel, .script])
        let apps = all.filter { $0.name == "Old Tool" }
        #expect(apps.count == 1)
        #expect(apps.first?.name == "Old Tool" && apps.first?.version == "1.2" && apps.first?.architecture == .intel)
        #expect(apps.first?.isApple == false)
    }
}
