import Foundation
import Combine

/// Formatting commands dispatched from the window toolbar to whichever
/// `MarkdownTextView` is currently hosted in the same window. Each window
/// owns its own bus (see RootView / NoteWindowView) so toolbar clicks only
/// affect that window's editor.
enum EditorCommand {
    /// Replace the current line's block prefix with `prefix`. Pass `""` to
    /// clear an existing prefix (i.e., turn a heading/list back into body).
    case setBlock(String)
    /// Wrap or unwrap the current selection with the marker for `style`.
    case toggleInline(EditorInlineStyle)
    /// Insert a 2×2 markdown table stub at the caret.
    case insertTable
    /// Insert a fenced ```-block at the caret.
    case insertCodeBlock
    /// Insert a horizontal rule (`---`) as a new block at the caret.
    case insertDivider
    /// Show an NSOpenPanel and embed the picked file as markdown.
    case insertAttachment
    /// Insert a markdown link template at the caret.
    case insertLink
}

enum EditorInlineStyle {
    case bold
    case italic
    case code
    case strikethrough

    var marker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .code: return "`"
        case .strikethrough: return "~~"
        }
    }

    /// Placeholder inserted when the user triggers inline styling with an
    /// empty selection, so the caret lands on something visible they can
    /// type over.
    var placeholder: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .code: return "code"
        case .strikethrough: return "text"
        }
    }
}

@MainActor
final class EditorCommandBus: ObservableObject {
    let publisher = PassthroughSubject<EditorCommand, Never>()
    func send(_ cmd: EditorCommand) { publisher.send(cmd) }

    /// Dispatch whatever a `SlashOption` means as a proper `EditorCommand`.
    /// Keeps the toolbar Format menu and the `/`-menu sharing one taxonomy
    /// so adding a block type in `SlashOption.groups` picks it up in both.
    func apply(_ option: SlashOption) {
        // Group IDs `...b` are the Basic-blocks duplicates of the Suggested
        // entries. We treat all heading variants the same way.
        switch option.id {
        case "code":
            send(.toggleInline(.code))
        case "codeblock":
            send(.insertCodeBlock)
        case "divider":
            send(.insertDivider)
        default:
            // Everything else is a line-prefix transformation: `# `, `- `,
            // `- [ ] `, `1. `, `> `, or `""` (Text).
            send(.setBlock(option.replacement))
        }
    }
}
