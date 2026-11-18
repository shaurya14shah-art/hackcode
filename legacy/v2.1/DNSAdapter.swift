import Foundation

class DNSAdapter: SecurityAdapter {
    let identifier = "dns_enumerator"
    let name = "DNS Enumeration"
    let description = "Performs DNS queries (A, MX, TXT) to discover domain infrastructure."
    let category = "OSINT"
    
    func validate(scope: SecurityScope) async throws {
        if scope.targetType != .domain {
            throw NSError(domain: "DNSAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid scope. DNS enumeration requires a domain scope."])
        }
    }
    
    func execute(scope: SecurityScope) async throws -> [SecurityObservation] {
        var observations: [SecurityObservation] = []
        let domain = scope.target
        
        // Prevent flag injection: domain must not start with a hyphen
        guard !domain.hasPrefix("-") else {
            return [SecurityObservation(
                toolId: identifier,
                description: "Invalid domain: '\(domain)' — rejected (flag injection prevention)."
            )]
        }
        
        // A Records
        let aResult = CommandExecutor.execute(executable: "dig", arguments: ["+short", "A", "--", domain])
        if !aResult.stdout.isEmpty {
            let aAsset = SecurityAsset(name: "A Records for \(domain)", type: .ip, properties: ["records": aResult.stdout])
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "Found A records for \(domain)",
                relatedAssets: [aAsset]
            ))
        }
        
        // MX Records
        let mxResult = CommandExecutor.execute(executable: "dig", arguments: ["+short", "MX", "--", domain])
        if !mxResult.stdout.isEmpty {
            let mxAsset = SecurityAsset(name: "MX Records for \(domain)", type: .domain, properties: ["records": mxResult.stdout])
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "Found MX records for \(domain)",
                relatedAssets: [mxAsset]
            ))
        }
        
        // TXT Records
        let txtResult = CommandExecutor.execute(executable: "dig", arguments: ["+short", "TXT", "--", domain])
        if !txtResult.stdout.isEmpty {
            let txtAsset = SecurityAsset(name: "TXT Records for \(domain)", type: .domain, properties: ["records": txtResult.stdout])
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "Found TXT records for \(domain)",
                relatedAssets: [txtAsset]
            ))
        }
        
        if observations.isEmpty {
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "No DNS records found for \(domain)."
            ))
        }
        
        return observations
    }
}
