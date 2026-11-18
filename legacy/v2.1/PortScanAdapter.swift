import Foundation

class PortScanAdapter: SecurityAdapter {
    let identifier = "port_scanner"
    let name = "Local Port Auditor"
    let description = "Checks target host for exposed local TCP listening services."
    let category = "Network"
    
    private let commonPorts = [21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 548, 993, 995, 3306, 3389, 5432, 5900, 8080, 8443, 9090]
    
    private let serviceNames: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS",
        80: "HTTP", 110: "POP3", 143: "IMAP", 443: "HTTPS", 445: "SMB",
        548: "AFP", 993: "IMAPS", 995: "POP3S", 3306: "MySQL",
        3389: "RDP", 5432: "PostgreSQL", 5900: "VNC", 8080: "HTTP-ALT",
        8443: "HTTPS-ALT", 9090: "Prometheus"
    ]
    
    func validate(scope: SecurityScope) async throws {
        if scope.targetType != .ipAddress && scope.targetType != .domain && scope.targetType != .localMac {
            throw NSError(domain: "PortScanAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Port scan requires an IP address, domain, or localMac target."])
        }
        // Prevent flag injection
        guard !scope.target.hasPrefix("-") else {
            throw NSError(domain: "PortScanAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid target: flag injection rejected."])
        }
    }
    
    func execute(scope: SecurityScope) async throws -> [SecurityObservation] {
        var observations: [SecurityObservation] = []
        let target = scope.targetType == .localMac ? "127.0.0.1" : scope.target
        let hostAsset = SecurityAsset(name: target, type: .host)
        
        for port in commonPorts {
            let result = CommandExecutor.execute(executable: "/usr/bin/nc", arguments: ["-z", "-w", "1", "-G", "1", "--", target, String(port)])
            
            if result.exitCode == 0 {
                let serviceName = serviceNames[port] ?? "Unknown"
                let portAsset = SecurityAsset(
                    name: "\(target):\(port)",
                    type: .openPort,
                    properties: ["port": String(port), "service": serviceName, "state": "OPEN"]
                )
                let rel = SecurityRelationship(sourceId: hostAsset.id, targetId: portAsset.id, type: .exposes)
                observations.append(SecurityObservation(
                    toolId: identifier,
                    description: "Open port \(port)/\(serviceName) on \(target)",
                    relatedAssets: [hostAsset, portAsset],
                    relationships: [rel]
                ))
            }
        }
        
        if observations.isEmpty {
            observations.append(SecurityObservation(
                toolId: identifier,
                description: "No exposed services found on \(target) (checked \(commonPorts.count) standard service ports)."
            ))
        }
        
        return observations
    }
}
