import AppKit

/// Custom NSTextStorage that re-tokenizes edited paragraphs and applies
/// markdown styling as attributes. Keeps the plain-markdown source intact
/// in `backing` — rendering is purely an attribute overlay, so exporting
/// `.string` round-trips the same markdown the server stored.
///
/// The "hide syntax on unfocused line" trick is done by shrinking marker
/// characters (like `# `, `**`) to 0.01pt font size on paragraphs that
/// don't contain the caret. When the caret moves into a paragraph, we
/// re-tokenize it so markers become visible again for editing.
final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    /// Driven by MarkdownTextView's delegate — character index of caret.
    /// Re-tokenizes affected paragraphs when the caret moves between them.
    var caretLocation: Int = 0 {
        didSet {
            guard caretLocation != oldValue else { return }
            retokenizeParagraphsTouching([oldValue, caretLocation])
        }
    }

    // MARK: - NSTextStorage primitives

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - Tokenization

    override func processEditing() {
        // Expand the edited range to full paragraphs so we never leave a
        // half-styled line. Also include the previous paragraph in case
        // the edit split one into two.
        let ns = backing.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let edited = self.editedRange
        var range = ns.paragraphRange(for: edited)
        // Extend a bit to pick up paragraph right before (handles newline insertion)
        if range.location > 0 {
            let prior = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            range = NSUnionRange(range, prior)
        }
        range = NSIntersectionRange(range, full)
        tokenize(range: range)
        super.processEditing()
    }

    /// Re-tokenize the paragraphs containing each of the given character
    /// indices. Used for caret-movement re-renders (marker visibility toggle).
    func retokenizeParagraphsTouching(_ locations: [Int]) {
        let ns = backing.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }

        var ranges: [NSRange] = []
        for loc in locations {
            let clamped = max(0, min(loc, full.length))
            let r = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
            if !ranges.contains(where: { NSEqualRanges($0, r) }) {
                ranges.append(r)
            }
        }
        for r in ranges {
            beginEditing()
            tokenize(range: r)
            edited(.editedAttributes, range: r, changeInLength: 0)
            endEditing()
        }
    }

    /// Apply markdown-derived attributes to the given (paragraph-aligned) range.
    func tokenize(range: NSRange) {
        let ns = backing.string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard clamped.length > 0 else { return }
        let firstNonEmptyLineLocation = firstNonEmptyLineLocation(in: ns)

        // Reset to body baseline first.
        backing.setAttributes(MarkdownStyle.bodyAttrs, range: clamped)

        // Walk the range line-by-line.
        var cursor = clamped.location
        let end = NSMaxRange(clamped)
        while cursor < end {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            applyLineAttributes(
                lineRange: lineRange,
                string: ns,
                firstNonEmptyLineLocation: firstNonEmptyLineLocation
            )
            cursor = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }

    // MARK: - Per-line rendering

    private func applyLineAttributes(
        lineRange: NSRange,
        string ns: NSString,
        firstNonEmptyLineLocation: Int?
    ) {
        guard lineRange.length > 0 else { return }
        let line = ns.substring(with: lineRange)
        let caretOnThisLine = NSLocationInRange(caretLocation, lineRange)
            || caretLocation == NSMaxRange(lineRange) // allow caret at paragraph end

        // 1. Check if this is the first non-empty line → render as Title.
        let isFirstLine = firstNonEmptyLineLocation == lineRange.location

        // Strip any leading `# ` / `## ` / `### ` marker for styling purposes.
        var markerCharCount = 0
        var level = 0 // 0 = no `#` prefix, 1..3 = heading levels
        var scan = line.startIndex
        while scan < line.endIndex, line[scan] == "#", level < 3 {
            level += 1
            scan = line.index(after: scan)
        }
        if level > 0, scan < line.endIndex, line[scan] == " " {
            markerCharCount = level + 1 // e.g. "# " is 2 chars
        } else {
            level = 0
            markerCharCount = 0
        }

        if isFirstLine {
            // Title styling regardless of whether `# ` was there.
            applyFont(MarkdownStyle.title, to: NSRange(location: lineRange.location + markerCharCount,
                                                       length: lineRange.length - markerCharCount))
            hideBlockMarker(NSRange(location: lineRange.location, length: markerCharCount))
            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: markerCharCount)
            return
        }

        // Heading cases on non-first lines.
        if level > 0 {
            let font: NSFont
            switch level {
            case 1: font = MarkdownStyle.heading
            case 2: font = MarkdownStyle.subheading
            default: font = MarkdownStyle.h3
            }
            applyFont(font, to: NSRange(location: lineRange.location + markerCharCount,
                                        length: lineRange.length - markerCharCount))
            hideBlockMarker(NSRange(location: lineRange.location, length: markerCharCount))
            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: markerCharCount)
            return
        }

        // Blockquote `> `
        if line.hasPrefix("> ") {
            let markerLen = 2
            let textRange = NSRange(location: lineRange.location + markerLen,
                                    length: lineRange.length - markerLen)
            backing.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: textRange)
            backing.addAttribute(.font, value: MarkdownStyle.body, range: textRange)
            hideBlockMarker(NSRange(location: lineRange.location, length: markerLen))
            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: markerLen)
            return
        }

        // Checklist `- [ ] ` / `- [x] `. Marker is ALWAYS hidden; the circle
        // is drawn by ChecklistLayoutManager in the indent gutter. The
        // paragraph indent makes room for the drawn circle.
        if let match = checklistPrefixLength(in: line) {
            let markerLen = match.markerLength
            let isChecked = match.checked
            let textRange = NSRange(location: lineRange.location + markerLen,
                                    length: lineRange.length - markerLen)
            let markerRange = NSRange(location: lineRange.location, length: markerLen)

            // Hide the raw `- [ ] ` text.
            backing.addAttribute(.font, value: MarkdownStyle.hiddenFont, range: markerRange)

            // Push visible text right so the drawn circle has a gutter.
            backing.addAttribute(.paragraphStyle, value: MarkdownStyle.checklistParagraph, range: lineRange)

            if isChecked {
                backing.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue,
                                     range: textRange)
                backing.addAttribute(.foregroundColor,
                                     value: NSColor.tertiaryLabelColor,
                                     range: textRange)
            }

            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: markerLen)
            return
        }

        // Bulleted list `- ` or `* `
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let markerLen = 2
            // Keep the marker visible so the bullet is readable. Style dimmer.
            let markerRange = NSRange(location: lineRange.location, length: markerLen)
            backing.addAttribute(.foregroundColor,
                                 value: NSColor.tertiaryLabelColor,
                                 range: markerRange)
            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: markerLen)
            return
        }

        // Numbered list `1. `, `2. `, ...
        if let numLen = numberedPrefixLength(in: line) {
            let markerRange = NSRange(location: lineRange.location, length: numLen)
            backing.addAttribute(.foregroundColor,
                                 value: NSColor.tertiaryLabelColor,
                                 range: markerRange)
            applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: numLen)
            return
        }

        // Default body line — still run inline rules for bold/italic/code/link.
        applyInline(in: lineRange, string: ns, caretOnLine: caretOnThisLine, skipLeading: 0)
    }

    /// Inline (within-line) rules: `**bold**`, `*italic*`, `` `code` ``, `[text](url)`.
    private func applyInline(in lineRange: NSRange, string ns: NSString, caretOnLine: Bool, skipLeading: Int) {
        let searchStart = lineRange.location + skipLeading
        let searchLen = lineRange.length - skipLeading
        guard searchLen > 0 else { return }
        let range = NSRange(location: searchStart, length: searchLen)
        let lineSub = ns.substring(with: range)

        // Links `[text](url)` — style the text portion, hide the brackets/url.
        for m in MarkdownPatterns.link.matches(in: lineSub, options: [], range: NSRange(location: 0, length: (lineSub as NSString).length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let fullLocal = m.range
            let textLocal = m.range(at: 1)
            let full = NSRange(location: range.location + fullLocal.location, length: fullLocal.length)
            let textAbs = NSRange(location: range.location + textLocal.location, length: textLocal.length)

            // Style visible text portion as link.
            backing.addAttribute(.foregroundColor, value: NSColor.linkColor, range: textAbs)
            backing.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textAbs)

            // Hide surrounding brackets + url.
            let leadingBracketRange = NSRange(location: full.location, length: 1) // "["
            let middleRange = NSRange(location: textAbs.location + textAbs.length,
                                      length: NSMaxRange(full) - (textAbs.location + textAbs.length)) // "](url)"
            hideMarker(leadingBracketRange, whenCaretIsOnLine: caretOnLine)
            hideMarker(middleRange, whenCaretIsOnLine: caretOnLine)
        }

        // Bold **text** (two-star). Run before italic so the four stars of
        // `****text****` don't mis-parse as italic.
        styleInlineDelimited(pattern: MarkdownPatterns.bold, in: range, lineSub: lineSub,
                              caretOnLine: caretOnLine, markerLength: 2) { subrange in
            let current = self.backing.attribute(.font, at: subrange.location, effectiveRange: nil) as? NSFont
                ?? MarkdownStyle.body
            let bolded = NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)
            self.backing.addAttribute(.font, value: bolded, range: subrange)
        }

        // Italic *text*
        styleInlineDelimited(pattern: MarkdownPatterns.italic, in: range, lineSub: lineSub,
                              caretOnLine: caretOnLine, markerLength: 1) { subrange in
            let current = self.backing.attribute(.font, at: subrange.location, effectiveRange: nil) as? NSFont
                ?? MarkdownStyle.body
            let italicized = NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask)
            self.backing.addAttribute(.font, value: italicized, range: subrange)
        }

        // Inline code `code`
        styleInlineDelimited(pattern: MarkdownPatterns.code, in: range, lineSub: lineSub,
                              caretOnLine: caretOnLine, markerLength: 1) { subrange in
            let size = (self.backing.attribute(.font, at: subrange.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 16
            let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            self.backing.addAttribute(.font, value: mono, range: subrange)
            self.backing.addAttribute(.backgroundColor,
                                      value: NSColor.quaternaryLabelColor.withAlphaComponent(0.4),
                                      range: subrange)
        }
    }

    private func styleInlineDelimited(
        pattern: NSRegularExpression,
        in absRange: NSRange,
        lineSub: String,
        caretOnLine: Bool,
        markerLength: Int,
        apply: (NSRange) -> Void
    ) {
        let localFull = NSRange(location: 0, length: (lineSub as NSString).length)
        for m in pattern.matches(in: lineSub, options: [], range: localFull) {
            guard m.numberOfRanges >= 2 else { continue }
            let inner = m.range(at: 1)
            let outer = m.range
            let innerAbs = NSRange(location: absRange.location + inner.location, length: inner.length)
            let leadMarkerAbs = NSRange(location: absRange.location + outer.location, length: markerLength)
            let trailMarkerAbs = NSRange(location: absRange.location + outer.location + outer.length - markerLength,
                                         length: markerLength)
            apply(innerAbs)
            hideMarker(leadMarkerAbs, whenCaretIsOnLine: caretOnLine)
            hideMarker(trailMarkerAbs, whenCaretIsOnLine: caretOnLine)
        }
    }

    // MARK: - Attribute helpers

    private func applyFont(_ font: NSFont, to range: NSRange) {
        guard range.length > 0 else { return }
        backing.addAttribute(.font, value: font, range: range)
    }

    /// Inline markers (`**`, `*`, `` ` ``, `[`, `](url)`): dimmed when caret
    /// is on the line so the user can see where the styled span starts/ends,
    /// fully hidden otherwise.
    private func hideMarker(_ range: NSRange, whenCaretIsOnLine caretOn: Bool) {
        guard range.length > 0 else { return }
        if caretOn {
            backing.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        } else {
            backing.addAttribute(.font, value: MarkdownStyle.hiddenFont, range: range)
        }
    }

    /// Block-level prefixes (`# `, `## `, `> `, etc.): always hidden. These
    /// define the *block type* — the user deletes them by backspacing the
    /// prefix chars away, not by editing them in place.
    private func hideBlockMarker(_ range: NSRange) {
        guard range.length > 0 else { return }
        backing.addAttribute(.font, value: MarkdownStyle.hiddenFont, range: range)
    }

    private func firstNonEmptyLineLocation(in ns: NSString) -> Int? {
        var scanStart = 0
        while scanStart < ns.length {
            let r = ns.lineRange(for: NSRange(location: scanStart, length: 0))
            let sub = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sub.isEmpty {
                return r.location
            }
            scanStart = NSMaxRange(r)
            if r.length == 0 { break }
        }
        return nil
    }

    private func checklistPrefixLength(in line: String) -> (markerLength: Int, checked: Bool)? {
        // Matches "- [ ] " or "- [x] " or "- [X] " at start.
        if line.hasPrefix("- [ ] ") { return (6, false) }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return (6, true) }
        return nil
    }

    private func numberedPrefixLength(in line: String) -> Int? {
        let m = MarkdownPatterns.numberedPrefix.firstMatch(in: line, options: [],
                                                            range: NSRange(location: 0, length: (line as NSString).length))
        guard let m, m.range.location == 0 else { return nil }
        return m.range.length
    }
}

// MARK: - Style + patterns

enum MarkdownStyle {
    static let body = NSFont.systemFont(ofSize: 16)
    static let title = NSFont.systemFont(ofSize: 28, weight: .bold)
    static let heading = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let subheading = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let h3 = NSFont.systemFont(ofSize: 16, weight: .semibold)
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    static var bodyAttrs: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        return [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Checkbox gutter width. Reserved on the left of checklist paragraphs so
    /// the drawn circle doesn't overlap the text.
    static let checklistGutter: CGFloat = 24

    static var checklistParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.25
        p.firstLineHeadIndent = checklistGutter
        p.headIndent = checklistGutter
        return p
    }
}

enum MarkdownPatterns {
    // `[text](url)` — non-greedy text, non-greedy url.
    static let link = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
        options: []
    )
    // **text** — no leading/trailing whitespace inside, no `*` inside.
    static let bold = try! NSRegularExpression(
        pattern: #"\*\*([^\*\n]+)\*\*"#,
        options: []
    )
    // *text* — single star; avoid matching `**` by requiring non-star neighbors.
    // Implemented via a lookaround-free pattern that consumes `*` when not preceded
    // or followed by another `*`.
    static let italic = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^\*\n]+)\*(?!\*)"#,
        options: []
    )
    // `code`
    static let code = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#,
        options: []
    )
    // `1. `, `22. `, etc. at start of line
    static let numberedPrefix = try! NSRegularExpression(
        pattern: #"^\d+\.\s"#,
        options: []
    )
}
