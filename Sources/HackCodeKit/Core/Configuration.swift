import Foundation

/// User-adjustable configuration. Persisted as JSON in UserDefaults; contains no secrets.
public struct HackCodeSettings: Codable, Equatable, Sendable {
    /// Only HTTPS endpoints on this host are accepted, so a typo cannot send the key elsewhere.
    public static let allowedAPIHost = "integrate.api.nvidia.com"
    public static let defaultBaseURL = "https://integrate.api.nvidia.com/v1"
    /// Nemotron-3 model verified callable via the NVIDIA API catalog at development time.
    public static let defaultModelID = "nvidia/nemotron-3-ultra-550b-a55b"
    public static let suggestedModelIDs = [
        "nvidia/nemotron-3-ultra-550b-a55b",
        "nvidia/nemotron-3-super-120b-a12b",
        "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
        "nvidia/nemotron-nano-3-30b-a3b",
    ]

    public var baseURL: String = HackCodeSettings.defaultBaseURL
    public var modelID: String = HackCodeSettings.defaultModelID
    /// Nemotron-3 reasoning mode. Off by default: faster, and reasoning text is never shown or stored.
    public var enableModelReasoning: Bool = false
    public var requestTimeoutSeconds: Double = 60
    public var maxConversationTurns: Int = 12

    /// Monitor
    public var monitorIntervalSeconds: Double = 2
    public var monitorHistoryLength: Int = 120

    /// Privacy: what may be sent to the provider.
    public var shareProcessSnapshotWithModel: Bool = true
    public var autoExplainResults: Bool = false

    /// Alerts & background behaviour
    public var alertThresholds = AlertThresholds()
    /// Keep sampling (and alerting) while MONITOR is not visible.
    public var backgroundMonitoring: Bool = false
    public var notificationsEnabled: Bool = false
    public var showMenuBarExtra: Bool = true
    /// Re-run the security audit every N hours while HackCode is open (0 = off).
    public var autoAuditHours: Int = 0

    /// Keep terminal command history between launches (redacted, owner-only file).
    public var persistHistory: Bool = true

    /// Appearance: Matrix-style falling glyphs behind the interface.
    public var matrixRain: Bool = true
    /// Background rain opacity (0.1 subtle … 1.0 vivid).
    public var matrixRainIntensity: Double = 0.85
    /// Terminal aliases: name → expansion (see AliasBook).
    public var aliases: [String: String] = [:]
    /// Process names pinned in MONITOR (max 12).
    public var pinnedProcesses: [String] = []
    /// tmux-style status line along the bottom of the window.
    public var showStatusLine: Bool = true
    /// Terminal colour palette: "green", "amber", "cyan" or "mono".
    public var terminalTheme: String = "green"
    /// Bumped when appearance defaults change so older saved defaults are upgraded once.
    public var appearanceRevision: Int = 2

    public init() {}

    public func validatedBaseURL() throws -> URL {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host == Self.allowedAPIHost else {
            throw HackCodeError.invalidEndpoint("only https://\(Self.allowedAPIHost) is permitted")
        }
        return url
    }

    public var isModelIDWellFormed: Bool {
        modelID.range(of: "^[A-Za-z0-9._\\-]+/[A-Za-z0-9._\\-]+$", options: .regularExpression) != nil
    }

    /// Names of top-level settings that differ from `old` (sorted). Names only — values such as aliases or
    /// the endpoint are never put in the audit log.
    public func changedKeys(from old: HackCodeSettings) -> [String] {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        guard let a = try? enc.encode(old), let b = try? enc.encode(self),
              let da = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
              let db = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return [] }
        return Set(da.keys).union(db.keys).filter { key in
            switch (da[key], db[key]) {
            case let (x?, y?): return !(x as AnyObject).isEqual(y)
            case (nil, nil): return false
            default: return true
            }
        }.sorted()
    }

    public mutating func clamp() {
        requestTimeoutSeconds = min(max(requestTimeoutSeconds, 10), 300)
        maxConversationTurns = min(max(maxConversationTurns, 2), 40)
        monitorIntervalSeconds = min(max(monitorIntervalSeconds, 0.5), 30)
        monitorHistoryLength = min(max(monitorHistoryLength, 10), 600)
        alertThresholds.processCPUPercent = min(max(alertThresholds.processCPUPercent, 20), 800)
        alertThresholds.sustainedSamples = min(max(alertThresholds.sustainedSamples, 2), 60)
        alertThresholds.diskFreePercent = min(max(alertThresholds.diskFreePercent, 1), 50)
        alertThresholds.lowBatteryPercent = min(max(alertThresholds.lowBatteryPercent, 1), 50)
        autoAuditHours = min(max(autoAuditHours, 0), 168)
        pinnedProcesses = Array(pinnedProcesses.prefix(12))
        matrixRainIntensity = min(max(matrixRainIntensity, 0.1), 1.0)
    }
}

/// Loads and saves settings.
public protocol SettingsStore: Sendable {
    func load() -> HackCodeSettings
    func save(_ settings: HackCodeSettings)
}

public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "HackCode.settings.v3"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> HackCodeSettings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(HackCodeSettings.self, from: data) else {
            return HackCodeSettings()
        }
        settings.clamp()
        return settings
    }

    public func save(_ settings: HackCodeSettings) {
        var s = settings
        s.clamp()
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}

extension HackCodeSettings {
    private enum CodingKeys: String, CodingKey {
        case baseURL, modelID, enableModelReasoning, requestTimeoutSeconds, maxConversationTurns
        case monitorIntervalSeconds, monitorHistoryLength, shareProcessSnapshotWithModel, autoExplainResults
        case alertThresholds, backgroundMonitoring, notificationsEnabled, showMenuBarExtra, autoAuditHours
        case matrixRain, matrixRainIntensity, appearanceRevision, persistHistory, terminalTheme, showStatusLine, pinnedProcesses, aliases
    }

    /// Tolerant decoding: missing keys keep their defaults so settings survive upgrades.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? modelID
        enableModelReasoning = try c.decodeIfPresent(Bool.self, forKey: .enableModelReasoning) ?? enableModelReasoning
        requestTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds) ?? requestTimeoutSeconds
        maxConversationTurns = try c.decodeIfPresent(Int.self, forKey: .maxConversationTurns) ?? maxConversationTurns
        monitorIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .monitorIntervalSeconds) ?? monitorIntervalSeconds
        monitorHistoryLength = try c.decodeIfPresent(Int.self, forKey: .monitorHistoryLength) ?? monitorHistoryLength
        shareProcessSnapshotWithModel = try c.decodeIfPresent(Bool.self, forKey: .shareProcessSnapshotWithModel) ?? shareProcessSnapshotWithModel
        autoExplainResults = try c.decodeIfPresent(Bool.self, forKey: .autoExplainResults) ?? autoExplainResults
        alertThresholds = (try? c.decodeIfPresent(AlertThresholds.self, forKey: .alertThresholds)) ?? alertThresholds
        backgroundMonitoring = try c.decodeIfPresent(Bool.self, forKey: .backgroundMonitoring) ?? backgroundMonitoring
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? notificationsEnabled
        showMenuBarExtra = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? showMenuBarExtra
        autoAuditHours = try c.decodeIfPresent(Int.self, forKey: .autoAuditHours) ?? autoAuditHours
        matrixRain = try c.decodeIfPresent(Bool.self, forKey: .matrixRain) ?? matrixRain
        persistHistory = try c.decodeIfPresent(Bool.self, forKey: .persistHistory) ?? persistHistory
        terminalTheme = try c.decodeIfPresent(String.self, forKey: .terminalTheme) ?? terminalTheme
        showStatusLine = try c.decodeIfPresent(Bool.self, forKey: .showStatusLine) ?? showStatusLine
        pinnedProcesses = try c.decodeIfPresent([String].self, forKey: .pinnedProcesses) ?? pinnedProcesses
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? aliases
        let savedRevision = try c.decodeIfPresent(Int.self, forKey: .appearanceRevision) ?? 1
        if savedRevision >= 2 {
            matrixRainIntensity = try c.decodeIfPresent(Double.self, forKey: .matrixRainIntensity) ?? matrixRainIntensity
        }   // revision 1 stored the old, dimmer default — keep the new default instead
    }
}
