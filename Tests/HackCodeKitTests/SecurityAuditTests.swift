import Testing
import Foundation
@testable import HackCodeKit

@Suite("Security checks (canned evidence)")
struct SecurityCheckTests {
    let registry = SecurityToolRegistry.standard()

    func eval(_ id: String, _ raw: String, failure: String? = nil) -> Evaluation {
        registry.check(id: id)!.evaluate(CollectedEvidence(items: [], raw: raw, failure: failure))
    }

    @Test func firewall() {
        #expect(eval("firewall", "Firewall is enabled. (State = 1)").status == .pass)
        let off = eval("firewall", "Firewall is disabled. (State = 0)")
        #expect(off.status == .issue && off.severity == .medium)
        #expect(eval("firewall", "garbage").status == .couldNotRun)
        #expect(eval("firewall", "", failure: "timed out").status == .couldNotRun)
    }

    @Test func fileVaultSipGatekeeper() {
        #expect(eval("filevault", "FileVault is On.").status == .pass)
        #expect(eval("filevault", "FileVault is Off.").severity == .high)
        #expect(eval("sip", "System Integrity Protection status: enabled.").status == .pass)
        #expect(eval("sip", "System Integrity Protection status: disabled.").severity == .high)
        #expect(eval("sip", "System Integrity Protection status: unknown (Custom Configuration).").severity == .medium)
        #expect(eval("gatekeeper", "assessments enabled").status == .pass)
        #expect(eval("gatekeeper", "assessments disabled").status == .issue)
    }

    @Test func screenLock() {
        #expect(eval("screen-lock", "2026-10-21 sysadminctl[1:2] screenLock delay is immediate").status == .pass)
        #expect(eval("screen-lock", "screenLock delay is 3600 seconds").severity == .medium)
        #expect(eval("screen-lock", "screenLock delay is 60 seconds").severity == .low)
        #expect(eval("screen-lock", "screenLock is off").status == .issue)
    }

    @Test func autoUpdatesAndLoginWindow() {
        #expect(eval("auto-updates", "AutomaticCheckEnabled = 1\nCriticalUpdateInstall = 1\nConfigDataInstall = 1").status == .pass)
        #expect(eval("auto-updates", "AutomaticCheckEnabled = 1\nCriticalUpdateInstall = 0\nConfigDataInstall = 1").status == .issue)
        let unset = eval("auto-updates", "AutomaticCheckEnabled = (not set — macOS default)")
        #expect(unset.status == .pass && unset.confidence == .medium)
        #expect(eval("auto-login", "autoLoginUser = (set)").severity == .high)
        #expect(eval("guest-account", "GuestEnabled = 1").severity == .low)
    }

    @Test func pendingUpdates() {
        #expect(eval("pending-updates", "Software Update Tool\n\nNo new software available.").status == .pass)
        let pending = eval("pending-updates", "* Label: macOS 27.0.1-26A434\n\tTitle: macOS 27.0.1, Version: 27.0.1, Size: 3235867KiB,")
        #expect(pending.status == .issue && pending.severity == .medium)
    }

    @Test func remoteServicesAndListeners() {
        #expect(eval("remote-login", "Bad request.\nCould not find service \"com.openssh.sshd\" in domain for system").status == .pass)
        #expect(eval("remote-login", "system/com.openssh.sshd = {\n\tstate = waiting").status == .issue)
        let lsof = """
        COMMAND     PID        USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    768 me   10u  IPv4 0xc1d00cb9f586a35b      0t0  TCP *:56712 (LISTEN)
        node       1234 me   20u  IPv4 0x1      0t0  TCP 127.0.0.1:3000 (LISTEN)
        """
        let rows = SecurityToolRegistry.parseLsofListen(lsof)
        #expect(rows.count == 2)
        #expect(rows[0].allInterfaces && !rows[1].allInterfaces)
        #expect(eval("listening-services", lsof).status == .issue)
    }

    @Test func homePermissions() {
        #expect(eval("home-permissions", "~ mode 750\n~/.ssh mode 700\n~/.ssh/id_ed25519 mode 600").status == .pass)
        let leaky = eval("home-permissions", "~ mode 750\n~/.ssh mode 755\n~/.ssh/id_rsa mode 644")
        #expect(leaky.status == .issue && leaky.severity == .high)
    }
}

@Suite("Security audit service")
struct SecurityAuditServiceTests {
    @Test func failedChecksAreDisclosedNotPassed() async {
        let runner = MockRunner { req in
            if req.executable.hasSuffix("fdesetup") { throw HackCodeError.launchFailed("denied") }
            if req.executable.hasSuffix("socketfilterfw") { return MockRunner.ok("Firewall is disabled. (State = 0)") }
            return MockRunner.ok("unrecognised")
        }
        let service = SecurityAuditService(registry: .standard(), runner: runner, auditLog: AuditLogService(fileURL: nil))
        let run = await service.runAudit(checkIDs: ["firewall", "filevault", "sip"])
        let byID = Dictionary(uniqueKeysWithValues: run.findings.map { ($0.checkID, $0) })
        #expect(byID["firewall"]?.status == .issue)
        #expect(byID["firewall"]?.remediation?.operationID == "security.enable_firewall")
        #expect(byID["filevault"]?.status == .couldNotRun)
        #expect(byID["sip"]?.status == .couldNotRun)
        #expect(run.failedChecks.count == 2)
        // Every check runs sandboxed.
        #expect(runner.requests.allSatisfy { $0.sandbox == .readOnlyNoNetwork })
    }

    @Test func verificationReinspectsState() async {
        let state = LockedBox("Firewall is disabled. (State = 0)")
        let runner = MockRunner { _ in MockRunner.ok(state.value) }
        let service = SecurityAuditService(registry: .standard(), runner: runner, auditLog: AuditLogService(fileURL: nil))
        let before = await service.runCheck(id: "firewall")!
        #expect(before.status == .issue)
        // Remediation "failed" (e.g. timed out) but the setting actually changed: verification must report REMEDIATED.
        state.mutate { $0 = "Firewall is enabled. (State = 1)" }
        let timedOut = ExecutionRecord(id: UUID(), operationID: "security.enable_firewall", displayCommand: "", status: .timedOut,
                                       exitCode: nil, output: "", errorOutput: "", truncated: false, sandboxed: false, startedAt: Date(), duration: 1)
        let after = await service.verify(before, afterExecution: timedOut)
        #expect(after.status == .remediated)
        state.mutate { $0 = "Firewall is disabled. (State = 0)" }
        let again = await service.verify(before, afterExecution: nil)
        #expect(again.status == .unresolved)
    }

    @Test func scoreExcludesChecksThatCouldNotRun() {
        func f(_ s: FindingStatus, _ sev: Severity) -> Finding {
            Finding(id: UUID().uuidString, checkID: "x", title: "x", severity: sev, confidence: .high, component: "", evidence: [],
                    collectedAt: Date(), whyItMatters: "", limitations: [], remediation: nil, verificationSteps: [], status: s, statusNote: nil)
        }
        let run = AuditRun(startedAt: Date(), findings: [f(.pass, .info), f(.issue, .high), f(.couldNotRun, .info)], cancelled: false)
        #expect(run.score == 80)
        #expect(AuditRun(startedAt: Date(), findings: [f(.couldNotRun, .info)], cancelled: false).score == nil)
    }
}
