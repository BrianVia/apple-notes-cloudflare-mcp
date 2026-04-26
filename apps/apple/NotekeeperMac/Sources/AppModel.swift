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
@MainActor
final class AppModel: ObservableObject {
    @Published var client: APIClient?
    @Published var endpoint: String = "https://notekeeper-prod.brian-via.workers.dev"
    @Published var apiKey: String = ""
    @Published var notes: [Note] = [] {
        didSet { rebuildNoteCaches() }
    }
    @Published var folders: [Folder] = [] {
        didSet { rebuildFolderCaches() }
    }
    @Published private(set) var noteBuckets: [NoteBucket] = []
    @Published var sidebarSelection: SidebarSelection = .allNotes
    @Published var selectedId: String?
    @Published var status: String = "Disconnected"
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false

    private let credentials = KeychainCredentialStore()
    private var notesById: [String: Note] = [:]
    private var folderNamesById: [String: String] = [:]

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
            status = "Connected"
            try? credentials.save(Credential(endpoint: url, apiKey: apiKey))
            await refresh()
        } catch {
            client = nil
            status = "Disconnected"
            errorMessage = "\(error)"
        }
    }

    func disconnect() {
        client = nil
        notes = []
        folders = []
        selectedId = nil
        status = "Disconnected"
        try? credentials.delete()
    }

    func refresh() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            async let foldersTask = client.listFolders()
            async let notesTask = client.listNotes(queryForCurrentSelection)
            let (fetchedFolders, noteResponse) = try await (foldersTask, notesTask)
            folders = fetchedFolders
            notes = filterForCurrentSelection(noteResponse.notes)
            if let selectedId, !notes.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func selectSidebar(_ selection: SidebarSelection) async {
        sidebarSelection = selection
        selectedId = nil
        await refresh()
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
            notes.insert(note, at: 0)
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
            notes.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
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
            notes.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Toggle the pin state of a note. Updates local state optimistically
    /// on success so the list re-buckets without waiting for a refresh.
    func togglePin(id: String) async {
        guard let client, let note = notes.first(where: { $0.id == id }) else { return }
        do {
            let updated = try await client.updateNote(id: id, NoteUpdate(pinned: !note.pinned))
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i] = updated
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Save an edited body back to the API. For now the whole body is sent
    /// as a PATCH — once CRDT sync lands, this becomes a Y.Doc update.
    func saveBody(_ newBody: String, noteId: String? = nil) async {
        guard let client else { return }
        let id = noteId ?? selectedId
        guard let id else { return }
        do {
            let updated = try await client.updateNote(id: id, NoteUpdate(body: newBody))
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i] = updated
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: - Filtering helpers

    /// Server-side query for the active sidebar selection. `pinned` isn't a
    /// server filter yet; we post-filter in `filterForCurrentSelection`.
    private var queryForCurrentSelection: APIClient.NoteListQuery {
        switch sidebarSelection {
        case .allNotes, .pinned:
            return .init()
        case .folder(let id):
            return .init(folderId: id)
        case .recentlyDeleted:
            return .init(trashed: true)
        }
    }

    /// Apply any client-side refinements the server can't express.
    private func filterForCurrentSelection(_ notes: [Note]) -> [Note] {
        switch sidebarSelection {
        case .pinned:
            return notes.filter { $0.pinned }
        case .allNotes, .folder, .recentlyDeleted:
            return notes
        }
    }

    private func rebuildNoteCaches() {
        notesById = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        noteBuckets = NoteBucket.group(notes)
    }

    private func rebuildFolderCaches() {
        folderNamesById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    }
}
