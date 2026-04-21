import SwiftUI
import NotekeeperCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            NoteListView()
                .frame(minWidth: 260)
        } detail: {
            NoteDetailView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ConnectionControls()
            }
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
}

struct ConnectionControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConnectSheet = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.client != nil ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.client == nil {
                Button("Connect") { showConnectSheet = true }
            } else {
                Button("Disconnect") { model.disconnect() }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectSheet()
        }
    }
}

struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Notekeeper")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Endpoint").font(.caption).foregroundStyle(.secondary)
                TextField("https://notekeeper.example.workers.dev", text: $model.endpoint)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.caption).foregroundStyle(.secondary)
                SecureField("nk_live_…", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    Task {
                        await model.connect()
                        if model.client != nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct NoteListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedId },
            set: { model.selectedId = $0 }
        )) {
            if model.client == nil {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "link.badge.plus",
                    description: Text("Click Connect in the toolbar.")
                )
            } else if model.notes.isEmpty {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "note.text",
                    description: Text("⌘N to create one.")
                )
            } else {
                ForEach(model.notes) { note in
                    NoteRowView(note: note).tag(note.id)
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await model.refresh()
        }
    }
}

struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            Text(snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var snippet: String {
        let stripped = note.body
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(120))
    }
}

struct NoteDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draftBody: String = ""
    @State private var lastSavedBody: String = ""
    @State private var lastLoadedId: String?

    var body: some View {
        Group {
            if let note = model.selectedNote {
                editor(for: note)
            } else {
                ContentUnavailableView(
                    "No note selected",
                    systemImage: "square.and.pencil",
                    description: Text("Pick one from the sidebar or press ⌘N.")
                )
            }
        }
    }

    @ViewBuilder
    private func editor(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.title2).bold()
                Spacer()
                Text(note.updatedAt, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            TextEditor(text: $draftBody)
                .font(.body.monospaced())
                .padding(8)
                .onChange(of: note.id) { _, _ in
                    draftBody = note.body
                    lastSavedBody = note.body
                    lastLoadedId = note.id
                }
                .onAppear {
                    if lastLoadedId != note.id {
                        draftBody = note.body
                        lastSavedBody = note.body
                        lastLoadedId = note.id
                    }
                }
                .onSubmit {
                    save()
                }
            HStack {
                if draftBody != lastSavedBody {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draftBody == lastSavedBody)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func save() {
        let body = draftBody
        Task {
            await model.saveBody(body)
            lastSavedBody = body
        }
    }
}
