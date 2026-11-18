import SwiftUI
import Observation
import HackCodeKit

@MainActor
@Observable
final class StorageViewModel {
    private(set) var path: String = NSHomeDirectory()
    private(set) var entries: [SizedEntry] = []
    private(set) var isScanning = false
    private(set) var error: String?
    private(set) var scannedAt: Date?
    private(set) var scannedItems = 0
    private(set) var childCount = 0
    var selectedPath: String?
    private(set) var backStack: [String] = []
    enum ViewMode: String, CaseIterable { case list = "LIST", map = "MAP", apps = "APPS" }
    /// LIST (table), MAP (squarified treemap) or APPS (installed-application inventory).
    var viewMode: ViewMode = .list { didSet { if viewMode == .apps && apps.isEmpty && !appsScanning { scanApps() } } }

    // MARK: Apps inventory

    enum AppFilter: String, CaseIterable { case all = "ALL", intel = "INTEL ONLY", thirdParty = "THIRD-PARTY" }
    private(set) var apps: [InstalledApp] = []
    private(set) var appsScanning = false
    var appFilter: AppFilter = .all
    var selectedApp: String?

    var filteredApps: [InstalledApp] {
        switch appFilter {
        case .all: return apps
        case .intel: return apps.filter { $0.architecture.needsRosetta }
        case .thirdParty: return apps.filter { !$0.isApple }
        }
    }

    func scanApps() {
        appsScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppInventory.scan() }.value
            apps = found
            appsScanning = false
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let sizer = FolderSizer()
    @ObservationIgnored private var task: Task<Void, Never>?

    func attach(_ app: AppModel) { self.app = app }

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var selected: SizedEntry? { entries.first { $0.path == selectedPath } }

    static var shortcuts: [(String, String)] {
        let h = NSHomeDirectory() as NSString
        return [("~", NSHomeDirectory()), ("Downloads", h.appendingPathComponent("Downloads")), ("Documents", h.appendingPathComponent("Documents")),
                ("Desktop", h.appendingPathComponent("Desktop")), ("Caches", h.appendingPathComponent("Library/Caches")),
                ("Applications", "/Applications")]
    }

    /// Breadcrumb segments from the closest readable root (home, /Applications or /Volumes).
    var breadcrumbs: [(name: String, path: String)] {
        let home = NSHomeDirectory()
        let base: String = path.hasPrefix(home) ? home : (path.hasPrefix("/Applications") ? "/Applications" : "/Volumes")
        var crumbs: [(String, String)] = [(base == home ? "~" : base, base)]
        var current = base
        for part in path.dropFirst(base.count).split(separator: "/") {
            current += "/" + part
            crumbs.append((String(part), current))
        }
        return crumbs
    }

    func appeared() {
        if entries.isEmpty && !isScanning && error == nil { open(path, pushHistory: false) }
    }

    func open(_ raw: String, pushHistory: Bool = true, force: Bool = false) {
        guard let app else { return }
        let resolved: String
        do {
            resolved = try app.policy.paths.resolveReadable(raw)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if pushHistory, resolved != path { backStack.append(path) }
        task?.cancel()
        path = resolved
        error = nil
        selectedPath = nil
        Task {
            if force { await sizer.invalidate(resolved) }
            if let cached = await sizer.cached(resolved) {
                apply(cached)
                return
            }
            scan(resolved)
        }
    }

    private func scan(_ target: String) {
        guard let app else { return }
        entries = []
        isScanning = true
        scannedItems = 0
        childCount = (try? FileManager.default.contentsOfDirectory(atPath: target).count) ?? 0
        let excluded = app.policy.context.excludedPrefixes
        let stream = OrderedEntryStream { [weak self] entry in
            guard let self, self.path == target else { return }
            self.entries.append(entry)
            self.entries.sort { $0.bytes > $1.bytes }
            self.scannedItems += entry.itemCount
        }
        task = Task {
            do {
                let result = try await sizer.scan(target, excluded: excluded, progress: stream.onEntry)
                await stream.finish()
                if path == target { apply(result) }
            } catch is CancellationError {
                await stream.finish()
            } catch {
                await stream.finish()
                if path == target {
                    self.error = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }

    private func apply(_ scan: FolderScan) {
        entries = scan.entries
        scannedItems = scan.scannedItems
        childCount = scan.entries.count
        scannedAt = scan.date
        isScanning = false
    }

    func up() {
        let parent = (path as NSString).deletingLastPathComponent
        open(parent)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        open(previous, pushHistory: false)
    }

    func rescan() { open(path, pushHistory: false, force: true) }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    func enter(_ entry: SizedEntry) {
        guard entry.isDirectory, !entry.isProtected else { return }
        open(entry.path)
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let i = selectedPath.flatMap { p in entries.firstIndex { $0.path == p } } ?? (delta > 0 ? -1 : entries.count)
        selectedPath = entries[min(max(i + delta, 0), entries.count - 1)].path
    }

    // MARK: Actions — staged in SYS.ADMIN, where the normal validation / approval flow applies.

    func stage(_ operation: String, _ args: [String: ArgumentValue], _ label: String) {
        app?.sysAdmin.stage(OperationRequest(operationID: operation, arguments: args, provenance: .user), note: label)
    }

    func reveal(_ e: SizedEntry) { stage("finder.reveal", ["path": .string(e.path)], "Reveal \(e.name) in Finder") }
    func trash(_ e: SizedEntry) { stage("files.move_to_trash", ["path": .string(e.path)], "Move \(e.name) to the Trash") }
    func duplicates(in p: String) { stage("files.duplicates", ["path": .string(p)], "Duplicate files in \((p as NSString).lastPathComponent)") }
    func stale(in p: String) { stage("files.stale", ["path": .string(p), "days": .integer(180)], "Files untouched for 180+ days in \((p as NSString).lastPathComponent)") }
    func largest(in p: String) { stage("files.largest", ["path": .string(p), "limit": .integer(25)], "Largest files in \((p as NSString).lastPathComponent)") }
}

/// Orders streamed scan results onto the main actor.
@MainActor
final class OrderedEntryStream {
    let onEntry: @Sendable (SizedEntry) -> Void
    private let continuation: AsyncStream<SizedEntry>.Continuation
    private let consumer: Task<Void, Never>

    init(_ handle: @escaping @MainActor (SizedEntry) -> Void) {
        let (stream, continuation) = AsyncStream<SizedEntry>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.onEntry = { continuation.yield($0) }
        self.consumer = Task { @MainActor in for await e in stream { handle(e) } }
    }

    func finish() async {
        continuation.finish()
        await consumer.value
    }
}
