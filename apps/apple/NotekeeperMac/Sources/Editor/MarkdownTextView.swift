import SwiftUI
import AppKit
import Combine

/// SwiftUI wrapper around an `NSTextView` backed by `MarkdownTextStorage`.
/// Syncs a `Binding<String>` (plain markdown source) and hosts the `/`-menu.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var bus: EditorCommandBus
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(self)
        coord.subscribe(to: bus)
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the storage stack manually so we can plug in our custom
        // NSTextStorage. The init(frame:) convenience on NSTextView builds
        // a default one we can't easily replace.
        let storage = MarkdownTextStorage()
        let layoutManager = ChecklistLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.font = MarkdownStyle.body
        textView.typingAttributes = MarkdownStyle.bodyAttrs
        textView.slashMenuController = context.coordinator.slashMenuController
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false

        // Autoresize inside scroll view.
        textView.minSize = CGSize(width: 0, height: 0)
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.storage = storage

        // Initial content + styling.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.endEditing()
        storage.tokenize(range: NSRange(location: 0, length: (storage.string as NSString).length))

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? EditorTextView else { return }
        // If the bound text was externally changed (e.g. note switched) and
        // differs from our storage, replace the contents.
        if textView.string != text {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.replaceCharacters(in: full, with: text)
            if let storage = textView.textStorage as? MarkdownTextStorage {
                storage.tokenize(range: NSRange(location: 0, length: (storage.string as NSString).length))
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: EditorTextView?
        weak var storage: MarkdownTextStorage?
        let slashMenuController = SlashMenuController()
        private var busCancellable: AnyCancellable?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
            slashMenuController.onCommit = { [weak self] option in
                self?.applySlashOption(option)
            }
            slashMenuController.onFilterChange = { [weak self] filter in
                self?.slashMenuController.state.filter = filter
                self?.slashMenuController.state.selectedIndex = 0
            }
        }

        func subscribe(to bus: EditorCommandBus) {
            busCancellable = bus.publisher.sink { [weak self] cmd in
                self?.handle(cmd)
            }
        }

        private func handle(_ cmd: EditorCommand) {
            switch cmd {
            case .setBlock(let prefix):
                applyBlockPrefix(prefix)
            case .toggleInline(let style):
                toggleInline(style)
            case .insertTable:
                insertBlock("|     |     |\n| --- | --- |\n|     |     |\n")
            case .insertCodeBlock:
                insertBlock("```\n\n```\n", caretLineOffsetFromTop: 1)
            case .insertDivider:
                insertBlock("---\n")
            case .insertAttachment:
                promptForAttachment()
            case .insertLink:
                insertLinkTemplate()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let newValue = textView.string
            if parent.text != newValue {
                parent.text = newValue
            }
            // Update slash menu filter if it's visible.
            if slashMenuController.isVisible, let info = slashMenuController.activeContext {
                let caret = textView.selectedRange().location
                if caret < info.slashLocation {
                    // Caret moved before the `/` → close.
                    slashMenuController.hide()
                } else {
                    let filterRange = NSRange(location: info.slashLocation + 1,
                                              length: caret - info.slashLocation - 1)
                    if filterRange.location + filterRange.length <= (textView.string as NSString).length {
                        let filter = (textView.string as NSString).substring(with: filterRange)
                        slashMenuController.state.filter = filter
                        slashMenuController.state.selectedIndex = 0
                    } else {
                        slashMenuController.hide()
                    }
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let storage else { return }
            storage.caretLocation = textView.selectedRange().location
            // If the slash menu is visible and the caret moved outside its range, close it.
            if slashMenuController.isVisible, let info = slashMenuController.activeContext {
                let caret = textView.selectedRange().location
                if caret < info.slashLocation { slashMenuController.hide() }
            }
        }

        /// Called from EditorTextView when the user types `/` at a valid position.
        func slashTyped(at caret: Int) {
            guard let textView else { return }
            // Valid position: start of line OR preceded by whitespace.
            let str = textView.string as NSString
            let isValid: Bool = {
                guard caret > 0 else { return true }
                let prevRange = NSRange(location: caret - 1, length: 1)
                let ch = str.substring(with: prevRange)
                return ch == "\n" || ch == " " || ch == "\t"
            }()
            guard isValid else { return }
            slashMenuController.state.reset()
            slashMenuController.show(in: textView, slashLocation: caret)
        }

        func applySlashOption(_ option: SlashOption) {
            guard let textView, let info = slashMenuController.activeContext else { return }
            let str = textView.string as NSString
            // Compute the line-prefix range we want to replace. We replace
            // from the start of the current line up to the current caret,
            // which includes `/filter`. Plus we replace any existing markdown
            // prefix on that line so "/h1" rewrites `## Foo` → `# Foo`.
            let caret = textView.selectedRange().location
            let lineRange = str.lineRange(for: NSRange(location: info.slashLocation, length: 0))
            let lineStart = lineRange.location
            let lineContent = str.substring(with: lineRange)
            let existingPrefix = detectExistingPrefix(line: lineContent)

            // Replace from line start to the end of `/filter` with the new prefix.
            let replaceStart = lineStart
            let replaceEnd = caret
            let replaceRange = NSRange(location: replaceStart, length: replaceEnd - replaceStart)

            // If there was a markdown prefix before `/`, strip it by consuming
            // it in the replacement range.
            let finalReplaceRange: NSRange
            if existingPrefix > 0 && existingPrefix < replaceRange.length {
                // The replaceRange already starts at line start, so existing
                // prefix is included in it — nothing extra to do.
                finalReplaceRange = replaceRange
            } else {
                finalReplaceRange = replaceRange
            }

            textView.insertText(option.replacement, replacementRange: finalReplaceRange)
            slashMenuController.hide()
        }

        /// How many characters of markdown prefix (`# `, `- `, `> `, etc.) sit at
        /// the start of `line`? Returns 0 if none.
        private func detectExistingPrefix(line: String) -> Int {
            if line.hasPrefix("### ") { return 4 }
            if line.hasPrefix("## ") { return 3 }
            if line.hasPrefix("# ") { return 2 }
            if line.hasPrefix("- [ ] ") { return 6 }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return 6 }
            if line.hasPrefix("- ") { return 2 }
            if line.hasPrefix("* ") { return 2 }
            if line.hasPrefix("> ") { return 2 }
            return 0
        }

        // MARK: - Checkbox toggle on click

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, url.scheme == "notekeeper-checkbox" {
                toggleChecklist(at: charIndex)
                return true
            }
            return false
        }

        private func toggleChecklist(at charIndex: Int) {
            guard let textView, let storage else { return }
            let str = storage.string as NSString
            let lineRange = str.lineRange(for: NSRange(location: charIndex, length: 0))
            let line = str.substring(with: lineRange)
            guard line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") else { return }
            let newPrefix = line.hasPrefix("- [ ] ") ? "- [x] " : "- [ ] "
            let prefixRange = NSRange(location: lineRange.location, length: 6)
            textView.insertText(newPrefix, replacementRange: prefixRange)
        }

        // MARK: - Toolbar command handlers

        /// Replace whatever markdown prefix currently starts the caret line
        /// with `prefix`. Toggles off when asked to set the same prefix that's
        /// already there — e.g. clicking the Checklist button while already on
        /// a checklist line turns it back into body text.
        private func applyBlockPrefix(_ prefix: String) {
            guard let textView else { return }
            let str = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = str.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = str.substring(with: lineRange)
            let existingLen = detectExistingPrefix(line: line)
            let existing = existingLen > 0
                ? (line as NSString).substring(to: existingLen)
                : ""

            let replacement = (existing == prefix) ? "" : prefix
            let replaceRange = NSRange(location: lineRange.location, length: existingLen)
            textView.insertText(replacement, replacementRange: replaceRange)
        }

        /// Wrap (or unwrap, if already wrapped) the current selection with
        /// `style.marker`. With an empty selection, insert the markers around
        /// a short placeholder and leave the placeholder selected so the user
        /// can type over it.
        private func toggleInline(_ style: EditorInlineStyle) {
            guard let textView else { return }
            let marker = style.marker
            let markerLen = (marker as NSString).length
            let str = textView.string as NSString
            let sel = textView.selectedRange()

            if sel.length == 0 {
                let placeholder = style.placeholder
                let wrapped = marker + placeholder + marker
                textView.insertText(wrapped, replacementRange: sel)
                let start = sel.location + markerLen
                textView.setSelectedRange(NSRange(location: start, length: (placeholder as NSString).length))
                return
            }

            // Unwrap if the selection is already surrounded by matching markers.
            let before = sel.location - markerLen
            let after = sel.location + sel.length
            if before >= 0, after + markerLen <= str.length {
                let beforeText = str.substring(with: NSRange(location: before, length: markerLen))
                let afterText = str.substring(with: NSRange(location: after, length: markerLen))
                if beforeText == marker && afterText == marker {
                    let inner = str.substring(with: sel)
                    let wholeRange = NSRange(location: before, length: markerLen + sel.length + markerLen)
                    textView.insertText(inner, replacementRange: wholeRange)
                    textView.setSelectedRange(NSRange(location: before, length: (inner as NSString).length))
                    return
                }
            }

            let inner = str.substring(with: sel)
            let wrapped = marker + inner + marker
            textView.insertText(wrapped, replacementRange: sel)
            textView.setSelectedRange(NSRange(location: sel.location + markerLen, length: sel.length))
        }

        /// Insert a multi-line block at the caret. Leaves the caret at the
        /// end of the inserted block by default; pass `caretLineOffsetFromTop`
        /// to land inside (e.g. between fence lines of a code block).
        private func insertBlock(_ block: String, caretLineOffsetFromTop: Int? = nil) {
            guard let textView else { return }
            let str = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = str.lineRange(for: NSRange(location: sel.location, length: 0))
            let onBlankLine = str.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let lead = onBlankLine ? "" : "\n\n"
            let full = lead + block
            textView.insertText(full, replacementRange: sel)

            if let offset = caretLineOffsetFromTop {
                // Walk forward from the start of our insertion past `offset`
                // newlines so the caret ends on that line.
                let insertStart = sel.location + (lead as NSString).length
                var caret = insertStart
                var newlinesSeen = 0
                let currentStr = textView.string as NSString
                while caret < currentStr.length && newlinesSeen < offset {
                    let ch = currentStr.substring(with: NSRange(location: caret, length: 1))
                    caret += 1
                    if ch == "\n" { newlinesSeen += 1 }
                }
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
        }

        private func insertLinkTemplate() {
            guard let textView else { return }
            let sel = textView.selectedRange()
            let str = textView.string as NSString
            let linkText: String
            if sel.length > 0 {
                linkText = str.substring(with: sel)
            } else {
                linkText = "link text"
            }
            let template = "[\(linkText)](url)"
            textView.insertText(template, replacementRange: sel)
            // Select "url" so the user can paste over it.
            let urlStart = sel.location + (linkText as NSString).length + 3 // "[text]("
            textView.setSelectedRange(NSRange(location: urlStart, length: 3))
        }

        private func promptForAttachment() {
            guard let textView else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.canCreateDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let name = url.lastPathComponent
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "bmp", "tiff"]
            let isImage = imageExts.contains(url.pathExtension.lowercased())
            // Markdown image syntax renders inline; file links render as a link.
            // We embed the absolute file:// URL for now — Phase 8 will upload
            // attachments to R2 and rewrite to public URLs.
            let md = isImage
                ? "![\(name)](\(url.absoluteString))"
                : "[\(name)](\(url.absoluteString))"
            let sel = textView.selectedRange()
            textView.insertText(md, replacementRange: sel)
        }
    }
}

/// NSTextView subclass that watches for `/` and exposes a hook so the
/// coordinator can pop up the SlashMenu. Also intercepts clicks in the
/// checklist gutter to toggle checkboxes.
final class EditorTextView: NSTextView {
    weak var slashMenuController: SlashMenuController?

    override func mouseDown(with event: NSEvent) {
        if handleChecklistClick(with: event) { return }
        super.mouseDown(with: event)
    }

    /// Returns true if the click was inside a checklist gutter and we
    /// toggled a checkbox (in which case we short-circuit the default
    /// click handling that would otherwise place the caret).
    private func handleChecklistClick(with event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return false }
        let pointInView = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let adjusted = NSPoint(x: pointInView.x - inset.width,
                               y: pointInView.y - inset.height)

        // First: resolve the click to a character/line.
        // Use the textContainer origin for glyphIndex lookup.
        let glyphIndex = lm.glyphIndex(for: adjusted, in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard let storage = textStorage, charIndex < storage.length else { return false }
        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = ns.substring(with: lineRange)

        let isUnchecked = line.hasPrefix("- [ ] ")
        let isChecked = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
        guard isUnchecked || isChecked else { return false }

        // Only toggle when click landed inside the gutter (x < gutter width).
        let firstGlyphIdx = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 1),
                                          actualCharacterRange: nil).location
        let lineRect = lm.lineFragmentRect(forGlyphAt: firstGlyphIdx, effectiveRange: nil)
        let gutterWidth = MarkdownStyle.checklistGutter
        let inGutter = adjusted.x >= 0 && adjusted.x <= gutterWidth
        let inVerticalBand = adjusted.y >= lineRect.minY && adjusted.y <= lineRect.maxY
        guard inGutter && inVerticalBand else { return false }

        let newPrefix = isUnchecked ? "- [x] " : "- [ ] "
        let prefixRange = NSRange(location: lineRange.location, length: 6)
        insertText(newPrefix, replacementRange: prefixRange)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // If slash menu is visible, intercept navigation keys.
        if let controller = slashMenuController, controller.isVisible {
            switch event.keyCode {
            case 125: // down arrow
                controller.state.selectNext(); return
            case 126: // up arrow
                controller.state.selectPrevious(); return
            case 36: // return
                if let option = controller.state.currentOption() {
                    controller.commit(option); return
                }
            case 48: // tab
                if let option = controller.state.currentOption() {
                    controller.commit(option); return
                }
            case 53: // escape
                controller.hide(); return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        // After the super call updates the document, check if a `/` landed.
        if let s = string as? String, s == "/" {
            if let coordinator = delegate as? MarkdownTextView.Coordinator {
                // Use selectedRange after insertion — the caret is right after `/`.
                coordinator.slashTyped(at: max(selectedRange().location - 1, 0))
            }
        }
    }
}

/// NSLayoutManager subclass that draws checkboxes in the left gutter of
/// any paragraph whose markdown starts with `- [ ] ` or `- [x] `.
///
/// The raw marker text is hidden via 0.01pt font (see MarkdownTextStorage),
/// and a `firstLineHeadIndent`/`headIndent` of `checklistGutter` pts is
/// applied so visible text starts to the right of the gutter. Here we paint
/// the circle into that gutter during glyph drawing.
final class ChecklistLayoutManager: NSLayoutManager {
    private let notekeeperYellow = NSColor(red: 254/255, green: 206/255, blue: 79/255, alpha: 1)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawCheckboxes(in: glyphsToShow, origin: origin)
    }

    private func drawCheckboxes(in glyphRange: NSRange, origin: NSPoint) {
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }

        var cursor = charRange.location
        let end = min(NSMaxRange(charRange), ns.length)
        while cursor < end {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            guard lineRange.length > 0 else { break }

            let line = ns.substring(with: lineRange)
            let isChecked: Bool? = {
                if line.hasPrefix("- [ ] ") { return false }
                if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return true }
                return nil
            }()

            if let checked = isChecked {
                // Locate the line's first glyph to find where to draw.
                let firstGlyphIdx = self.glyphRange(
                    forCharacterRange: NSRange(location: lineRange.location, length: 1),
                    actualCharacterRange: nil
                ).location
                if firstGlyphIdx != NSNotFound {
                    let lineRect = lineFragmentRect(forGlyphAt: firstGlyphIdx, effectiveRange: nil)
                    drawCheckbox(lineRect: lineRect, origin: origin, checked: checked)
                }
            }

            cursor = NSMaxRange(lineRange)
        }
    }

    private func drawCheckbox(lineRect: NSRect, origin: NSPoint, checked: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size: CGFloat = 15
        let gutterPadding: CGFloat = 4
        // lineRect is in text-container coordinates; origin shifts into view space.
        let x = origin.x + lineRect.minX + gutterPadding
        let y = origin.y + lineRect.minY + (lineRect.height - size) / 2
        // Pull x back to the gutter start (lineRect.minX accounts for indent).
        let gutterX = origin.x + gutterPadding
        let box = CGRect(x: gutterX, y: y, width: size, height: size)
        _ = x // silence unused var if we later want centered variant

        ctx.saveGState()
        if checked {
            ctx.setFillColor(notekeeperYellow.cgColor)
            ctx.fillEllipse(in: box)
            // White checkmark inside. NSTextView uses flipped coordinates,
            // so "down" is increasing y.
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: box.minX + 3.2, y: box.midY + 0.5))
            ctx.addLine(to: CGPoint(x: box.midX - 0.5, y: box.maxY - 3.5))
            ctx.addLine(to: CGPoint(x: box.maxX - 2.8, y: box.minY + 3.8))
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: box.insetBy(dx: 0.5, dy: 0.5))
        }
        ctx.restoreGState()
    }
}

/// Owns the NSPopover that hosts the SwiftUI slash-menu UI.
@MainActor
final class SlashMenuController: NSObject {
    struct ActiveContext {
        let slashLocation: Int
    }

    let state = SlashMenuState()
    private let popover = NSPopover()
    private(set) var activeContext: ActiveContext?
    var onCommit: ((SlashOption) -> Void)?
    var onFilterChange: ((String) -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
    }

    var isVisible: Bool { popover.isShown }

    func show(in textView: NSTextView, slashLocation: Int) {
        activeContext = ActiveContext(slashLocation: slashLocation)

        let host = NSHostingController(
            rootView: SlashMenuContent(
                state: state,
                onPick: { [weak self] option in self?.commit(option) },
                onClose: { [weak self] in self?.hide() }
            )
        )
        popover.contentViewController = host

        // Anchor the popover at the caret.
        let rect = caretRect(in: textView, at: slashLocation) ?? .zero
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }

    func commit(_ option: SlashOption) {
        onCommit?(option)
    }

    func hide() {
        popover.performClose(nil)
        activeContext = nil
    }

    private func caretRect(in textView: NSTextView, at location: Int) -> NSRect? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 0),
                                       actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        // Clamp to non-zero size so NSPopover has something to anchor.
        rect.size.width = max(rect.size.width, 2)
        rect.size.height = max(rect.size.height, 18)
        return rect
    }
}
