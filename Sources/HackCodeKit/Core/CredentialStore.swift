import Foundation
import Security

/// Storage for the NVIDIA API key. The key is never logged or placed in model context.
public protocol CredentialStore: Sendable {
    /// Whether a key is stored. Must not trigger UI (e.g. a Keychain access prompt); safe on the main thread.
    func hasStoredKey() -> Bool
    /// Reads the key. May block on a system prompt — call off the main thread.
    func readAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

public extension CredentialStore {
    var hasAPIKey: Bool { hasStoredKey() }
}

/// macOS Keychain-backed credential store (generic password item).
public struct KeychainCredentialStore: CredentialStore {
    /// Service name kept compatible with HackCode 2.x so existing keys continue to work.
    public static let defaultService = "HackCode_NVIDIA_API_KEY"
    public let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    /// Attributes-only lookup: does not access the secret, so macOS never shows an access prompt for it.
    public func hasStoredKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { return true }
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["HACKCODE_DEV_NVIDIA_API_KEY"], !env.isEmpty { return true }
        #endif
        return false
    }

    public func readAPIKey() throws -> String? {
        #if DEBUG
        // Development-only override (debug builds only): lets scripted runs avoid Keychain prompts.
        if let env = ProcessInfo.processInfo.environment["HACKCODE_DEV_NVIDIA_API_KEY"], !env.isEmpty { return env }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw HackCodeError.credentialStoreFailure(status)
        }
    }

    public func saveAPIKey(_ key: String) throws {
        let clean = Self.normalize(key)
        guard !clean.isEmpty, let data = clean.data(using: .utf8) else {
            throw HackCodeError.invalidArgument(operation: "settings", argument: "apiKey", reason: "the key is empty")
        }
        try deleteAPIKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw HackCodeError.credentialStoreFailure(status) }
    }

    public func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HackCodeError.credentialStoreFailure(status)
        }
    }

    /// Strips whitespace and an accidental "Bearer " prefix.
    public static func normalize(_ key: String) -> String {
        var clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("bearer ") {
            clean = String(clean.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean
    }
}

/// In-memory store used by tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    public init(key: String? = nil) { self.key = key }
    public func hasStoredKey() -> Bool { lock.withLock { !(key ?? "").isEmpty } }
    public func readAPIKey() throws -> String? { lock.withLock { key } }
    public func saveAPIKey(_ key: String) throws { lock.withLock { self.key = KeychainCredentialStore.normalize(key) } }
    public func deleteAPIKey() throws { lock.withLock { key = nil } }
}
