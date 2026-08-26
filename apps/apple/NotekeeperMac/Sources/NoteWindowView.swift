import SwiftUI
import NotekeeperCore

/// Standalone window for a single note. No sidebar, no list — just the
/// editor. Triggered by ⌥⌘N or the "Open Note in New Window" command.
/// Reuses `EditorView` from `NoteDetailView.swift` so changes stay in sync.
struct NoteWindowView: View {
    @EnvironmentObject private var model: AppModel
    /// Per-window bus — secondary windows get their own so a keyboard
    /// shortcut fired in one window doesn't retarget another window's editor.
    @StateObject private var editorBus = EditorCommandBus()
    let noteId: String

    @State private var note: Note?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let note {
                EditorView(
                    noteId: note.id,
                    initialBody: note.body,
                    metadataLabel: metadataLabel(for: note),
                    onSave: { body in
                        await model.saveBody(body, noteId: note.id)
                    }
                )
                .environmentObject(editorBus)
                .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't open note",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task { await load() }
    }

    private func load() async {
        // 1. In-memory list (active filter)
        if let existing = model.notes.first(where: { $0.id == noteId }) {
            note = existing
            return
        }
        // 2. Local SQLite cache — covers trashed notes and ones outside the
        // current filter without a network round-trip.
        if let cached = await model.cachedNote(id: noteId) {
            note = cached
            return
        }
        // 3. Last resort: ask the server.
        guard let client = model.client else {
            loadError = "Not connected"
            return
        }
        do {
            note = try await client.getNote(id: noteId)
        } catch {
            loadError = "\(error)"
        }
    }

    private func metadataLabel(for note: Note) -> String {
        note.updatedAt.formatted(date: .long, time: .shortened)
    }
}
