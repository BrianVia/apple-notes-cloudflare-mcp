import SwiftUI
import NotekeeperCore

/// Three-column shell. The sidebar's `.ultraThinMaterial` reads up through
/// the hidden titlebar, giving the classic Apple Notes translucency.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var editorBus: EditorCommandBus
    @Environment(\.openWindow) private var openWindow
    @State private var searchText: String = ""

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Theme.Layout.sidebarMinWidth,
                    ideal: Theme.Layout.sidebarIdealWidth,
                    max: Theme.Layout.sidebarMaxWidth
                )
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(
                    min: Theme.Layout.noteListMinWidth,
                    ideal: Theme.Layout.noteListIdealWidth
                )
        } detail: {
            NoteDetailView()
        }
        // Keep the toolbar visible but transparent so it reads as a single
        // unified surface with the sidebar's ultraThinMaterial below. This
        // is the Apple Notes look: traffic lights + toolbar items on one row,
        // sidebar material bleeding up behind the whole thing.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar { mainToolbar }
        .background {
            // Hidden shortcut handlers. They live here instead of in
            // .commands because CommandGroup content can't read
            // @EnvironmentObject from the WindowGroup.
            ZStack {
                Button("") {
                    if let id = model.selectedId {
                        openWindow(value: id)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.client == nil)

                // Inline-styling shortcuts. They used to live in the Format
                // menu; moved here so the menu can stay aligned with the
                // slash menu (which is purely block-level).
                Button("") { editorBus.send(.toggleInline(.bold)) }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(model.selectedId == nil)

                Button("") { editorBus.send(.toggleInline(.italic)) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model.selectedId == nil)

                Button("") { editorBus.send(.insertLink) }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.selectedId == nil)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Window toolbar modeled after Apple Notes. Left cluster (near the
    /// note-list column) holds compose; center cluster holds format tools
    /// that operate on the editor; right cluster holds share/more/search.
    ///
    /// Every format action routes through `editorBus` — the active
    /// `MarkdownTextView` subscribes in its Coordinator and applies the
    /// command to whatever the caret/selection is on.
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.createDraft() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New Note (⌘N)")
            .disabled(model.client == nil)
        }

        ToolbarItemGroup(placement: .principal) {
            formatMenu

            Button {
                editorBus.send(.setBlock("- [ ] "))
            } label: {
                Image(systemName: "checklist")
            }
            .help("Checklist (⇧⌘L)")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.selectedId == nil)

            Button {
                editorBus.send(.insertTable)
            } label: {
                Image(systemName: "tablecells")
            }
            .help("Table")
            .disabled(model.selectedId == nil)

            Button {
                editorBus.send(.insertAttachment)
            } label: {
                Image(systemName: "paperclip")
            }
            .help("Attachment")
            .disabled(model.selectedId == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let note = model.selectedNote {
                ShareLink(item: note.body,
                          preview: SharePreview(note.title.isEmpty ? "Untitled" : note.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share")
            }

            Menu {
                Button("Copy Link", systemImage: "link") {}.disabled(true)
                Button("Move to Folder…", systemImage: "folder") {}.disabled(true)
                Divider()
                if let id = model.selectedId {
                    Button("Move to Trash", systemImage: "trash") {
                        Task { await model.trash(id: id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More actions")

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .keyboardShortcut("f", modifiers: .command)
        }
    }

    /// Format menu — mirrors the `/`-menu so there's one taxonomy of block
    /// types across the app. Rendered as native macOS menu sections with
    /// the right-aligned syntax hint (#, ##, -, [ ], 1.) as a monospaced
    /// trailing label, so discoverability carries over from slash to click.
    @ViewBuilder
    private var formatMenu: some View {
        Menu {
            ForEach(SlashOption.groups) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Button {
                            editorBus.apply(option)
                        } label: {
                            if let symbol = option.iconSymbol {
                                Label(option.title, systemImage: symbol)
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Format")
        .disabled(model.selectedId == nil)
    }
}
