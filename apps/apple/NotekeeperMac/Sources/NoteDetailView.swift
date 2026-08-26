import SwiftUI
import NotekeeperCore

/// Right column. Centered metadata line on top, plain markdown editor
/// below. Inline markdown rendering lands in Phase 3; for now the editor
/// shows raw markdown in SF Pro (not monospaced — see Theme.Font.editorBody).
struct NoteDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let note = model.selectedNote {
                EditorView(
                    noteId: note.id,
                    initialBody: note.body,
                    metadataLabel: metadataLabel(for: note),
                    onSave: { body in await model.saveBody(body, noteId: note.id) }
                )
                // Rekey on note change so @State gets fresh values.
                .id(note.id)
            } else {
                ContentUnavailableView(
                    "No note selected",
                    systemImage: "square.and.pencil",
                    description: Text("Pick one from the list or press ⌘N.")
                )
            }
        }
    }

    private func metadataLabel(for note: Note) -> String {
        note.updatedAt.formatted(date: .long, time: .shortened)
    }
}

/// Shared editor chrome — centered date row, title, body. Used both in the
/// main window and the per-note secondary window.
struct EditorView: View {
    let noteId: String
    let initialBody: String
    let metadataLabel: String
    let onSave: @MainActor (String) async -> Void

    @EnvironmentObject private var bus: EditorCommandBus
    @State private var draftBody: String = ""
    @State private var lastSavedBody: String = ""
    @State private var autosaveTask: Task<Void, Never>?
    @State private var saving = false

    /// How long after the user stops typing before we PATCH. Apple Notes
    /// saves continuously; once CRDT sync lands (Phase 7) this goes away
    /// entirely and every keystroke flows as a Y.Doc update.
    private let autosaveDelay: Duration = .milliseconds(600)

    var body: some View {
        VStack(spacing: 0) {
            Text(metadataLabel)
                .font(Theme.Font.editorMetadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 6)

            MarkdownTextView(text: $draftBody, bus: bus)
                .padding(.horizontal, 48)
                .padding(.vertical, 4)
                .onChange(of: draftBody) { _, _ in scheduleAutosave() }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .background {
            Button("") { saveNow() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear {
            draftBody = initialBody
            lastSavedBody = initialBody
        }
        .onDisappear {
            autosaveTask?.cancel()
            if draftBody != lastSavedBody { saveNow() }
        }
    }

    private var footer: some View {
        HStack {
            if saving {
                Text("Saving…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if draftBody != lastSavedBody {
                Text("Unsaved changes")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Text("Saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Debounced autosave: each keystroke cancels the previous pending
    /// save and starts a new 600ms timer. ⌘S still works via `saveNow()`.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await performSave()
        }
    }

    private func saveNow() {
        autosaveTask?.cancel()
        Task { @MainActor in await performSave() }
    }

    private func performSave() async {
        let body = draftBody
        guard body != lastSavedBody else { return }
        saving = true
        await onSave(body)
        lastSavedBody = body
        saving = false
    }
}
