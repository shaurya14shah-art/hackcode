import Foundation

class MacSecurityAdapter: SecurityAdapter {
    let identifier = "mac_os_auditor"
    let name = "Mac OS Security Auditor"
    let description = "Checks local macOS security configurations like SIP, Gatekeeper, Firewall, and FileVault."
    let category = "Local Security"
    
    func validate(scope: SecurityScope) async throws {
        if scope.targetType != .localMac {
            throw NSError(domain: "MacSecurityAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid scope type for Mac OS Security Auditor"])
        }
    }
    
    func execute(scope: SecurityScope) async throws -> [SecurityObservation] {
        var observations: [SecurityObservation] = []
        
        // SIP Check
        let sipResult = CommandExecutor.execute(executable: "csrutil", arguments: ["status"])
        let sipAsset = SecurityAsset(name: "System Integrity Protection", type: .fileSystem, properties: ["output": sipResult.stdout])
        observations.append(SecurityObservation(
            toolId: identifier,
            description: "SIP Status: \(sipResult.stdout.isEmpty ? "Unknown" : sipResult.stdout)",
            relatedAssets: [sipAsset]
        ))
        
        // Gatekeeper Check
        let gatekeeperResult = CommandExecutor.execute(executable: "spctl", arguments: ["--status"])
        let gatekeeperAsset = SecurityAsset(name: "Gatekeeper", type: .fileSystem, properties: ["output": gatekeeperResult.stdout])
        observations.append(SecurityObservation(
            toolId: identifier,
            description: "Gatekeeper Status: \(gatekeeperResult.stdout.isEmpty ? "Unknown" : gatekeeperResult.stdout)",
            relatedAssets: [gatekeeperAsset]
        ))
        
        // Firewall Check
        let firewallResult = CommandExecutor.execute(executable: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"])
        let firewallAsset = SecurityAsset(name: "Application Firewall", type: .service, properties: ["output": firewallResult.stdout])
        observations.append(SecurityObservation(
            toolId: identifier,
            description: "Firewall Status: \(firewallResult.stdout.isEmpty ? "Unknown" : firewallResult.stdout)",
            relatedAssets: [firewallAsset]
        ))
        
        // FileVault Check
        let fdesetupResult = CommandExecutor.execute(executable: "fdesetup", arguments: ["status"])
        let fileVaultAsset = SecurityAsset(name: "FileVault Encryption", type: .fileSystem, properties: ["output": fdesetupResult.stdout])
        observations.append(SecurityObservation(
            toolId: identifier,
            description: "FileVault Status: \(fdesetupResult.stdout.isEmpty ? "Unknown" : fdesetupResult.stdout)",
            relatedAssets: [fileVaultAsset]
        ))
        
        return observations
    }
}
