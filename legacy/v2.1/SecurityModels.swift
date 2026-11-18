import Foundation

// MARK: - Core Enums
enum HackCodeMode: String, CaseIterable {
    case systemAdmin = "SYS.ADMIN"
    case monitor = "MONITOR"
    case security = "SECURITY"
    case networkScanner = "NET.SCAN"
}

enum SecuritySeverity: String, Codable, Comparable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"
    
    var priority: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }
    
    static func < (lhs: SecuritySeverity, rhs: SecuritySeverity) -> Bool {
        return lhs.priority < rhs.priority
    }
}

enum RemediationStatus: String, Codable {
    case pending = "PENDING"
    case resolved = "RESOLVED"
    case improved = "IMPROVED"
    case unchanged = "UNCHANGED"
    case unableToVerify = "UNABLE TO VERIFY"
}

// MARK: - Scope and Context

enum TargetType: String, Codable {
    case localMac = "LOCAL_MAC"
    case domain = "DOMAIN"
    case ipAddress = "IP_ADDRESS"
    case networkRange = "NETWORK_RANGE"
    case webApplication = "WEB_APPLICATION"
    case directory = "DIRECTORY"
    case file = "FILE"
}

struct AuthContext: Codable {
    var requiresRoot: Bool = false
    var credentialsId: String?
    var customTokens: [String: String]?
}

struct SecurityScope: Identifiable, Codable {
    let id: UUID
    var target: String
    var targetType: TargetType
    var authContext: AuthContext?
    
    init(id: UUID = UUID(), target: String, targetType: TargetType, authContext: AuthContext? = nil) {
        self.id = id
        self.target = target
        self.targetType = targetType
        self.authContext = authContext
    }
}

// MARK: - Correlation Graph Models

enum AssetType: String, Codable {
    case host = "HOST"
    case ip = "IP"
    case domain = "DOMAIN"
    case openPort = "OPEN_PORT"
    case service = "SERVICE"
    case userAccount = "USER_ACCOUNT"
    case fileSystem = "FILE_SYSTEM"
    case vulnerability = "VULNERABILITY"
    case unknown = "UNKNOWN"
}

struct SecurityAsset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: AssetType
    var properties: [String: String]
    
    init(id: UUID = UUID(), name: String, type: AssetType, properties: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.type = type
        self.properties = properties
    }
    
    static func == (lhs: SecurityAsset, rhs: SecurityAsset) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum RelationshipType: String, Codable {
    case resolvesTo = "RESOLVES_TO"
    case hosts = "HOSTS"
    case runs = "RUNS"
    case owns = "OWNS"
    case exposes = "EXPOSES"
    case vulnerableTo = "VULNERABLE_TO"
    case relatedTo = "RELATED_TO"
}

struct SecurityRelationship: Identifiable, Codable, Hashable {
    let id: UUID
    var sourceId: UUID
    var targetId: UUID
    var type: RelationshipType
    var metadata: [String: String]
    
    init(id: UUID = UUID(), sourceId: UUID, targetId: UUID, type: RelationshipType, metadata: [String: String] = [:]) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.type = type
        self.metadata = metadata
    }
}

// MARK: - Observation

struct SecurityObservation: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let toolId: String
    let description: String
    var relatedAssets: [SecurityAsset]
    var relationships: [SecurityRelationship]
    var rawData: Data?
    
    init(id: UUID = UUID(), timestamp: Date = Date(), toolId: String, description: String, relatedAssets: [SecurityAsset] = [], relationships: [SecurityRelationship] = [], rawData: Data? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.toolId = toolId
        self.description = description
        self.relatedAssets = relatedAssets
        self.relationships = relationships
        self.rawData = rawData
    }
}

// MARK: - Findings & Audits

struct SecurityFinding: Identifiable, Codable {
    let id: UUID
    let title: String
    let category: String
    let severity: SecuritySeverity
    let target: String
    let evidence: [String]
    let explanation: String
    let impact: String
    let remediation: String
    let verification: String
    let confidence: String // HIGH, MEDIUM, LOW
    var remediationStatus: RemediationStatus
    
    init(id: UUID = UUID(), title: String, category: String, severity: SecuritySeverity, target: String = "THIS MAC", evidence: [String], explanation: String, impact: String, remediation: String, verification: String, confidence: String, remediationStatus: RemediationStatus = .pending) {
        self.id = id
        self.title = title
        self.category = category
        self.severity = severity
        self.target = target
        self.evidence = evidence
        self.explanation = explanation
        self.impact = impact
        self.remediation = remediation
        self.verification = verification
        self.confidence = confidence
        self.remediationStatus = remediationStatus
    }
}

enum CheckResult {
    case success(evidence: String)
    case failure(error: String)
}

protocol SecurityCheck {
    var id: String { get }
    var name: String { get }
    var category: String { get }
    var remediationCommand: String? { get }
    
    func execute() async -> CheckResult
}

struct SecurityAuditSession: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var target: String = "THIS MAC"
    var checksPerformed: Int
    var findings: [SecurityFinding]
    
    init(id: UUID = UUID(), timestamp: Date = Date(), checksPerformed: Int = 0, findings: [SecurityFinding] = []) {
        self.id = id
        self.timestamp = timestamp
        self.checksPerformed = checksPerformed
        self.findings = findings
    }
    
    var overallScore: Int {
        if checksPerformed == 0 { return 100 }
        return RiskEngine().calculatePostureScore(findings: findings)
    }
}

// MARK: - Network Scanner Models

enum DeviceStatus: String, Codable {
    case online = "ONLINE"
    case offline = "OFFLINE"
    case scanning = "SCANNING"
}

struct PortResult: Identifiable, Codable, Hashable {
    let id: UUID
    let port: Int
    let isOpen: Bool
    let service: String
    let banner: String
    
    init(id: UUID = UUID(), port: Int, isOpen: Bool, service: String = "unknown", banner: String = "") {
        self.id = id
        self.port = port
        self.isOpen = isOpen
        self.service = service
        self.banner = banner
    }
}

struct NetworkDevice: Identifiable, Codable {
    let id: UUID
    let ipAddress: String
    var hostname: String
    var macAddress: String
    var vendor: String
    var status: DeviceStatus
    var openPorts: [PortResult]
    var lastSeen: Date
    var isGateway: Bool
    var isLocalHost: Bool
    
    init(id: UUID = UUID(), ipAddress: String, hostname: String = "unknown", macAddress: String = "--", vendor: String = "Unknown", status: DeviceStatus = .online, openPorts: [PortResult] = [], lastSeen: Date = Date(), isGateway: Bool = false, isLocalHost: Bool = false) {
        self.id = id
        self.ipAddress = ipAddress
        self.hostname = hostname
        self.macAddress = macAddress
        self.vendor = vendor
        self.status = status
        self.openPorts = openPorts
        self.lastSeen = lastSeen
        self.isGateway = isGateway
        self.isLocalHost = isLocalHost
    }
}

struct NetworkScanSession: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var subnet: String
    var devices: [NetworkDevice]
    var isScanning: Bool
    var progress: Double // 0.0 - 1.0
    var scanPhase: String
    
    init(id: UUID = UUID(), timestamp: Date = Date(), subnet: String = "", devices: [NetworkDevice] = [], isScanning: Bool = false, progress: Double = 0.0, scanPhase: String = "IDLE") {
        self.id = id
        self.timestamp = timestamp
        self.subnet = subnet
        self.devices = devices
        self.isScanning = isScanning
        self.progress = progress
        self.scanPhase = scanPhase
    }
}
