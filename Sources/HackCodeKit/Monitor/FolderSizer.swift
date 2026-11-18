import Foundation

/// One child of a scanned folder, with its total allocated size.
public struct SizedEntry: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let bytes: Int64
    public let itemCount: Int
    public let modified: Date?
    /// Protected by HackCode's path policy (credentials / private data) — never entered.
    public let isProtected: Bool
    /// macOS denied access (or the folder could only be partially read).
    public let unreadable: Bool
    /// The scan stopped at its limit, so the size is a lower bound.
    public let partial: Bool
}

public struct FolderScan: Sendable, Equatable {
    public let path: String
    public let entries: [SizedEntry]
    public let totalBytes: Int64
    public let scannedItems: Int
    public let date: Date
}

/// Read-only folder size scanner (metadata only; never follows symlinks; skips protected locations).
/// Results are cached per folder so navigating back is instant.
public actor FolderSizer {
    private var cache: [String: FolderScan] = [:]
    public static let maxItemsPerChild = 400_000

    public init() {}

    public func cached(_ path: String) -> FolderScan? { cache[path] }
    public func invalidate(_ path: String) { cache = cache.filter { !$0.key.hasPrefix(path) } }

    /// Sizes every child of `path`. `progress` receives each finished child (largest-first ordering is left to the caller).
    public func scan(_ path: String, excluded: [String],
                     progress: @escaping @Sendable (SizedEntry) -> Void = { _ in }) async throws -> FolderScan {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw HackCodeError.permissionDenied("cannot list \(path): \(error.localizedDescription)")
        }
        var entries: [SizedEntry] = []
        var scanned = 0
        try await withThrowingTaskGroup(of: SizedEntry.self) { group in
            var iterator = children.makeIterator()
            func addNext() {
                guard let child = iterator.next() else { return }
                group.addTask { try Self.size(child, keys: keys, excluded: excluded) }
            }
            for _ in 0..<4 { addNext() }
            while let entry = try await group.next() {
                try Task.checkCancellation()
                entries.append(entry)
                scanned += entry.itemCount
                progress(entry)
                addNext()
            }
        }
        entries.sort { $0.bytes > $1.bytes }
        let result = FolderScan(path: path, entries: entries, totalBytes: entries.reduce(0) { $0 + $1.bytes },
                                scannedItems: scanned, date: Date())
        cache[path] = result
        return result
    }

    static func size(_ url: URL, keys: [URLResourceKey], excluded: [String]) throws -> SizedEntry {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let path = url.path
        let isLink = v?.isSymbolicLink == true
        let isDir = v?.isDirectory == true && !isLink
        let protected = excluded.contains { PathPolicy.isWithin(path, root: $0, allowRootItself: true) }
        func entry(bytes: Int64, items: Int, unreadable: Bool = false, partial: Bool = false) -> SizedEntry {
            SizedEntry(name: url.lastPathComponent, path: path, isDirectory: isDir, isPackage: v?.isPackage == true,
                       bytes: bytes, itemCount: items, modified: v?.contentModificationDate,
                       isProtected: protected, unreadable: unreadable, partial: partial)
        }
        if protected { return entry(bytes: 0, items: 0) }
        guard isDir else {
            return entry(bytes: isLink ? 0 : Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0), items: 1)
        }
        var total: Int64 = 0
        var count = 0
        var hadErrors = false
        let errorFlag = ErrorFlag()
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in errorFlag.set(); return true }) else {
            return entry(bytes: 0, items: 0, unreadable: true)
        }
        while let item = e.nextObject() as? URL {
            try Task.checkCancellation()
            if excluded.contains(where: { PathPolicy.isWithin(item.path, root: $0, allowRootItself: true) }) {
                e.skipDescendants()
                continue
            }
            guard let iv = try? item.resourceValues(forKeys: Set(keys)), iv.isSymbolicLink != true else { continue }
            if iv.isDirectory != true { total += Int64(iv.totalFileAllocatedSize ?? iv.fileAllocatedSize ?? 0) }
            count += 1
            if count >= maxItemsPerChild { return entry(bytes: total, items: count, partial: true) }
        }
        hadErrors = errorFlag.value
        return entry(bytes: total, items: count, unreadable: hadErrors && count == 0, partial: hadErrors && count > 0)
    }
}

private final class ErrorFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
