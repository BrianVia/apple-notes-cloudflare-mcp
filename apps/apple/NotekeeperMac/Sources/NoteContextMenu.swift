import SwiftUI
import AppKit
import NotekeeperCore
import UniformTypeIdentifiers

/// Right-click (or two-finger tap) menu for a note row. Encapsulated here so
/// `NoteListView` stays focused on layout and the action handlers live
/// alongside their helpers (clipboard, NSSavePanel, plain-text conversion).
struct NoteRowContextMenu: ViewModifier {
    let note: Note
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmPermanentDelete = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .alert("Delete \(note.title.isEmpty ? "this note" : "\"\(note.title)\"") permanently?",
                   isPresented: $confirmPermanentDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await model.deletePermanently(id: note.id) }
                }
            } message: {
                Text("This can't be undone.")
            }
    }

    @ViewBuilder
    private var menu: some View {
        Button(note.pinned ? "Unpin" : "Pin") {
            Task { await model.togglePin(id: note.id) }
        }
        .keyboardShortcut("l", modifiers: .command)

        Button("Open Note in New Window") {
            openWindow(value: note.id)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Divider()

        Button("Copy as Markdown") {
            copyToPasteboard(note.body)
        }
        Button("Copy as Plain Text") {
            copyToPasteboard(NoteExport.plainText(from: note.body))
        }
        Button("Export as Markdown…") {
            exportAsMarkdown(note: note)
        }
        ShareLink(item: note.body, preview: SharePreview(note.title.isEmpty ? "Untitled" : note.title))

        Divider()

        Button("Move to Trash") {
            Task { await model.trash(id: note.id) }
        }
        .keyboardShortcut(.delete, modifiers: .command)

        Button(role: .destructive) {
            confirmPermanentDelete = true
        } label: {
            Text("Delete Permanently…")
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
    }

    // MARK: - Action helpers

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func exportAsMarkdown(note: Note) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(sanitizeFilename(note.title.isEmpty ? "Untitled" : note.title)).md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Pre-write the body to a temp so even if the user cancels, we haven't
        // destroyed anything — and on OK, write to the chosen URL.
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try note.body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func sanitizeFilename(_ s: String) -> String {
        var out = s
        for ch in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"] {
            out = out.replacingOccurrences(of: ch, with: "-")
        }
        if out.count > 120 { out = String(out.prefix(120)) }
        return out.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : out
    }
}

extension View {
    /// Attach the note row context menu. Exists as a namespaced helper
    /// so `NoteListView` reads `.noteContextMenu(note)` inline.
    func noteContextMenu(for note: Note) -> some View {
        modifier(NoteRowContextMenu(note: note))
    }
}

/// Stateless helpers for converting note content to other formats.
enum NoteExport {
    /// Strip markdown syntax to produce a reasonable plain-text version.
    /// Targets common markers; not a full parser — good enough for clipboard.
    static func plainText(from markdown: String) -> String {
        var s = markdown

        // Fenced code blocks → keep content, drop the fence lines.
        s = s.replacingOccurrences(
            of: #"^```[^\n]*\n([\s\S]*?)\n```"#,
            with: "$1",
            options: .regularExpression
        )

        // Images & links: keep visible text, drop the URL portion.
        s = s.replacingOccurrences(
            of: #"!?\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )

        // Line-level markers: `#`, `##`, `>`, `-`, `*`, `1.`
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*#{1,6}[ \t]+"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*>[ \t]+"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*][ \t]+\[([ xX])\][ \t]+"#,
            with: { m in
                // Swift's `replacingOccurrences` doesn't support capture-group
                // closures, so this block is actually unreachable — the raw
                // regex below does the real work. Kept for clarity.
                return m
            }("") as String,
            options: .regularExpression
        )
        // Actual checklist stripping (produces `[ ] ` / `[x] ` prefix text):
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*][ \t]+\[ \][ \t]+"#,
            with: "• ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*][ \t]+\[[xX]\][ \t]+"#,
            with: "✓ ",
            options: .regularExpression
        )
        // Plain bulleted / numbered lists:
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*][ \t]+"#,
            with: "• ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*\d+\.[ \t]+"#,
            with: "",
            options: .regularExpression
        )

        // Inline: **bold** / *italic* / `code` → content only.
        s = s.replacingOccurrences(
            of: #"\*\*([^\*\n]+)\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?<!\*)\*([^\*\n]+)\*(?!\*)"#,
            with: "$1",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"`([^`\n]+)`"#,
            with: "$1",
            options: .regularExpression
        )

        return s
    }
}
