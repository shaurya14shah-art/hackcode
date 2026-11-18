import Foundation

/// Decides which filesystem paths operations may touch. Validation happens at proposal time and again at
/// execution time, on fully resolved paths (symlinks followed), so a link cannot redirect an operation.
public struct PathPolicy: Sendable {
    public let readRoots: [String]
    public let writeRoots: [String]
    /// Resolved prefixes that are never readable or writable even inside a root (credentials, private data).
    public let deniedPrefixes: [String]
    public static let maxPathLength = 1024

    public init(readRoots: [String], writeRoots: [String], deniedPrefixes: [String]) {
        self.readRoots = readRoots.compactMap(Self.realpathOrNil)
        self.writeRoots = writeRoots.compactMap(Self.realpathOrNil)
        self.deniedPrefixes = deniedPrefixes.map { Self.realpathOrNil($0) ?? $0 }
    }

    public static func standard(home: String = NSHomeDirectory()) -> PathPolicy {
        let h = (home as NSString)
        let writable = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures", "Library/Caches"].map { h.appendingPathComponent($0) }
        let denied = [
            ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".config/gcloud",
            "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Cookies", "Library/Safari",
            "Library/Application Support/com.apple.TCC", "Library/Accounts", "Library/Suggestions",
        ].map { h.appendingPathComponent($0) }
        return PathPolicy(readRoots: [home, "/Applications", "/Volumes"], writeRoots: writable, deniedPrefixes: denied)
    }

    /// Validates a path for read-only inspection and returns the resolved absolute path.
    public func resolveReadable(_ raw: String) throws -> String {
        let lexical = try Self.lexicallyValidate(raw)
        guard let resolved = Self.realpathOrNil(lexical) else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "it does not exist or cannot be resolved")
        }
        try checkDenied(resolved, raw: raw)
        guard readRoots.contains(where: { Self.isWithin(resolved, root: $0, allowRootItself: true) }) else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "it is outside the readable locations (home folder, /Applications, /Volumes)")
        }
        return resolved
    }

    /// Validates an item that may be moved to the Trash. The parent directory is resolved, the final component
    /// is not followed (trashing a symlink trashes the link, never its target). Roots themselves are protected.
    public func resolveTrashable(_ raw: String) throws -> String {
        let lexical = try Self.lexicallyValidate(raw)
        let parent = (lexical as NSString).deletingLastPathComponent
        let name = (lexical as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", let resolvedParent = Self.realpathOrNil(parent) else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "its folder does not exist")
        }
        let candidate = (resolvedParent as NSString).appendingPathComponent(name)
        var st = stat()
        guard lstat(candidate, &st) == 0 else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "the item does not exist")
        }
        try checkDenied(candidate, raw: raw)
        if name.hasPrefix(".") {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "hidden items are not removed by HackCode")
        }
        if writeRoots.contains(candidate) {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "the folder itself cannot be moved to the Trash; choose an item inside it")
        }
        guard writeRoots.contains(where: { Self.isWithin(candidate, root: $0, allowRootItself: false) }) else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "only items inside Downloads, Desktop, Documents, Movies, Music, Pictures or ~/Library/Caches can be moved to the Trash")
        }
        return candidate
    }

    // MARK: - Helpers

    static func lexicallyValidate(_ raw: String) throws -> String {
        // Control characters are rejected before any trimming so "a\n" is never silently treated as "a".
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HackCodeError.pathNotPermitted(path: raw.debugDescription, reason: "the path contains control characters")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw HackCodeError.pathNotPermitted(path: raw, reason: "the path is empty") }
        guard trimmed.count <= maxPathLength else { throw HackCodeError.pathNotPermitted(path: String(raw.prefix(64)) + "…", reason: "the path is too long") }
        var expanded = trimmed
        if expanded == "~" {
            expanded = NSHomeDirectory()
        } else if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst(1))
        }
        guard expanded.hasPrefix("/") else {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "only absolute paths or ~/ paths are accepted")
        }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." }) {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "parent-directory traversal ('..') is not accepted")
        }
        return expanded
    }

    func checkDenied(_ resolved: String, raw: String) throws {
        if deniedPrefixes.contains(where: { Self.isWithin(resolved, root: $0, allowRootItself: true) }) {
            throw HackCodeError.pathNotPermitted(path: raw, reason: "it is a protected location containing credentials or private data")
        }
    }

    static func isWithin(_ path: String, root: String, allowRootItself: Bool) -> Bool {
        if path == root { return allowRootItself }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    static func realpathOrNil(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
