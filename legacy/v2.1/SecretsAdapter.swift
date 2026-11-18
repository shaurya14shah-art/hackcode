import Foundation

class SecretsAdapter: SecurityAdapter {
    let identifier = "secrets_scanner"
    let name = "Secrets Scanner"
    let description = "Scans local files for exposed secrets (API keys, private keys)."
    let category = "Code Audit"
    
    func validate(scope: SecurityScope) async throws {
        if scope.targetType != .directory && scope.targetType != .file {
            throw NSError(domain: "SecretsAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid scope. Secrets scanner requires a directory or file scope."])
        }
    }
    
    func execute(scope: SecurityScope) async throws -> [SecurityObservation] {
        var observations: [SecurityObservation] = []
        let path = scope.target
        
        // Prevent flag injection: path must not start with a hyphen
        guard !path.hasPrefix("-") else {
            return [SecurityObservation(
                toolId: identifier,
                description: "Invalid path: '\(path)' — rejected (flag injection prevention)."
            )]
        }
        
        // Search for API_KEY=
        let apiRegex = "API_KEY=[A-Za-z0-9]+"
        let grepApiResult = CommandExecutor.execute(executable: "grep", arguments: ["-rHEo", apiRegex, "--", path])
        if grepApiResult.success && !grepApiResult.stdout.isEmpty {
            let lines = grepApiResult.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for line in lines {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let file = parts[0]
                    let match = parts[1...].joined(separator: ":")
                    let redactedMatch = redact(secret: match, prefix: "API_KEY=")
                    let asset = SecurityAsset(name: URL(fileURLWithPath: file).lastPathComponent, type: .fileSystem, properties: ["match": redactedMatch, "path": file])
                    observations.append(SecurityObservation(
                        toolId: identifier,
                        description: "Found potential API Key in \(file): \(redactedMatch)",
                        relatedAssets: [asset]
                    ))
                }
            }
        }
        
        // Search for Private Keys
        let privateKeyRegex = "-----BEGIN PRIVATE KEY-----"
        let grepPkResult = CommandExecutor.execute(executable: "grep", arguments: ["-rhl", privateKeyRegex, "--", path])
        if grepPkResult.success && !grepPkResult.stdout.isEmpty {
            let files = grepPkResult.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for file in files {
                let asset = SecurityAsset(name: URL(fileURLWithPath: file).lastPathComponent, type: .fileSystem, properties: ["type": "Private Key", "path": file])
                observations.append(SecurityObservation(
                    toolId: identifier,
                    description: "Found potential Private Key file: \(file)",
                    relatedAssets: [asset]
                ))
            }
        }
        
        if observations.isEmpty {
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "No secrets found in \(path)."
            ))
        }
        
        return observations
    }
    
    private func redact(secret: String, prefix: String) -> String {
        guard secret.hasPrefix(prefix) else { return secret }
        let value = String(secret.dropFirst(prefix.count))
        let visibleCount = min(4, value.count)
        let visiblePart = String(value.prefix(visibleCount))
        return "\(prefix)\(visiblePart)****"
    }
}
