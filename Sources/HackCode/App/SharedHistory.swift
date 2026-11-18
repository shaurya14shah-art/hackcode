import Foundation
import Observation
import HackCodeKit

/// Command history shared by every terminal tab (like zsh's SHARE_HISTORY), persisted when enabled.
@MainActor
@Observable
final class SharedHistory {
    private(set) var history = CommandHistory()
    @ObservationIgnored private let store: CommandHistoryStore
    @ObservationIgnored private let shouldPersist: @MainActor () -> Bool

    init(store: CommandHistoryStore, shouldPersist: @escaping @MainActor () -> Bool) {
        self.store = store
        self.shouldPersist = shouldPersist
    }

    func load() async {
        guard shouldPersist() else { return }
        let loaded = await store.load()
        // Keep anything typed before loading finished.
        var merged = loaded
        for line in history.entries { merged.record(line) }
        history = merged
    }

    func record(_ line: String) {
        history.record(line)
        guard shouldPersist() else { return }
        let snapshot = history
        Task { await store.save(snapshot) }
    }

    func clear() async {
        history.clear()
        await store.clear()
    }

    func deleteFile() async { await store.clear() }
}
