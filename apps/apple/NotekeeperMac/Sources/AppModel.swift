import Foundation
import NotekeeperCore

/// Single source of truth for the app UI. All mutations run on the main
/// actor so SwiftUI views can observe without extra synchronization.
@MainActor
final class AppModel: ObservableObject {
    @Published var client: APIClient?
    @Published var endpoint: String = "https://notekeeper.brian-via.workers.dev"
    @Published var apiKey: String = ""
    @Published var notes: [Note] = []
    @Published var selectedId: String?
    @Published var status: String = "Disconnected"
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false

    private let credentials = KeychainCredentialStore()

    var selectedNote: Note? {
        notes.first { $0.id == selectedId }
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
        selectedId = nil
        status = "Disconnected"
        try? credentials.delete()
    }

    func refresh() async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.listNotes()
            notes = response.notes
            if let selectedId, !notes.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func createDraft() async {
        guard let client else { return }
        do {
            let note = try await client.createNote(NoteCreate(title: "Untitled", body: "# Untitled\n\n"))
            notes.insert(note, at: 0)
            selectedId = note.id
        } catch {
            errorMessage = "\(error)"
        }
    }

    func trashSelected() async {
        guard let client, let id = selectedId else { return }
        do {
            try await client.deleteNote(id: id)
            notes.removeAll { $0.id == id }
            selectedId = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Save an edited body back to the API. For now the whole body is sent
    /// as a PATCH — once CRDT sync lands, this becomes a Y.Doc update.
    func saveBody(_ newBody: String) async {
        guard let client, let id = selectedId else { return }
        do {
            let updated = try await client.updateNote(id: id, NoteUpdate(body: newBody))
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i] = updated
            }
        } catch {
            errorMessage = "\(error)"
        }
    }
}
