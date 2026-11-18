import SwiftUI
import Observation
import HackCodeKit

@MainActor
@Observable
final class SecurityAuditViewModel {
    enum Filter: String, CaseIterable { case all = "ALL", issues = "ISSUES", passed = "PASSED", failed = "COULD NOT RUN" }
    enum Pane: String, CaseIterable { case findings = "FINDINGS", history = "HISTORY", log = "AUDIT LOG" }

    struct RemediationPreview: Identifiable {
        let id = UUID()
        let finding: Finding
        let remediation: Remediation
        let operation: ValidatedOperation?
        let validationError: String?
    }

    private(set) var findings: [Finding] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var cancelled = false
    var selectedID: String?
    var filter: Filter = .all
    var pane: Pane = .findings
    var preview: RemediationPreview?
    private(set) var remediating: Set<String> = []
    private(set) var rechecking: Set<String> = []
    private(set) var remediationResults: [String: ExecutionRecord] = [:]
    private(set) var explanations: [String: String] = [:]
    private(set) var explaining: Set<String> = []
    private(set) var explainErrors: [String: String] = [:]
    private(set) var logEvents: [AuditEvent] = []
    private(set) var changes: [PostureChange] = []
    private(set) var scoreHistory: [(date: Date, score: Int)] = []
    /// Every recorded run summary, oldest first (HISTORY pane).
    private(set) var historyRuns: [AuditSummary] = []
    private(set) var lastTrigger: Trigger = .manual

    enum Trigger: String { case manual = "manual", scheduled = "scheduled" }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var auditTask: Task<Void, Never>?

    func attach(_ app: AppModel) { self.app = app }

    var score: Int? {
        AuditRun(startedAt: startedAt ?? Date(), findings: findings, cancelled: cancelled).score
    }

    var visibleFindings: [Finding] {
        let base: [Finding]
        switch filter {
        case .all: base = findings
        case .issues: base = findings.filter(\.isActionable)
        case .passed: base = findings.filter { $0.status == .pass || $0.status == .remediated || $0.status == .observed }
        case .failed: base = findings.filter { $0.status == .couldNotRun }
        }
        return base.sorted { a, b in
            if a.isActionable != b.isActionable { return a.isActionable }
            if a.severity != b.severity { return a.severity > b.severity }
            return a.title < b.title
        }
    }

    var selected: Finding? { findings.first { $0.id == selectedID } }

    /// Every finding, issues first — used for exports so the current list filter never hides results.
    var allFindingsSorted: [Finding] {
        findings.sorted { a, b in
            if a.isActionable != b.isActionable { return a.isActionable }
            if a.severity != b.severity { return a.severity > b.severity }
            return a.title < b.title
        }
    }

    // MARK: Audit

    func runAudit(trigger: Trigger = .manual) {
        guard let app, !isRunning else { return }
        lastTrigger = trigger
        isRunning = true
        cancelled = false
        findings = []
        completed = 0
        total = app.auditService.registry.checks.count
        startedAt = Date()
        finishedAt = nil
        auditTask = Task {
            let run = await app.auditService.runAudit { finding in
                await MainActor.run {
                    self.findings.append(finding)
                    self.completed += 1
                    if self.selectedID == nil && finding.isActionable { self.selectedID = finding.id }
                }
            }
            self.findings = run.findings
            self.cancelled = run.cancelled
            self.finishedAt = Date()
            self.isRunning = false
            if !run.cancelled {
                var finished = run
                finished.finishedAt = Date()
                let diff = await app.historyStore.record(AuditSummary(run: finished))
                self.changes = diff
                for c in diff {
                    await app.auditLog.record(AuditEvent(kind: .postureChanged, operation: "audit.\(c.checkID)", outcome: "\(c.from)→\(c.to)", detail: c.title))
                }
                let regressions = diff.filter(\.isRegression)
                if !regressions.isEmpty {
                    app.notify("HackCode · security posture changed", regressions.map { "\($0.title): \($0.from) → \($0.to)" }.joined(separator: "; "))
                } else if trigger == .scheduled {
                    app.notify("HackCode · scheduled audit complete", "Score \(run.score.map(String.init) ?? "n/a"), \(run.issues.count) issue(s), no regressions.")
                }
                await self.loadHistory()
            }
            if self.selectedID == nil { self.selectedID = self.visibleFindings.first?.id }
            await self.loadLog()
        }
    }

    func cancelAudit() { auditTask?.cancel() }

    // MARK: AI briefing (titles / statuses / severities only)

    private(set) var briefing = ""
    private(set) var isBriefing = false
    private(set) var briefingError: String?
    var showBriefing = false

    func generateBriefing() {
        guard let app, !isBriefing, !findings.isEmpty else { return }
        isBriefing = true
        showBriefing = true
        briefing = ""
        briefingError = nil
        let stream = OrderedTextStream { [weak self] in self?.briefing += $0 }
        let snapshot = allFindingsSorted
        Task {
            do {
                _ = try await app.llm.securityBriefing(findings: snapshot, onDelta: stream.onDelta)
            } catch {
                briefingError = error.localizedDescription
            }
            await stream.finish()
            isBriefing = false
        }
    }

    func loadHistory() async {
        guard let app else { return }
        historyRuns = await app.historyStore.all().sorted { $0.date < $1.date }
        scoreHistory = historyRuns.compactMap { s in s.score.map { (s.date, $0) } }
    }

    func clearHistory() {
        guard let app else { return }
        Task {
            await app.historyStore.clear()
            changes = []
            await loadHistory()
        }
    }

    func moveSelection(_ delta: Int) {
        let list = visibleFindings
        guard !list.isEmpty else { return }
        let index = selectedID.flatMap { id in list.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : list.count)
        selectedID = list[min(max(index + delta, 0), list.count - 1)].id
    }

    func markdownReport() -> String {
        var s = "# HackCode Security Audit\n\n"
        s += "- Date: \(startedAt?.formatted() ?? "—")\n- Posture score: \(score.map { "\($0)/100" } ?? "n/a")\n- Checks: \(findings.count) · issues: \(findings.filter(\.isActionable).count) · could not run: \(findings.filter { $0.status == .couldNotRun }.count)\n"
        s += "- Scope: local, read-only checks on this Mac. Checks that could not run are excluded from the score.\n\n"
        if !changes.isEmpty {
            s += "## Changes since previous audit\n\n" + changes.map { "- **\($0.title)**: \($0.from) → \($0.to)" }.joined(separator: "\n") + "\n\n"
        }
        s += "## Findings\n\n| Status | Severity | Confidence | Check | Result |\n|---|---|---|---|---|\n"
        for f in allFindingsSorted {
            s += "| \(f.status.rawValue) | \(f.severity.label) | \(f.confidence.rawValue) | \(f.title) | \((f.statusNote ?? "").replacingOccurrences(of: "|", with: "/")) |\n"
        }
        for f in allFindingsSorted where f.isActionable {
            s += "\n### \(f.title)\n\n\(f.whyItMatters)\n\n**Evidence**\n\n"
            for e in f.evidence { s += "`\(e.source)`\n\n```\n\(e.output)\n```\n\n" }
            if let r = f.remediation { s += "**Remediation:** \(r.summary)  \n**Exact change:** `\(r.exactChange)`\n" }
        }
        return Redactor().redact(s)
    }

    func recheck(_ finding: Finding) {
        guard let app, !rechecking.contains(finding.id) else { return }
        rechecking.insert(finding.id)
        Task {
            let updated: Finding
            if finding.status == .issue || finding.status == .unresolved || finding.status == .remediated {
                updated = await app.auditService.verify(finding, afterExecution: nil)
            } else {
                updated = await app.auditService.runCheck(id: finding.checkID) ?? finding
            }
            replace(updated)
            rechecking.remove(finding.id)
            await loadLog()
        }
    }

    private func replace(_ f: Finding) {
        if let i = findings.firstIndex(where: { $0.id == f.id }) { findings[i] = f } else { findings.append(f) }
    }

    // MARK: Remediation: preview → authorize → apply → verify

    func previewRemediation(_ finding: Finding) {
        guard let app, let remediation = finding.remediation else { return }
        var op: ValidatedOperation?
        var validationError: String?
        if let id = remediation.operationID {
            do {
                op = try app.policy.validate(OperationRequest(operationID: id, provenance: .securityAudit, rationale: "Remediate: \(finding.title)"))
            } catch {
                validationError = error.localizedDescription
            }
        }
        preview = RemediationPreview(finding: finding, remediation: remediation, operation: op, validationError: validationError)
        Task { await app.auditLog.record(AuditEvent(kind: .approvalRequested, operation: remediation.operationID ?? "manual.\(finding.checkID)",
                                                    risk: op?.risk.tier, provenance: .securityAudit, outcome: "previewed")) }
    }

    func dismissPreview(approved: Bool) {
        guard let p = preview else { return }
        preview = nil
        guard let app else { return }
        if !approved {
            Task { await app.auditLog.record(AuditEvent(kind: .approvalDenied, operation: p.remediation.operationID ?? "manual", provenance: .securityAudit, outcome: "dismissed")) }
            return
        }
        guard let op = p.operation else { return }
        let approval = ApprovalGate.approve(op)
        remediating.insert(p.finding.id)
        Task {
            await app.auditLog.record(AuditEvent(kind: .approvalGranted, operation: op.spec.id, risk: op.risk.tier, provenance: .securityAudit, outcome: "granted"))
            let record = await app.executor.execute(op, approval: approval)
            remediationResults[p.finding.id] = record
            // Always re-inspect: a failure or timeout is not proof that nothing changed.
            let verified = await app.auditService.verify(p.finding, afterExecution: record)
            replace(verified)
            remediating.remove(p.finding.id)
            await loadLog()
        }
    }

    func openSystemSettings(_ urlString: String) {
        guard urlString.hasPrefix("x-apple.systempreferences:"), let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: AI explanation of a finding

    func explain(_ finding: Finding) {
        guard let app, !explaining.contains(finding.id) else { return }
        explaining.insert(finding.id)
        explanations[finding.id] = ""
        explainErrors[finding.id] = nil
        let stream = OrderedTextStream { [weak self] in self?.explanations[finding.id, default: ""] += $0 }
        Task {
            do {
                _ = try await app.llm.explainFinding(finding, onDelta: stream.onDelta)
            } catch {
                explainErrors[finding.id] = error.localizedDescription
            }
            await stream.finish()
            explaining.remove(finding.id)
        }
    }

    // MARK: Log & report

    enum LogSource: String, CaseIterable { case session = "SESSION", disk = "ON DISK" }
    var logSource: LogSource = .session { didSet { Task { await loadLog() } } }
    var logFilter = AuditLogFilter()

    /// Newest first, after the category/window/text filter.
    var filteredLog: [AuditEvent] { logFilter.apply(logEvents) }
    var logCounts: [AuditLogFilter.Category: Int] { logFilter.counts(logEvents) }

    func loadLog() async {
        guard let app else { return }
        switch logSource {
        case .session: logEvents = await app.auditLog.recent(limit: 500).reversed()
        case .disk: logEvents = await app.auditLog.history(limit: 5000).reversed()
        }
    }

    func exportLogCSV() {
        // Export what is on screen (filtered), oldest first like the file itself.
        _ = saveTextFile(AuditLogFilter.csv(filteredLog.reversed()), suggestedName: "hackcode-audit-log-\(timestampForFile()).csv")
    }

    func clearLog() {
        guard let app else { return }
        Task {
            await app.auditLog.clear()
            await loadLog()
        }
    }

    func clearSession() {
        auditTask?.cancel()
        findings = []
        explanations = [:]
        remediationResults = [:]
        selectedID = nil
        startedAt = nil
        finishedAt = nil
    }

    func reportText() -> String {
        var s = "HackCode security audit — this Mac\n"
        s += "Run: \(startedAt?.formatted() ?? "—")  ·  score: \(score.map { "\($0)/100" } ?? "n/a")  ·  checks: \(findings.count)\n"
        s += "Scope: local, read-only checks. Checks that could not run are excluded from the score.\n\n"
        for f in allFindingsSorted {
            s += "[\(f.status.rawValue)] \(f.severity.label) (confidence \(f.confidence.rawValue)) — \(f.title)\n"
            if let note = f.statusNote { s += "  \(note)\n" }
            for e in f.evidence { s += "  evidence: \(e.source)\n    " + e.output.replacingOccurrences(of: "\n", with: "\n    ") + "\n" }
            if let r = f.remediation { s += "  remediation: \(r.summary) [\(r.exactChange)]\n" }
            s += "\n"
        }
        return Redactor().redact(s)
    }
}
