import Foundation

/// Runs registered read-only checks and the remediate → re-check workflow.
public actor SecurityAuditService {
    public nonisolated let registry: SecurityToolRegistry
    private let runner: ProcessRunning
    private let auditLog: AuditLogging

    public init(registry: SecurityToolRegistry, runner: ProcessRunning = SystemProcessRunner(), auditLog: AuditLogging) {
        self.registry = registry
        self.runner = runner
        self.auditLog = auditLog
    }

    /// Runs the given checks (default: all) concurrently with a small width. Progress is reported per finding.
    public func runAudit(checkIDs: [String]? = nil,
                         progress: @escaping @Sendable (Finding) async -> Void = { _ in }) async -> AuditRun {
        let checks = checkIDs.map { ids in registry.checks.filter { ids.contains($0.id) } } ?? registry.checks
        var run = AuditRun(startedAt: Date(), findings: [], cancelled: false)
        await withTaskGroup(of: Finding.self) { group in
            var iterator = checks.makeIterator()
            let width = 4
            for _ in 0..<width {
                guard let check = iterator.next() else { break }
                group.addTask { await self.runCheck(check) }
            }
            while let finding = await group.next() {
                run.findings.append(finding)
                await progress(finding)
                if Task.isCancelled { run.cancelled = true; group.cancelAll(); continue }
                if let check = iterator.next() { group.addTask { await self.runCheck(check) } }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: checks.enumerated().map { ($1.id, $0) })
        run.findings.sort { (order[$0.checkID] ?? 0) < (order[$1.checkID] ?? 0) }
        run.finishedAt = Date()
        return run
    }

    public func runCheck(id: String) async -> Finding? {
        guard let check = registry.check(id: id) else { return nil }
        return await runCheck(check)
    }

    func runCheck(_ check: SecurityCheck) async -> Finding {
        let collectedAt = Date()
        let runner = self.runner
        let evidence: CollectedEvidence
        do {
            evidence = try await withTimeout(seconds: check.timeoutSeconds + 5) { await check.collect(runner) }
        } catch HackCodeError.timeout(let s) {
            evidence = CollectedEvidence(items: [EvidenceItem(source: check.evidenceMethod, output: "Timed out after \(Int(s)) s")], raw: "", failure: "timed out")
        } catch {
            evidence = CollectedEvidence(items: [EvidenceItem(source: check.evidenceMethod, output: "Cancelled")], raw: "", failure: "cancelled")
        }
        let evaluation = Task.isCancelled && evidence.failure == nil ? Evaluation.couldNotRun("cancelled") : check.evaluate(evidence)
        let finding = Finding(id: check.id, checkID: check.id, title: check.title, severity: evaluation.severity,
                              confidence: evaluation.confidence, component: check.component, evidence: evidence.items,
                              collectedAt: collectedAt, whyItMatters: check.whyItMatters, limitations: check.limitations,
                              remediation: evaluation.status == .issue ? check.remediation : nil,
                              verificationSteps: check.verificationSteps, status: evaluation.status, statusNote: evaluation.note)
        await auditLog.record(AuditEvent(kind: .auditCheckCompleted, operation: "audit.\(check.id)", outcome: finding.status.rawValue,
                                         detail: "\(finding.severity.label) / confidence \(finding.confidence.rawValue): \(evaluation.note ?? "")"))
        return finding
    }

    /// After a remediation attempt (or a manual fix), re-run the check and classify the outcome.
    /// A failed or interrupted remediation is never assumed to have changed nothing: the state is re-inspected.
    public func verify(_ previous: Finding, afterExecution record: ExecutionRecord?) async -> Finding {
        guard let check = registry.check(id: previous.checkID) else { return previous }
        let fresh = await runCheck(check)
        var updated = fresh
        switch fresh.status {
        case .pass:
            updated.status = .remediated
            updated.statusNote = "Verified: " + (fresh.statusNote ?? "check now passes.")
            await auditLog.record(AuditEvent(kind: .remediationVerified, operation: "audit.\(check.id)", outcome: "REMEDIATED",
                                             detail: record.map { "after \($0.operationID): \($0.status.rawValue)" } ?? "manual fix"))
        case .issue:
            updated.status = .unresolved
            var note = "Re-check still shows the issue."
            if let record, record.status != .succeeded { note += " The remediation \(record.status.rawValue.lowercased())." }
            updated.statusNote = note + " " + (fresh.statusNote ?? "")
            updated = Finding(id: updated.id, checkID: updated.checkID, title: updated.title, severity: updated.severity,
                              confidence: updated.confidence, component: updated.component, evidence: updated.evidence,
                              collectedAt: updated.collectedAt, whyItMatters: updated.whyItMatters, limitations: updated.limitations,
                              remediation: check.remediation, verificationSteps: updated.verificationSteps,
                              status: .unresolved, statusNote: updated.statusNote)
            await auditLog.record(AuditEvent(kind: .remediationUnresolved, operation: "audit.\(check.id)", outcome: "UNRESOLVED",
                                             detail: updated.statusNote ?? ""))
        default:
            updated.statusNote = "Verification could not determine the current state: " + (fresh.statusNote ?? "unknown")
            await auditLog.record(AuditEvent(kind: .remediationUnresolved, operation: "audit.\(check.id)", outcome: "UNVERIFIED",
                                             detail: updated.statusNote ?? ""))
        }
        return updated
    }
}
