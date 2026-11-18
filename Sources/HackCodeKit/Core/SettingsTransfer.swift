import Foundation

/// Settings backup: export to a versioned JSON envelope and import it back with validation.
/// The API key is never part of settings (it lives in the Keychain). The endpoint is never exported or imported,
/// so a crafted file cannot redirect requests. Imported aliases are re-validated like typed ones.
public enum SettingsTransfer {
    public static let format = "hackcode-settings"
    public static let version = 1
    public static let maxBytes = 256 * 1024
    /// Never written to, nor taken from, a settings file.
    public static let excludedKeys: Set<String> = ["baseURL"]
    /// Turning these on sends more data to the model provider; imports that do so are called out before applying.
    public static let privacySensitiveKeys: Set<String> = ["shareProcessSnapshotWithModel", "autoExplainResults"]

    public enum ImportError: Error, Equatable, LocalizedError {
        case tooLarge, notASettingsFile, unsupportedVersion(Int), malformed(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "The file is larger than \(SettingsTransfer.maxBytes / 1024) KB — not a HackCode settings export."
            case .notASettingsFile: return "This is not a HackCode settings export."
            case .unsupportedVersion(let v): return "Settings export version \(v) is newer than this HackCode understands."
            case .malformed(let why): return "The settings file could not be read: \(why)"
            }
        }
    }

    public struct ImportResult: Sendable, Equatable {
        public let settings: HackCodeSettings
        public let changedKeys: [String]
        /// Privacy-sensitive switches this import would turn on.
        public let privacyWarnings: [String]
        /// Aliases dropped because they failed validation.
        public let skippedAliases: [String]
    }

    public static func export(_ settings: HackCodeSettings, now: Date = Date()) throws -> Data {
        let enc = JSONEncoder()
        guard var dict = try JSONSerialization.jsonObject(with: enc.encode(settings)) as? [String: Any] else {
            throw ImportError.malformed("encoding failed")
        }
        for k in excludedKeys { dict.removeValue(forKey: k) }
        let envelope: [String: Any] = ["format": format, "version": version,
                                       "exported": ISO8601DateFormatter().string(from: now), "settings": dict]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    public static func importSettings(_ data: Data, into current: HackCodeSettings, reservedAliasNames: Set<String>) throws -> ImportResult {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              top["format"] as? String == format else { throw ImportError.notASettingsFile }
        let v = top["version"] as? Int ?? 0
        guard v >= 1 else { throw ImportError.notASettingsFile }
        guard v <= version else { throw ImportError.unsupportedVersion(v) }
        guard let incoming = top["settings"] as? [String: Any] else { throw ImportError.malformed("missing settings") }

        // Overlay onto the current settings so absent keys keep their current values.
        guard var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any] else {
            throw ImportError.malformed("encoding failed")
        }
        for (k, value) in incoming where !excludedKeys.contains(k) { merged[k] = value }
        var next: HackCodeSettings
        do {
            next = try JSONDecoder().decode(HackCodeSettings.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            throw ImportError.malformed("a value has the wrong type")
        }
        next.baseURL = current.baseURL

        // Aliases: same rules as /alias.
        var accepted: [String: String] = [:]
        var skipped: [String] = []
        for (name, expansion) in next.aliases.sorted(by: { $0.key < $1.key }) {
            if (try? AliasBook.validate(name: name, expansion: expansion, reserved: reservedAliasNames, existing: accepted)) != nil {
                accepted[name] = expansion
            } else {
                skipped.append(name)
            }
        }
        next.aliases = accepted
        next.clamp()

        let changed = next.changedKeys(from: current)
        let flags: [String: (HackCodeSettings) -> Bool] = [
            "shareProcessSnapshotWithModel": { $0.shareProcessSnapshotWithModel },
            "autoExplainResults": { $0.autoExplainResults },
        ]
        let warnings = privacySensitiveKeys.sorted().filter { k in
            guard let f = flags[k] else { return false }
            return f(next) && !f(current)
        }
        return ImportResult(settings: next, changedKeys: changed, privacyWarnings: warnings, skippedAliases: skipped)
    }
}
