import Foundation
import NotekeeperCore

/// Which sidebar row is selected. Drives the middle column's filter.
enum SidebarSelection: Hashable {
    case allNotes
    case pinned
    case folder(id: String)
    case recentlyDeleted
}

/// Single source of truth for the app UI. All mutations run on the main
/// actor so SwiftUI views can observe without extra synchronization.
///
/// Backed by a local SQLite cache (`LocalStore`) so launch paints from disk
/// before the network responds. The server is the source of truth on edit
/// conflict (last-writer-wins by `updated_at`); local edits get the `dirty`
/// flag and are PATCHed back via `SyncEngine.pushDirty()`.
@MainActor
final class AppModel: ObservableObject {
    @Published var client: APIClient?
    @Published var endpoint: String = "https://notekeeper-prod.brian-via.workers.dev"
    @Published var apiKey: String = ""
    /// All notes loaded from the local cache, including trashed. Filtered
    /// for display via `notes` based on the active sidebar selection.
    @Published private(set) var allNotes: [Note] = [] {
        didSet { recomputeFilteredNotes() }
    }
    @Published private(set) var notes: [Note] = [] {
        didSet { rebuildNoteCaches() }
    }
    @Published var folders: [Folder] = [] {
        didSet { rebuildFolderCaches() }
    }
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var noteBuckets: [NoteBucket] = []
    @Published var sidebarSelection: SidebarSelection = .allNotes {
        didSet { recomputeFilteredNotes() }
    }
    @Published var selectedId: String?
    @Published var status: String = "Disconnected"
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false

    private let credentials = KeychainCredentialStore()
    private let store: LocalStore
    private var sync: SyncEngine?
    private var notesById: [String: Note] = [:]
    private var folderNamesById: [String: String] = [:]
    private var pushTask: Task<Void, Never>?

    init() {
        // The store init opens a connection synchronously and runs the
        // migrator. Failure here means the disk is unwritable — the app is
        // basically broken at that point, so crashing is acceptable.
        do {
            self.store = try LocalStore()
        } catch {
            fatalError("LocalStore init failed: \(error)")
        }
    }

    var selectedNote: Note? {
        guard let selectedId else { return nil }
        return notesById[selectedId]
    }

    /// Human-friendly label for the current sidebar selection, used as the
    /// note-list column header ("All Notes", "Pinned", folder name, etc.).
    var currentFilterLabel: String {
        switch sidebarSelection {
        case .allNotes: return "All Notes"
        case .pinned: return "Pinned"
        case .recentlyDeleted: return "Recently Deleted"
        case .folder(let id):
            return folderNamesById[id] ?? "Folder"
        }
    }

    func folderName(for folderId: String?) -> String {
        guard let folderId else { return "Notes" }
        return folderNamesById[folderId] ?? "Notes"
    }

    func loadStoredCredentialsAndConnect() async {
        // Paint from cache first — this is the whole point of having one.
        await reloadFromStore()

        if let cred = try? credentials.load() {
            endpoint = cred.endpoint.absoluteString
            apiKey = cred.apiKey
            await connect()
        }
    }

    func connect() async {
        errorMessage = nil
        guard let url = URL(string: endpoint), !apiKey.isEmpty else {
            errorMessage = "Endpoint and API key are required"
            return
        }
        isBusy = true
        defer { isBusy = false }
        status = "Connecting…"
        let newClient = APIClient(.init(endpoint: url, apiKey: apiKey))
        do {
            try await newClient.verify()
            client = newClient
            sync = SyncEngine(client: newClient, store: store)
            status = "Connected"
            try? credentials.save(Credential(endpoint: url, apiKey: apiKey))
            await refresh()
        } catch {
            client = nil
            sync = nil
            status = "Disconnected"
            errorMessage = "\(error)"
        }
    }

    func disconnect() {
        client = nil
        sync = nil
        selectedId = nil
        status = "Disconnected"
        try? credentials.delete()
        // Wipe the local cache so a fresh login can't leak the previous
        // user's notes onto disk.
        Task.detached { [store] in
            try? await store.wipe()
        }
        allNotes = []
        folders = []
        tags = []
    }

    func refresh() async {
        guard let sync else {
            await reloadFromStore()
            return
        }
        isBusy = true
        defer { isBusy = false }
        status = "Syncing…"
        do {
            // Push any dirty edits before pulling — keeps the cursor
            // advancing past our own writes so we don't yo-yo over them.
            _ = try await sync.pushDirty()
            _ = try await sync.syncOnce()
            await reloadFromStore()
            status = "Connected"
            if let selectedId, !allNotes.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        } catch {
            errorMessage = "\(error)"
            status = "Connected"
        }
    }

    func selectSidebar(_ selection: SidebarSelection) {
        sidebarSelection = selection
        selectedId = nil
        // No refresh — local cache already has everything; the filter just
        // recomputes from `allNotes` via the didSet above.
    }

    func createDraft() async {
        guard let client else { return }
        do {
            let folderId: String? = {
                if case .folder(let id) = sidebarSelection { return id }
                return nil
            }()
            let note = try await client.createNote(
                NoteCreate(title: "Untitled", body: "# Untitled\n\n", folderId: folderId)
            )
            try? await store.upsertServerNote(note)
            await reloadFromStore()
            selectedId = note.id
        } catch {
            errorMessage = "\(error)"
        }
    }

    func trashSelected() async {
        guard let id = selectedId else { return }
        await trash(id: id)
    }

    /// Soft-delete a note by id. Removes it from the current list view and
    /// clears the selection if it was selected.
    func trash(id: String) async {
        guard let client else { return }
        do {
            try await client.deleteNote(id: id)
            // Optimistic local update: refresh from server next sync
            // overwrites this if anything diverged.
            allNotes.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
            // Kick a background sync so the trashed_at column lands in the
            // local cache too.
            await refreshInBackground()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Permanently delete (no trash). Caller is expected to have already
    /// confirmed with the user — this method does not prompt.
    func deletePermanently(id: String) async {
        guard let client else { return }
        do {
            try await client.deleteNote(id: id, hard: true)
            allNotes.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Toggle the pin state of a note. Updates local state optimistically
    /// on success so the list re-buckets without waiting for a refresh.
    func togglePin(id: String) async {
        guard let client, let note = allNotes.first(where: { $0.id == id }) else { return }
        do {
            let updated = try await client.updateNote(id: id, NoteUpdate(pinned: !note.pinned))
            try? await store.upsertServerNote(updated)
            await reloadFromStore()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Save an edited body back to local storage and queue a server PATCH.
    /// Returns immediately after the local write so the UI can flip to
    /// "Saved" without waiting on the network. The PATCH runs in the
    /// background; failure surfaces via `errorMessage`.
    func saveBody(_ newBody: String, noteId: String? = nil) async {
        let id = noteId ?? selectedId
        guard let id else { return }
        do {
            try await store.markDirty(noteId: id, body: newBody, title: nil)
            await reloadFromStore()
            schedulePush()
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Internals

    private func reloadFromStore() async {
        do {
            let snap = try await store.snapshot()
            self.allNotes = snap.notes
            self.folders = snap.folders
            self.tags = snap.tags
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func refreshInBackground() async {
        guard let sync else { return }
        do {
            _ = try await sync.syncOnce()
            await reloadFromStore()
        } catch {
            // Background sync failures are logged but not surfaced — the
            // user's action already succeeded server-side.
            errorMessage = "\(error)"
        }
    }

    /// Coalesce multiple rapid edits into a single push. The editor
    /// debounces saves at 600ms; this makes sure two saves in flight don't
    /// race for the same note.
    private func schedulePush() {
        pushTask?.cancel()
        guard let sync else { return }
        pushTask = Task { [weak self] in
            // Tiny delay so a burst of `saveBody` calls coalesces into one
            // pass through the dirty queue.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                _ = try await sync.pushDirty()
                await self?.reloadFromStore()
            } catch {
                await MainActor.run { self?.errorMessage = "\(error)" }
            }
        }
    }

    /// Recompute `notes` (the displayed list) from `allNotes` based on the
    /// active sidebar selection. Selection-change cost is just an in-memory
    /// filter — no network, no SQLite.
    private func recomputeFilteredNotes() {
        let filtered: [Note]
        switch sidebarSelection {
        case .allNotes:
            filtered = allNotes.filter { $0.trashedAt == nil }
        case .pinned:
            filtered = allNotes.filter { $0.trashedAt == nil && $0.pinned }
        case .folder(let id):
            filtered = allNotes.filter { $0.trashedAt == nil && $0.folderId == id }
        case .recentlyDeleted:
            filtered = allNotes.filter { $0.trashedAt != nil }
        }
        notes = filtered
    }

    /// Look up a note in the local cache that may not yet be in `allNotes`
    /// (e.g., a secondary window opened by id before sync caught up).
    func cachedNote(id: String) async -> Note? {
        try? await store.fetchNote(id: id)
    }

    private func rebuildNoteCaches() {
        notesById = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        noteBuckets = NoteBucket.group(notes)
    }

    private func rebuildFolderCaches() {
        folderNamesById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    }
}
