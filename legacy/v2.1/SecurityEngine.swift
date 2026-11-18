import Foundation
import Combine

class SecurityEngine: ObservableObject {
    @Published var session: SecurityAuditSession?
    @Published var isAuditing = false
    @Published var auditLog: [String] = []
    @Published var graph = SecurityGraph()
    
    private var llmService: LLMService?
    private let checkRegistry = SecurityCheckRegistry()
    private let evidenceCollector = EvidenceCollector()
    private let findingAnalyzer = FindingAnalyzer()
    private let remediationEngine = RemediationEngine()
    private let verificationEngine = VerificationEngine()
    private let reportGenerator = SecurityReportGenerator()
    private let riskEngine = RiskEngine()
    
    init() {}
    
    func attach(llmService: LLMService) {
        self.llmService = llmService
        self.findingAnalyzer.attach(llmService: llmService)
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.auditLog.append(message)
        }
    }
    
    func startAudit() async {
        await MainActor.run {
            self.isAuditing = true
            self.session = SecurityAuditSession()
            self.auditLog = ["[SECURITY AUDIT] Initializing... Target: THIS MAC"]
        }
        
        await performAuditChecks()
        
        await MainActor.run {
            self.isAuditing = false
        }
    }
    
    private func performAuditChecks() async {
        guard llmService != nil else {
            log("[ERROR] AI Security Analyst not connected. Cannot perform analysis.")
            return
        }
        
        let checks = checkRegistry.getAllChecks()
        log("[DISCOVER] Found \(checks.count) security checks to run.")
        
        for check in checks {
            // Safely read cancellation state
            let currentIsAuditing = await MainActor.run { self.isAuditing }
            guard currentIsAuditing else {
                log("[CANCELLED] Audit was cancelled by user.")
                return
            }
            
            log("[INSPECT] Executing check: \(check.name)")
            let evidence = await evidenceCollector.collectEvidence(for: check)
            
            log("[ANALYZE] Parsing evidence for \(check.name)")
            do {
                let finding = try await findingAnalyzer.analyze(check: check, evidence: evidence)
                
                await MainActor.run {
                    self.session?.findings.append(finding)
                    self.session?.checksPerformed += 1
                }
                log("[IDENTIFY] Finding recorded: [\(finding.severity.rawValue)] \(finding.title)")
            } catch {
                log("[ERROR] Failed to analyze \(check.name): \(error.localizedDescription)")
            }
        }
        
        log("[CORRELATE] Analyzing relationships between findings...")
        let correlationEngine = CorrelationEngine()
        
        // Safely extract MainActor states needed for correlation
        let currentGraph = await MainActor.run { self.graph }
        correlationEngine.graph = currentGraph
        
        let currentFindings = await MainActor.run { self.session?.findings }
        
        if let findings = currentFindings {
            var observations: [SecurityObservation] = []
            for finding in findings {
                let hostAsset = SecurityAsset(name: finding.target, type: .host)
                let vulnAsset = SecurityAsset(name: finding.title, type: .vulnerability, properties: ["severity": finding.severity.rawValue, "category": finding.category])
                let rel = SecurityRelationship(sourceId: hostAsset.id, targetId: vulnAsset.id, type: .vulnerableTo)
                let obs = SecurityObservation(toolId: "SecurityEngine", description: finding.explanation, relatedAssets: [hostAsset, vulnAsset], relationships: [rel])
                observations.append(obs)
            }
            await correlationEngine.process(observations: observations)
            
            let riskScore = riskEngine.calculatePostureScore(findings: findings)
            log("[RISK] Advanced Risk Assessment Score: \(riskScore)/100")
        }
        
        let finalScore = await MainActor.run { self.session?.overallScore ?? 100 }
        log("[REPORT] Audit complete. Posture Score: \(finalScore)/100")
    }
    
    @MainActor
    func cancelAudit() {
        self.isAuditing = false
        self.auditLog.append("[CANCEL] Audit cancelled.")
    }
    
    func remediateFinding(_ finding: SecurityFinding) async {
        guard let check = checkRegistry.getCheck(id: finding.id.uuidString) ?? checkRegistry.getAllChecks().first(where: { $0.name == finding.title }) else {
            log("[ERROR] Cannot find associated check for remediation.")
            return
        }
        
        log("[REMEDIATE] Attempting to fix: \(finding.title)")
        let success = await remediationEngine.applyFix(for: finding, check: check)
        
        if success {
            log("[REMEDIATE] Fix applied. Verifying...")
            let newEvidence = await evidenceCollector.collectEvidence(for: check)
            
            do {
                let verificationFinding = try await findingAnalyzer.analyze(check: check, evidence: newEvidence)
                
                await MainActor.run {
                    if let index = self.session?.findings.firstIndex(where: { $0.id == finding.id }) {
                        if verificationFinding.severity < finding.severity || verificationFinding.severity == .info {
                            self.session?.findings[index].remediationStatus = .resolved
                            log("[VERIFY] SUCCESS: Issue resolved.")
                        } else {
                            self.session?.findings[index].remediationStatus = .unchanged
                            log("[VERIFY] FAILED: Issue unchanged.")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if let index = self.session?.findings.firstIndex(where: { $0.id == finding.id }) {
                        self.session?.findings[index].remediationStatus = .unableToVerify
                        log("[VERIFY] ERROR: Unable to verify fix.")
                    }
                }
            }
        } else {
            log("[REMEDIATE] FAILED to apply fix for: \(finding.title)")
        }
    }
    
    func runSingleCheck(id: String) async {
        guard let check = checkRegistry.getCheck(id: id) else {
            log("[ERROR] Security check with ID '\(id)' not found.")
            return
        }
        await runCheck(check)
    }
    
    func runCheck(_ check: SecurityCheck) async {
        await MainActor.run {
            self.isAuditing = true
            if self.session == nil {
                self.session = SecurityAuditSession()
            }
        }
        
        log("[INSPECT] Executing focused audit: \(check.name)")
        let evidence = await evidenceCollector.collectEvidence(for: check)
        
        do {
            let finding = try await findingAnalyzer.analyze(check: check, evidence: evidence)
            await MainActor.run {
                if let idx = self.session?.findings.firstIndex(where: { $0.title == finding.title }) {
                    self.session?.findings[idx] = finding
                } else {
                    self.session?.findings.append(finding)
                    self.session?.checksPerformed += 1
                }
            }
            log("[IDENTIFY] Result: [\(finding.severity.rawValue)] \(finding.title)")
            log("[EVIDENCE] \(evidence.trimmingCharacters(in: .whitespacesAndNewlines))")
            if !finding.remediation.isEmpty {
                log("[REMEDIATION] \(finding.remediation)")
            }
        } catch {
            log("[INFO] Evidence collected: \(evidence)")
        }
        
        await MainActor.run {
            self.isAuditing = false
        }
    }
    
    func runSecretsAudit() async {
        await MainActor.run {
            self.isAuditing = true
            if self.session == nil { self.session = SecurityAuditSession() }
        }
        log("[SECRETS] Initiating scan for exposed API keys and private certificates...")
        let adapter = SecretsAdapter()
        let scope = SecurityScope(id: UUID(), target: ".", targetType: .directory, authContext: nil)
        do {
            let observations = try await adapter.execute(scope: scope)
            if observations.isEmpty {
                log("[SECRETS] Clean: No leaked credentials or private keys detected in local directory.")
            } else {
                for obs in observations {
                    log("[ALERT] \(obs.description)")
                    let finding = SecurityFinding(
                        title: "Exposed Secret / Key Detected",
                        category: "SECRETS",
                        severity: .high,
                        target: "LOCAL DIRECTORY",
                        evidence: [obs.description],
                        explanation: obs.description,
                        impact: "Hardcoded secrets or private keys can be exploited by unauthorized actors.",
                        remediation: "Remove sensitive key material from source files and revoke exposed credentials.",
                        verification: "Re-run '/audit-secrets' to verify keys are eliminated.",
                        confidence: "HIGH"
                    )
                    await MainActor.run {
                        self.session?.findings.append(finding)
                        self.session?.checksPerformed += 1
                    }
                }
            }
        } catch {
            log("[ERROR] Secrets audit failed: \(error.localizedDescription)")
        }
        await MainActor.run { self.isAuditing = false }
    }
    
    func runPortAudit(target: String = "127.0.0.1") async {
        await MainActor.run {
            self.isAuditing = true
            if self.session == nil { self.session = SecurityAuditSession() }
        }
        log("[PORTS] Probing local listening TCP ports on \(target)...")
        let adapter = PortScanAdapter()
        let scope = SecurityScope(id: UUID(), target: target, targetType: .localMac, authContext: nil)
        do {
            let observations = try await adapter.execute(scope: scope)
            if observations.isEmpty {
                log("[PORTS] Secure: No exposed listening services found on monitored ports.")
            } else {
                for obs in observations {
                    log("[OPEN PORT] \(obs.description)")
                }
            }
        } catch {
            log("[ERROR] Port audit failed: \(error.localizedDescription)")
        }
        await MainActor.run { self.isAuditing = false }
    }
    
    func runDNSAudit(domain: String = "localhost") async {
        await MainActor.run {
            self.isAuditing = true
            if self.session == nil { self.session = SecurityAuditSession() }
        }
        log("[DNS] Querying DNS resolver records for '\(domain)'...")
        let adapter = DNSAdapter()
        let scope = SecurityScope(id: UUID(), target: domain, targetType: .domain, authContext: nil)
        do {
            let observations = try await adapter.execute(scope: scope)
            for obs in observations {
                log("[DNS RECORD] \(obs.description)")
            }
        } catch {
            log("[ERROR] DNS audit failed: \(error.localizedDescription)")
        }
        await MainActor.run { self.isAuditing = false }
    }
    
    func generateReport() -> String {
        guard let session = session else { return "No audit session available." }
        return reportGenerator.generate(session: session)
    }
}
