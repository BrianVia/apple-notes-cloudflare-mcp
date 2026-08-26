import SwiftUI
import AppKit

/// One block-type transformation a user can pick from the `/` menu.
struct SlashOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    /// Short text icon rendered in a rounded square on the left, Notion-style.
    /// Use iconSymbol instead for SF Symbol rendering.
    let iconText: String?
    let iconSymbol: String?
    /// Right-aligned markdown syntax hint (e.g., `#`, `##`, `1.`).
    let shortcutHint: String
    /// The markdown prefix to prepend to the line when this option is picked.
    /// Use `""` to clear any existing prefix (i.e., convert to plain body).
    let replacement: String

    init(
        id: String,
        title: String,
        subtitle: String,
        iconText: String? = nil,
        iconSymbol: String? = nil,
        shortcutHint: String,
        replacement: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconText = iconText
        self.iconSymbol = iconSymbol
        self.shortcutHint = shortcutHint
        self.replacement = replacement
    }
}

/// A named group of options in the slash menu (e.g., "Suggested",
/// "Basic blocks") — matches Notion's pattern.
struct SlashGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let options: [SlashOption]
}

extension SlashOption {
    /// All available block transformations, organized into Notion-style groups.
    static let groups: [SlashGroup] = [
        .init(id: "suggested", title: "Suggested", options: [
            .init(id: "h1", title: "Heading 1",     subtitle: "Large section heading",
                  iconText: "H1", shortcutHint: "#",     replacement: "# "),
            .init(id: "h2", title: "Heading 2",     subtitle: "Medium section heading",
                  iconText: "H2", shortcutHint: "##",    replacement: "## "),
            .init(id: "bulleted", title: "Bulleted List", subtitle: "Create a simple bulleted list",
                  iconSymbol: "list.bullet", shortcutHint: "-", replacement: "- "),
            .init(id: "checklist", title: "Checklist",    subtitle: "Track tasks with a to-do list",
                  iconSymbol: "checklist", shortcutHint: "[ ]", replacement: "- [ ] "),
        ]),
        .init(id: "basic", title: "Basic blocks", options: [
            .init(id: "body", title: "Text",         subtitle: "Plain body text",
                  iconSymbol: "textformat",       shortcutHint: "",      replacement: ""),
            .init(id: "h1b", title: "Heading 1",     subtitle: "Large section heading",
                  iconText: "H1", shortcutHint: "#",     replacement: "# "),
            .init(id: "h2b", title: "Heading 2",     subtitle: "Medium section heading",
                  iconText: "H2", shortcutHint: "##",    replacement: "## "),
            .init(id: "h3",  title: "Heading 3",     subtitle: "Small section heading",
                  iconText: "H3", shortcutHint: "###",   replacement: "### "),
            // Markdown supports `####`+, but our renderer currently only
            // styles three distinct heading sizes — showing H4–H6 here
            // would offer visually-identical options. Revisit if/when the
            // storage adds more levels.
            .init(id: "bulletedb", title: "Bulleted List", subtitle: "Simple bulleted list",
                  iconSymbol: "list.bullet",      shortcutHint: "-",     replacement: "- "),
            .init(id: "numbered",  title: "Numbered List", subtitle: "Ordered list",
                  iconSymbol: "list.number",      shortcutHint: "1.",    replacement: "1. "),
            .init(id: "checklistb", title: "Checklist",   subtitle: "Tasks with checkboxes",
                  iconSymbol: "checklist",        shortcutHint: "[ ]",   replacement: "- [ ] "),
            .init(id: "quote",  title: "Quote",           subtitle: "Block quote",
                  iconSymbol: "text.quote",       shortcutHint: ">",     replacement: "> "),
            .init(id: "code",   title: "Code",            subtitle: "Inline code span",
                  iconSymbol: "chevron.left.slash.chevron.right", shortcutHint: "`", replacement: "`"),
            .init(id: "codeblock", title: "Code Block",   subtitle: "Fenced code block",
                  iconSymbol: "curlybraces",      shortcutHint: "```",   replacement: "```\n"),
            .init(id: "divider", title: "Divider",        subtitle: "Horizontal rule",
                  iconSymbol: "minus",            shortcutHint: "---",   replacement: "---\n"),
        ]),
    ]

    /// Flat list — used to match against filter text.
    static let all: [SlashOption] = groups.flatMap { $0.options }
}

/// State shared between the NSPopover host and the SwiftUI content view.
@MainActor
final class SlashMenuState: ObservableObject {
    @Published var filter: String = ""
    @Published var selectedIndex: Int = 0

    var filteredGroups: [SlashGroup] {
        guard !filter.isEmpty else { return SlashOption.groups }
        let f = filter
        return SlashOption.groups.compactMap { group in
            let opts = group.options.filter { option in
                option.title.localizedCaseInsensitiveContains(f)
                    || option.id.localizedCaseInsensitiveContains(f)
                    || option.shortcutHint.localizedCaseInsensitiveContains(f)
            }
            return opts.isEmpty ? nil : SlashGroup(id: group.id, title: group.title, options: opts)
        }
    }

    /// Flat list of all options in filtered order, for arrow-key traversal.
    var filteredOptions: [SlashOption] { filteredGroups.flatMap { $0.options } }

    func reset() {
        filter = ""
        selectedIndex = 0
    }

    func selectNext() {
        let count = filteredOptions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }

    func selectPrevious() {
        let count = filteredOptions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    func currentOption() -> SlashOption? {
        let f = filteredOptions
        guard !f.isEmpty else { return nil }
        return f[min(selectedIndex, f.count - 1)]
    }
}

/// The popover body. Mirrors Notion's structure: grouped sections, subtle
/// gray hover (not accent-blue), right-aligned markdown hint, bottom
/// "Close menu esc" footer.
struct SlashMenuContent: View {
    @ObservedObject var state: SlashMenuState
    let onPick: (SlashOption) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.filteredOptions.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.filteredGroups.enumerated()), id: \.element.id) { _, group in
                            sectionHeader(group.title)
                            ForEach(group.options) { option in
                                row(option: option, selected: option.id == state.currentOption()?.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(option) }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
            }
            Divider()
            footer
        }
        .frame(width: 300)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(option: SlashOption, selected: Bool) -> some View {
        HStack(spacing: 10) {
            optionIcon(option)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(option.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !option.shortcutHint.isEmpty {
                Text(option.shortcutHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
        )
    }

    @ViewBuilder
    private func optionIcon(_ option: SlashOption) -> some View {
        if let text = option.iconText {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        } else if let symbol = option.iconSymbol {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        } else {
            Color.clear.frame(width: 28, height: 28)
        }
    }

    private var footer: some View {
        HStack {
            Button("Close menu", action: onClose)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("esc")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
