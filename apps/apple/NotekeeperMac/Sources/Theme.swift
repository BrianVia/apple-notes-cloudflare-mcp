import SwiftUI

/// Design tokens — extracted from live Notes.app reference. Values here
/// drive the whole UI so dark-mode + resolution-independence stays consistent.
/// Anything that reads "the default SwiftUI behavior is wrong for Notes" lives here.
enum Theme {
    // MARK: - Colors

    /// Warm sand tint that fills the actively-focused selected row in the note list.
    /// Default SwiftUI selection (`Color.accentColor`) is blue — wrong for Notes.
    static let activeSelection = Color(red: 254/255, green: 236/255, blue: 194/255)

    /// Muted gray for rows that are logically selected but the list doesn't have
    /// keyboard focus (e.g., focus has moved to a toolbar popover or the editor).
    /// Matches `NSColor.unemphasizedSelectedContentBackgroundColor` visually.
    static let inactiveSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    /// Yellow dot used for the pin indicator in note-list rows.
    static let pinDot = Color(red: 254/255, green: 206/255, blue: 79/255)

    /// Tint used on the selected folder's glyph in the sidebar (Notes draws it orange).
    static let selectedFolderGlyph = Color(red: 246/255, green: 182/255, blue: 62/255)

    // MARK: - Typography
    //
    // Use `.system(...)` — SF Pro is the default on macOS, and these sizes are
    // calibrated against a live Notes window. Don't monospace the editor body;
    // Notes uses SF Pro regular except for explicit Monostyled blocks.

    enum Font {
        // Sidebar
        static let sidebarRow = SwiftUI.Font.system(size: 13)
        static let sidebarRowSelected = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let sidebarSectionHeader = SwiftUI.Font.system(size: 12)
        static let sidebarCount = SwiftUI.Font.system(size: 12)

        // Note list column header
        static let listColumnHeader = SwiftUI.Font.system(size: 17, weight: .bold)
        static let listColumnSubtitle = SwiftUI.Font.system(size: 12)
        static let listSectionHeader = SwiftUI.Font.system(size: 15, weight: .semibold)

        // Note list cell
        static let cellTitle = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let cellMeta = SwiftUI.Font.system(size: 12)
        static let cellFolderFooter = SwiftUI.Font.system(size: 11)

        // Editor
        static let editorMetadata = SwiftUI.Font.system(size: 12)
        static let editorTitle = SwiftUI.Font.system(size: 28, weight: .bold)
        static let editorHeading = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let editorSubheading = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let editorBody = SwiftUI.Font.system(size: 16)
    }

    // MARK: - Layout

    enum Layout {
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarIdealWidth: CGFloat = 210
        static let sidebarMaxWidth: CGFloat = 240

        static let noteListMinWidth: CGFloat = 260
        static let noteListIdealWidth: CGFloat = 310

        static let sidebarRowHeight: CGFloat = 28
        static let noteListRowMinHeight: CGFloat = 68

        static let rowCornerRadius: CGFloat = 6
        static let rowHorizontalInset: CGFloat = 4
    }
}
