import SwiftUI
import NotekeeperCore

/// Middle column. Column header + section-bucketed list of notes.
struct NoteListView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            listBody
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private var columnHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentFilterLabel)
                    .font(Theme.Font.listColumnHeader)
                Text("\(model.notes.count) note\(model.notes.count == 1 ? "" : "s")")
                    .font(Theme.Font.listColumnSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Sort By Date Edited") {}
                Button("View as Gallery") {}
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var listBody: some View {
        if model.client == nil {
            ContentUnavailableView(
                "Not connected",
                systemImage: "link.badge.plus",
                description: Text("Connect from the sidebar to get started.")
            )
        } else if model.notes.isEmpty {
            ContentUnavailableView(
                "No notes",
                systemImage: "note.text",
                description: Text("⌘N to create one.")
            )
        } else {
            List(selection: Binding(
                get: { model.selectedId },
                set: { model.selectedId = $0 }
            )) {
                ForEach(model.noteBuckets, id: \.title) { bucket in
                    Section {
                        ForEach(bucket.notes) { note in
                            NoteRowView(
                                note: note,
                                isSelected: model.selectedId == note.id,
                                listFocused: listFocused,
                                folderLabel: model.folderName(for: note.folderId)
                            )
                                .tag(note.id)
                                .listRowSeparator(.visible)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                // Suppress SwiftUI's default blue selection tint —
                                // the row paints its own yellow/gray fill on top.
                                .listRowBackground(Color.clear)
                                .noteContextMenu(for: note)
                        }
                    } header: {
                        Text(bucket.title)
                            .font(Theme.Font.listSectionHeader)
                            .padding(.top, 6)
                    }
                }
            }
            .listStyle(.plain)
            .focused($listFocused)
            .scrollContentBackground(.hidden)
            .refreshable { await model.refresh() }
        }
    }
}

/// One cell in the note list — three lines: title, date + preview, folder footer.
private struct NoteRowView: View, Equatable {
    let note: Note
    let isSelected: Bool
    let listFocused: Bool
    let folderLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Yellow pin dot gutter so titles align whether pinned or not.
            Circle()
                .fill(note.pinned ? Theme.pinDot : .clear)
                .frame(width: 6, height: 6)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(Theme.Font.cellTitle)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(dateLabel(for: note.updatedAt))
                        .foregroundStyle(.secondary)
                    Text(preview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(Theme.Font.cellMeta)

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(folderLabel)
                }
                .font(Theme.Font.cellFolderFooter)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Layout.rowCornerRadius)
                .fill(selectionFill)
        )
        .contentShape(Rectangle())
    }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        return listFocused ? Theme.activeSelection : Theme.inactiveSelection
    }

    private var displayTitle: String {
        note.title.isEmpty ? "Untitled" : note.title
    }

    private var preview: String {
        let body = note.body
        let firstLine = body.components(separatedBy: .newlines).first ?? ""
        // Strip markdown header markers + a title duplicate.
        var rest = body.drop { !$0.isNewline }
        if rest.first?.isNewline == true { rest = rest.dropFirst() }
        let afterTitle = String(rest)
        let cleaned = afterTitle
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "- [ ]", with: "")
            .replacingOccurrences(of: "- [x]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = cleaned.isEmpty ? firstLine : cleaned
        return String(source.prefix(140))
    }

    private func dateLabel(for date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month().day().year(.twoDigits))
    }
}

/// Logical grouping of notes by "when" — the section headers the Notes app uses.
struct NoteBucket {
    let title: String
    let notes: [Note]

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yyyy")
        return formatter
    }()

    static func group(_ notes: [Note], now: Date = Date()) -> [NoteBucket] {
        var pinned: [Note] = []
        var today: [Note] = []
        var yesterday: [Note] = []
        var last7: [Note] = []
        var last30: [Note] = []
        var monthOrder: [String] = []
        var monthBuckets: [String: [Note]] = [:]
        var yearOrder: [String] = []
        var yearBuckets: [String: [Note]] = [:]

        let cal = Calendar.current
        let nowYear = cal.component(.year, from: now)

        for note in notes {
            if note.pinned {
                pinned.append(note)
                continue
            }
            let date = note.updatedAt
            if cal.isDateInToday(date) { today.append(note); continue }
            if cal.isDateInYesterday(date) { yesterday.append(note); continue }
            let daysAgo = cal.dateComponents([.day], from: date, to: now).day ?? 0
            if daysAgo < 7 { last7.append(note); continue }
            if daysAgo < 30 { last30.append(note); continue }
            let year = cal.component(.year, from: date)
            if year == nowYear {
                let key = monthFormatter.string(from: date)
                if monthBuckets[key] == nil {
                    monthOrder.append(key)
                    monthBuckets[key] = []
                }
                monthBuckets[key, default: []].append(note)
            } else {
                let key = yearFormatter.string(from: date)
                if yearBuckets[key] == nil {
                    yearOrder.append(key)
                    yearBuckets[key] = []
                }
                yearBuckets[key, default: []].append(note)
            }
        }

        var out: [NoteBucket] = []
        if !pinned.isEmpty { out.append(.init(title: "Pinned", notes: pinned)) }
        if !today.isEmpty { out.append(.init(title: "Today", notes: today)) }
        if !yesterday.isEmpty { out.append(.init(title: "Yesterday", notes: yesterday)) }
        if !last7.isEmpty { out.append(.init(title: "Previous 7 Days", notes: last7)) }
        if !last30.isEmpty { out.append(.init(title: "Previous 30 Days", notes: last30)) }
        for key in monthOrder {
            if let notes = monthBuckets[key] {
                out.append(.init(title: key, notes: notes))
            }
        }
        for key in yearOrder {
            if let notes = yearBuckets[key] {
                out.append(.init(title: key, notes: notes))
            }
        }
        return out
    }
}
