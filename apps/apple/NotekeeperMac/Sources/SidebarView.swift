import SwiftUI
import NotekeeperCore

/// Leftmost column. Background material extends up through the hidden
/// titlebar so it reads up past the traffic lights.
///
/// Phase 1 ships a minimal set of static rows + a placeholder for folders.
/// Phase 4 replaces the placeholder with the real folder tree + counts.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: selectionBinding) {
            Section("Notes") {
                sidebarRow(.allNotes, icon: "tray.full", label: "All Notes")
                sidebarRow(.pinned, icon: "pin", label: "Pinned")
            }

            Section("Folders") {
                if model.folders.isEmpty {
                    Text("No folders")
                        .font(Theme.Font.sidebarSectionHeader)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.folders) { folder in
                        sidebarRow(
                            .folder(id: folder.id),
                            icon: "folder",
                            label: folder.name
                        )
                    }
                }
            }

            Section {
                sidebarRow(.recentlyDeleted, icon: "trash", label: "Recently Deleted")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)           // let material show through
        .background(.ultraThinMaterial)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter()
        }
    }

    /// The `List`'s selection type has to be `Optional<SidebarSelection>` to
    /// avoid spurious deselection on click. When the binding reports a new
    /// value, fire an async refresh of the note list.
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { newValue in
                guard let newValue, newValue != model.sidebarSelection else { return }
                model.selectSidebar(newValue)
            }
        )
    }

    @ViewBuilder
    private func sidebarRow(_ selection: SidebarSelection, icon: String, label: String) -> some View {
        let isSelected = model.sidebarSelection == selection
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected && isFolder(selection) ? Theme.selectedFolderGlyph : .secondary)
                .frame(width: 16)
            Text(label)
                .font(isSelected ? Theme.Font.sidebarRowSelected : Theme.Font.sidebarRow)
        }
        .tag(selection)
    }

    private func isFolder(_ selection: SidebarSelection) -> Bool {
        if case .folder = selection { return true }
        return false
    }
}

/// Sits at the bottom of the sidebar — connection status + connect/disconnect
/// button. Replaces the toolbar-based controls the scaffold had, since we
/// hide the toolbar in Phase 1.
private struct ConnectionFooter: View {
    @EnvironmentObject private var model: AppModel
    @State private var showConnectSheet = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.client != nil ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if model.client == nil {
                Button("Connect") { showConnectSheet = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sheet(isPresented: $showConnectSheet) {
            ConnectSheet()
        }
    }
}

private struct ConnectSheet: View {
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
