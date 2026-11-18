import Foundation

class RiskEngine {
    
    public init() {}
    
    /// Calculates the overall security posture score (0-100) based on findings.
    /// - Parameter findings: An array of `SecurityFinding` objects.
    /// - Returns: An integer representing the posture score, bounded between 0 and 100.
    func calculatePostureScore(findings: [SecurityFinding]) -> Int {
        var penalty: Double = 0.0
        
        for finding in findings {
            if finding.remediationStatus == .resolved {
                continue
            }
            
            let severityWeight: Double
            switch finding.severity {
            case .critical: severityWeight = 25.0
            case .high:     severityWeight = 15.0
            case .medium:   severityWeight = 5.0
            case .low:      severityWeight = 2.0
            case .info:     severityWeight = 0.0
            }
            
            let confidenceFactor: Double
            switch finding.confidence.uppercased() {
            case "HIGH":   confidenceFactor = 1.0
            case "MEDIUM": confidenceFactor = 0.75
            case "LOW":    confidenceFactor = 0.5
            default:       confidenceFactor = 1.0
            }
            
            penalty += (severityWeight * confidenceFactor)
        }
        
        let score = 100.0 - penalty
        return max(0, min(100, Int(round(score))))
    }
}
