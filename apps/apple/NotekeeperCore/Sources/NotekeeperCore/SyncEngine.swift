import Foundation

/// Orchestrates pulls from `/v1/sync` into the LocalStore and pushes the
/// dirty queue back through PATCH. Stateless beyond the actor; cursor lives
/// in the LocalStore so syncs survive restarts.
public actor SyncEngine {
    private let client: APIClient
    private let store: LocalStore
    private var pulling = false
    private var pushing = false

    public init(client: APIClient, store: LocalStore) {
        self.client = client
        self.store = store
    }

    public struct PullSummary: Sendable {
        public let pages: Int
        public let notesUpserted: Int
        public let foldersUpserted: Int
        public let deleted: Int
    }

    /// Drain `/v1/sync` until `truncated == false`. Idempotent on re-entry —
    /// only one pull is in flight at a time.
    @discardableResult
    public func syncOnce() async throws -> PullSummary {
        if pulling { return PullSummary(pages: 0, notesUpserted: 0, foldersUpserted: 0, deleted: 0) }
        pulling = true
        defer { pulling = false }

        var pages = 0
        var notesCount = 0
        var foldersCount = 0
        var deletedCount = 0
        var since = try await store.cursor()
        var safety = 50  // hard cap on page count per call so a runaway server can't loop us forever
        while safety > 0 {
            safety -= 1
            let resp = try await client.sync(since: since, limit: 500)
            try await store.apply(resp)
            pages += 1
            notesCount += resp.notes.count
            foldersCount += resp.folders.count
            deletedCount += resp.deleted.count
            since = resp.serverTime
            if !resp.truncated { break }
        }
        return PullSummary(
            pages: pages,
            notesUpserted: notesCount,
            foldersUpserted: foldersCount,
            deleted: deletedCount
        )
    }

    /// Push every locally-dirty note back to the server. PATCHes serially to
    /// avoid PATCH/PATCH races on the same note. Returns the count pushed.
    @discardableResult
    public func pushDirty() async throws -> Int {
        if pushing { return 0 }
        pushing = true
        defer { pushing = false }

        var pushed = 0
        while true {
            let pending = try await store.nextDirty(limit: 25)
            if pending.isEmpty { break }
            for note in pending {
                let updated = try await client.updateNote(
                    id: note.id,
                    NoteUpdate(title: note.title, body: note.body)
                )
                try await store.clearDirty(noteId: note.id, serverNote: updated)
                pushed += 1
            }
        }
        return pushed
    }
}
