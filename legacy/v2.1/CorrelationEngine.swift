import Foundation
import Combine

/// Represents a graph of interconnected security assets based on observations
class SecurityGraph: ObservableObject {
    @Published var assets: [UUID: SecurityAsset] = [:]
    @Published var relationships: [SecurityRelationship] = []
    
    // Fast lookup sets to avoid O(N^2) complexity during bulk inserts
    private var knownRelationshipIds = Set<UUID>()
    private var knownRelationshipSignatures = Set<String>()
    
    /// Adds or merges an asset into the graph
    func addOrUpdate(asset: SecurityAsset) {
        if let existing = assets[asset.id] {
            var updated = existing
            for (key, value) in asset.properties {
                updated.properties[key] = value
            }
            assets[asset.id] = updated
        } else {
            assets[asset.id] = asset
        }
    }
    
    /// Adds a relationship between two assets
    func add(relationship: SecurityRelationship) {
        // Create a unique signature based on the composite key
        let signature = "\(relationship.sourceId.uuidString)-\(relationship.targetId.uuidString)-\(relationship.type.rawValue)"
        
        // O(1) checks using Sets instead of O(N) array iteration
        if !knownRelationshipIds.contains(relationship.id) && !knownRelationshipSignatures.contains(signature) {
            knownRelationshipIds.insert(relationship.id)
            knownRelationshipSignatures.insert(signature)
            relationships.append(relationship)
        }
    }
    
    func clear() {
        assets.removeAll()
        relationships.removeAll()
        knownRelationshipIds.removeAll()
        knownRelationshipSignatures.removeAll()
    }
}

/// Consumes observations and builds the security graph and derived findings
class CorrelationEngine: ObservableObject {
    @Published var graph = SecurityGraph()
    @Published var derivedFindings: [SecurityFinding] = []
    @Published var rawObservations: [SecurityObservation] = []
    
    /// Process a batch of new observations
    func process(observations: [SecurityObservation]) async {
        for obs in observations {
            await MainActor.run {
                self.rawObservations.append(obs)
                
                // Add all assets to the graph
                for asset in obs.relatedAssets {
                    self.graph.addOrUpdate(asset: asset)
                }
                
                // Add all relationships to the graph
                for rel in obs.relationships {
                    self.graph.add(relationship: rel)
                }
                
                self.correlateFindings(from: obs)
            }
        }
    }
    
    private func correlateFindings(from observation: SecurityObservation) {
        // Detect pattern: multiple vulnerabilities on the same host
        let hostAssets = observation.relatedAssets.filter { $0.type == .host }
        let vulnAssets = observation.relatedAssets.filter { $0.type == .vulnerability }
        
        for host in hostAssets {
            // Count how many existing vulnerabilities are linked to this host
            let existingVulns = graph.relationships.filter {
                $0.sourceId == host.id && $0.type == .vulnerableTo
            }
            
            // If 3+ vulnerabilities on one host, generate a compound finding
            if existingVulns.count + vulnAssets.count >= 3 {
                let finding = SecurityFinding(
                    title: "Multiple Vulnerabilities on \(host.name)",
                    category: "CORRELATION",
                    severity: .high,
                    evidence: ["\(existingVulns.count + vulnAssets.count) vulnerabilities detected on a single host."],
                    explanation: "This host has accumulated multiple security issues, indicating systemic hardening deficiencies.",
                    impact: "Combined vulnerabilities significantly increase attack surface.",
                    remediation: "Prioritize remediation of all findings for this host.",
                    verification: "Re-run audit after applying fixes.",
                    confidence: "HIGH"
                )
                // Only add if we haven't already generated one for this host
                if !derivedFindings.contains(where: { $0.title == finding.title }) {
                    derivedFindings.append(finding)
                }
            }
        }
    }
}
