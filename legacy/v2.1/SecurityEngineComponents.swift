import Foundation

// MARK: - Security Check Registry
class SecurityCheckRegistry {
    func getAllChecks() -> [SecurityCheck] {
        return [
            FirewallCheck(),
            SIPCheck(),
            GatekeeperCheck(),
            FileVaultCheck(),
            SSHCheck(),
            SharingCheck(),
            AutoUpdateCheck(),
            ScreenLockCheck()
        ]
    }
    
    func getCheck(id: String) -> SecurityCheck? {
        return getAllChecks().first { $0.id == id }
    }
}

// MARK: - Concrete Checks
struct FirewallCheck: SecurityCheck {
    let id = "mac-firewall"
    let name = "Application Firewall"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = "/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct SIPCheck: SecurityCheck {
    let id = "mac-sip"
    let name = "System Integrity Protection (SIP)"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = nil // Requires Recovery OS
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "csrutil", arguments: ["status"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct GatekeeperCheck: SecurityCheck {
    let id = "mac-gatekeeper"
    let name = "Gatekeeper"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = "spctl --master-enable"
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "spctl", arguments: ["--status"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct FileVaultCheck: SecurityCheck {
    let id = "mac-filevault"
    let name = "FileVault Encryption"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = "fdesetup enable"
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "fdesetup", arguments: ["status"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct SSHCheck: SecurityCheck {
    let id = "mac-ssh"
    let name = "SSH Remote Login"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = "systemsetup -setremotelogin off"
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "/usr/sbin/systemsetup", arguments: ["-getremotelogin"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct SharingCheck: SecurityCheck {
    let id = "mac-sharing"
    let name = "Sharing Services"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = nil
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "/bin/sh", arguments: ["-c", "sharing -l 2>/dev/null || echo 'No sharing services query tool available'"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct AutoUpdateCheck: SecurityCheck {
    let id = "mac-autoupdate"
    let name = "Automatic Updates"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = "defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true"
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "defaults", arguments: ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

struct ScreenLockCheck: SecurityCheck {
    let id = "mac-screenlock"
    let name = "Screen Lock"
    let category = "SYSTEM HARDENING"
    let remediationCommand: String? = nil
    
    func execute() async -> CheckResult {
        let result = CommandExecutor.execute(executable: "/bin/sh", arguments: ["-c", "sysadminctl -screenLock status 2>&1 || echo 'Unable to check screen lock'"])
        return result.success ? .success(evidence: result.stdout) : .failure(error: result.displayOutput)
    }
}

// MARK: - Evidence Collector
class EvidenceCollector {
    func collectEvidence(for check: SecurityCheck) async -> String {
        let result = await check.execute()
        switch result {
        case .success(let evidence):
            return sanitize(evidence)
        case .failure(let error):
            return "Failed to collect evidence: \(error)"
        }
    }
    
    private func sanitize(_ evidence: String) -> String {
        // Redact potential sensitive tokens/paths
        // For a real security product, we'd use regex to strip paths, keys, etc.
        var sanitized = evidence
        let username = NSUserName()
        if !username.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: username, with: "[USER]")
        }
        return sanitized
    }
}

// MARK: - Finding Analyzer
class FindingAnalyzer {
    private var llmService: LLMService?
    
    func attach(llmService: LLMService) {
        self.llmService = llmService
    }
    
    func analyze(check: SecurityCheck, evidence: String) async throws -> SecurityFinding {
        // Try LLM first
        if let llm = llmService {
            do {
                return try await withThrowingTaskGroup(of: SecurityFinding.self) { group in
                    group.addTask {
                        return try await llm.analyzeSecurityEvidence(
                            checkName: check.name,
                            checkCategory: check.category,
                            evidence: evidence
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000) // 15s timeout
                        throw CancellationError()
                    }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return result
                }
            } catch {
                // Fall through to offline analysis
            }
        }
        
        // Offline fallback: basic pattern matching
        return analyzeOffline(check: check, evidence: evidence)
    }
    
    private func analyzeOffline(check: SecurityCheck, evidence: String) -> SecurityFinding {
        let lowerEvidence = evidence.lowercased()
        var severity: SecuritySeverity = .info
        var explanation = "Offline analysis: "
        var remediation = "N/A"
        
        // Pattern match common outputs
        if lowerEvidence.contains("enabled") || lowerEvidence.contains("on") {
            severity = .info
            explanation += "\(check.name) appears to be enabled based on system output."
        } else if lowerEvidence.contains("disabled") || lowerEvidence.contains("off") {
            severity = .high
            explanation += "\(check.name) appears to be DISABLED. This is a security risk."
            remediation = check.remediationCommand ?? "Enable this security feature manually."
        } else if lowerEvidence.contains("failed") || lowerEvidence.contains("error") {
            severity = .medium
            explanation += "Unable to determine \(check.name) status. The check returned an error."
        } else {
            severity = .low
            explanation += "\(check.name) returned output that requires manual review."
        }
        
        return SecurityFinding(
            title: check.name,
            category: check.category,
            severity: severity,
            evidence: [evidence],
            explanation: explanation,
            impact: severity == .high ? "System may be vulnerable." : "Low or unknown impact.",
            remediation: remediation,
            verification: "Re-run the audit after applying fixes.",
            confidence: "MEDIUM"
        )
    }
}

// MARK: - Remediation Engine
class RemediationEngine {
    func applyFix(for finding: SecurityFinding, check: SecurityCheck) async -> Bool {
        guard let cmd = check.remediationCommand else { return false }
        
        let components = cmd.split(separator: " ").map(String.init)
        guard let executable = components.first else { return false }
        let args = Array(components.dropFirst())
        
        // Pass through the standard CommandExecutor to ensure it follows the rules
        let result = CommandExecutor.execute(executable: executable, arguments: args)
        return result.success
    }
}

// MARK: - Verification Engine
/// Placeholder for post-remediation verification. Currently integrated directly
/// into SecurityEngine.remediateFinding(). Expand when verification requires
/// different commands than the original check.
class VerificationEngine {
    func verify(check: SecurityCheck, expectedStatus: String) async -> Bool {
        // Re-run the check and compare output to expected status
        let result = await check.execute()
        switch result {
        case .success(let evidence):
            return evidence.lowercased().contains(expectedStatus.lowercased())
        case .failure:
            return false
        }
    }
}

// MARK: - Security Report Generator
class SecurityReportGenerator {
    func generate(session: SecurityAuditSession) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        
        var report = """
        ====================================================
        HACKCODE SECURITY AUDIT REPORT
        ====================================================
        TARGET: \(session.target)
        DATE: \(df.string(from: session.timestamp))
        CHECKS PERFORMED: \(session.checksPerformed)
        SECURITY POSTURE SCORE: \(session.overallScore) / 100
        ====================================================
        
        """
        
        for finding in session.findings {
            report += """
            
            [\(finding.severity.rawValue)] \(finding.title)
            STATUS: \(finding.remediationStatus.rawValue)
            CATEGORY: \(finding.category)
            CONFIDENCE: \(finding.confidence)
            EVIDENCE:
            \(finding.evidence.joined(separator: "\n"))
            EXPLANATION:
            \(finding.explanation)
            IMPACT:
            \(finding.impact)
            REMEDIATION:
            \(finding.remediation)
            ----------------------------------------------------
            """
        }
        
        return report
    }
}
