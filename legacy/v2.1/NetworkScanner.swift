import Foundation
import Combine

class NetworkScanner: ObservableObject {
    @Published var session = NetworkScanSession()
    @Published var scanLog: [String] = []
    
    // Well-known ports to scan on each device
    private let commonPorts = [22, 80, 443, 445, 548, 3389, 5900, 8080, 8443, 62078]
    
    // Known service names
    private let serviceNames: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS", 445: "SMB",
        548: "AFP", 3389: "RDP", 5900: "VNC", 8080: "HTTP-ALT",
        8443: "HTTPS-ALT", 62078: "iPhone-Sync", 53: "DNS",
        21: "FTP", 25: "SMTP", 110: "POP3", 143: "IMAP",
        3306: "MySQL", 5432: "PostgreSQL", 6379: "Redis",
        27017: "MongoDB", 9090: "Prometheus"
    ]
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.scanLog.append(message)
        }
    }
    
    // MARK: - Get Local Network Info
    
    func getLocalSubnet() -> String {
        let result = CommandExecutor.execute(executable: "ifconfig", arguments: ["en0"])
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") && !trimmed.contains("127.0.0.1") {
                let parts = trimmed.split(separator: " ")
                if let ipIndex = parts.firstIndex(of: "inet"), ipIndex + 1 < parts.count {
                    let ip = String(parts[ipIndex + 1])
                    // Derive /24 subnet
                    let octets = ip.split(separator: ".")
                    if octets.count == 4 {
                        return "\(octets[0]).\(octets[1]).\(octets[2])"
                    }
                }
            }
        }
        return "192.168.1"
    }
    
    func getLocalIP() -> String {
        let result = CommandExecutor.execute(executable: "ifconfig", arguments: ["en0"])
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") && !trimmed.contains("127.0.0.1") {
                let parts = trimmed.split(separator: " ")
                if let ipIndex = parts.firstIndex(of: "inet"), ipIndex + 1 < parts.count {
                    return String(parts[ipIndex + 1])
                }
            }
        }
        return "unknown"
    }
    
    func getGatewayIP() -> String {
        let result = CommandExecutor.execute(executable: "route", arguments: ["-n", "get", "default"])
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "unknown"
    }
    
    // MARK: - Full Network Scan
    
    func startScan() async {
        let subnet = getLocalSubnet()
        let localIP = getLocalIP()
        let gatewayIP = getGatewayIP()
        
        await MainActor.run {
            self.session = NetworkScanSession(subnet: subnet, isScanning: true, progress: 0.0, scanPhase: "INITIALIZING")
            self.scanLog = ["[NET.SCAN] Starting network scan on \(subnet).0/24"]
        }
        
        log("[DISCOVER] Local IP: \(localIP)")
        log("[DISCOVER] Gateway: \(gatewayIP)")
        
        // Phase 1: ARP table discovery
        await updatePhase("ARP DISCOVERY", progress: 0.1)
        let arpDevices = discoverViaARP()
        log("[ARP] Found \(arpDevices.count) devices in ARP table")
        
        // Phase 2: Ping sweep for additional hosts
        await updatePhase("PING SWEEP", progress: 0.2)
        let pingDevices = await pingSweep(subnet: subnet)
        log("[PING] Found \(pingDevices.count) responsive hosts")
        
        // Merge devices
        var allDevices: [String: NetworkDevice] = [:]
        for dev in arpDevices {
            allDevices[dev.ipAddress] = dev
        }
        for dev in pingDevices {
            if allDevices[dev.ipAddress] == nil {
                allDevices[dev.ipAddress] = dev
            }
        }
        
        // Mark gateway and localhost
        if var gw = allDevices[gatewayIP] {
            gw.isGateway = true
            gw.hostname = "Gateway"
            allDevices[gatewayIP] = gw
        } else {
            allDevices[gatewayIP] = NetworkDevice(ipAddress: gatewayIP, hostname: "Gateway", isGateway: true)
        }
        
        if var local = allDevices[localIP] {
            local.isLocalHost = true
            local.hostname = "This Mac"
            allDevices[localIP] = local
        } else {
            allDevices[localIP] = NetworkDevice(ipAddress: localIP, hostname: "This Mac", isLocalHost: true)
        }
        
        // Phase 3: Port scan each device
        await updatePhase("PORT SCANNING", progress: 0.4)
        let deviceIPs = Array(allDevices.keys).sorted()
        for (index, ip) in deviceIPs.enumerated() {
            guard await isStillScanning() else {
                log("[CANCEL] Scan cancelled.")
                return
            }
            
            let progress = 0.4 + (0.5 * Double(index) / max(1, Double(deviceIPs.count)))
            await updatePhase("SCANNING \(ip)", progress: progress)
            
            log("[PORT] Scanning \(ip) (\(commonPorts.count) ports)")
            let ports = scanPorts(ip: ip)
            
            if var dev = allDevices[ip] {
                dev.openPorts = ports.filter { $0.isOpen }
                allDevices[ip] = dev
                if !dev.openPorts.isEmpty {
                    let portSummary = dev.openPorts.map { "\($0.port)/\($0.service)" }.joined(separator: ", ")
                    log("[PORT] \(ip): \(portSummary)")
                }
            }
            
            // Update UI with current results
            let sorted = allDevices.values.sorted { $0.ipAddress < $1.ipAddress }
            await MainActor.run {
                self.session.devices = sorted
            }
        }
        
        // Phase 4: Hostname resolution
        await updatePhase("HOSTNAME RESOLUTION", progress: 0.9)
        for ip in deviceIPs {
            if var dev = allDevices[ip], dev.hostname == "unknown" {
                dev.hostname = resolveHostname(ip: ip)
                allDevices[ip] = dev
            }
        }
        
        // Final update
        let finalDevices = allDevices.values.sorted { $0.ipAddress < $1.ipAddress }
        await MainActor.run {
            self.session.devices = finalDevices
            self.session.isScanning = false
            self.session.progress = 1.0
            self.session.scanPhase = "COMPLETE"
        }
        
        let totalPorts = finalDevices.reduce(0) { $0 + $1.openPorts.count }
        log("[COMPLETE] Found \(finalDevices.count) devices, \(totalPorts) open ports")
    }
    
    func cancelScan() {
        DispatchQueue.main.async {
            self.session.isScanning = false
            self.session.scanPhase = "CANCELLED"
        }
        log("[CANCEL] Scan cancelled by user.")
    }
    
    // MARK: - Discovery Methods
    
    private func discoverViaARP() -> [NetworkDevice] {
        let result = CommandExecutor.execute(executable: "arp", arguments: ["-a"])
        var devices: [NetworkDevice] = []
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            // Format: ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ...
            guard let ipMatch = line.range(of: "\\([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\)", options: .regularExpression) else { continue }
            let ipRaw = String(line[ipMatch])
            let ip = ipRaw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            
            var mac = "--"
            if let macMatch = line.range(of: "[0-9a-f]{1,2}:[0-9a-f]{1,2}:[0-9a-f]{1,2}:[0-9a-f]{1,2}:[0-9a-f]{1,2}:[0-9a-f]{1,2}", options: [.regularExpression, .caseInsensitive]) {
                mac = String(line[macMatch])
            }
            
            if ip != "255.255.255.255" && !ip.hasSuffix(".255") {
                devices.append(NetworkDevice(ipAddress: ip, macAddress: mac))
            }
        }
        return devices
    }
    
    private func pingSweep(subnet: String) async -> [NetworkDevice] {
        // Ping a subset to keep it fast (first 30 + last 30 IPs)
        var devices: [NetworkDevice] = []
        let ipsToScan = Array(1...30) + Array(225...254)
        
        for octet in ipsToScan {
            guard await isStillScanning() else { break }
            let ip = "\(subnet).\(octet)"
            let result = CommandExecutor.execute(executable: "ping", arguments: ["-c", "1", "-W", "200", ip])
            if result.success {
                devices.append(NetworkDevice(ipAddress: ip))
            }
        }
        return devices
    }
    
    private func scanPorts(ip: String) -> [PortResult] {
        var results: [PortResult] = []
        for port in commonPorts {
            // Use /dev/tcp via bash -c OR nc with short timeout
            let result = CommandExecutor.execute(executable: "/usr/bin/nc", arguments: ["-z", "-w", "1", "-G", "1", ip, String(port)])
            let isOpen = result.exitCode == 0
            let service = serviceNames[port] ?? "unknown"
            results.append(PortResult(port: port, isOpen: isOpen, service: service))
        }
        return results
    }
    
    private func resolveHostname(ip: String) -> String {
        let result = CommandExecutor.execute(executable: "host", arguments: [ip])
        if result.success {
            let lines = result.stdout.components(separatedBy: .newlines)
            for line in lines {
                if line.contains("domain name pointer") {
                    let parts = line.split(separator: " ")
                    if let last = parts.last {
                        var hostname = String(last)
                        if hostname.hasSuffix(".") {
                            hostname = String(hostname.dropLast())
                        }
                        return hostname
                    }
                }
            }
        }
        return "unknown"
    }
    
    // MARK: - Helpers
    
    private func updatePhase(_ phase: String, progress: Double) async {
        await MainActor.run {
            self.session.scanPhase = phase
            self.session.progress = progress
        }
    }
    
    private func isStillScanning() async -> Bool {
        return await MainActor.run { self.session.isScanning }
    }
}
