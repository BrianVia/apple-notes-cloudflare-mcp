import SwiftUI
import NotekeeperCore

@main
struct NotekeeperMacApp: App {
    @StateObject private var model = AppModel()
    /// One bus per primary window keeps toolbar clicks scoped to the editor
    /// in that window. Secondary per-note windows create their own.
    @StateObject private var editorBus = EditorCommandBus()

    var body: some Scene {
        WindowGroup("Notekeeper") {
            RootView()
                .environmentObject(model)
                .environmentObject(editorBus)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await model.loadStoredCredentialsAndConnect()
                }
        }
        // Hidden titlebar lets the sidebar's `.ultraThinMaterial` extend all
        // the way up through the traffic-light row. Without this the app
        // looks like any other 3-column SwiftUI app instead of Notes.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    Task { await model.createDraft() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.client == nil)
            }
        }

        // Per-note secondary scene — ⌥⌘N and the "Open Note in New Window"
        // command spawn one of these. `Note.ID` is a String, which is both
        // Hashable and Codable, so SwiftUI can round-trip it across the
        // window-state restoration boundary.
        WindowGroup("Note", for: Note.ID.self) { $noteId in
            if let noteId {
                NoteWindowView(noteId: noteId)
                    .environmentObject(model)
                    .frame(minWidth: 560, minHeight: 400)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}


