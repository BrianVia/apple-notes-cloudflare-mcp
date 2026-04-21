# NotekeeperMac UI build-out plan

Last updated: 2026-04-21

This is a sequenced plan for turning the current scaffold (a functional CRUD
shell over `NotekeeperCore`) into something that feels like Apple Notes —
without Catalyst, without shortcuts, and without accepting the generic
SwiftUI "chrome look" as the destination.

The repo-wide [`ROADMAP.md`](../../ROADMAP.md) lists the high-level P1 items;
this doc is the finer-grained path through the macOS-specific work, with
design calls, framework picks, and the order they should be attacked in.

---

## Design north star

Apple Notes has three non-obvious properties that make it feel native and
hard to copy:

1. **Typography that earns its size.** SF Pro at specific weights/sizes,
   with title-to-body contrast that matches the OS, not the app. Body is
   16 pt regular; title is 22 pt semibold; metadata (date, folder name)
   is 11 pt with `.secondary` foreground. Line-height is system-derived,
   not custom.
2. **Inline-formatted markdown that never shows its syntax.** You type
   `# Title` and see "Title" at title size — the `#` disappears as the
   caret leaves the line. `- [ ]` becomes a tappable circle. Links are
   blue; not underlined until hover. This is the hard part. Get it
   right and the app feels premium; get it wrong and it feels like
   a wrapped code editor.
3. **Sidebar materials and rhythm.** `.ultraThinMaterial` background with
   `.sidebar` list style, 2-line note-list cells with the pin as a small
   yellow dot, and a fixed 44 pt row height (not `Spacer`-driven). The
   animation when switching notes is the default `NavigationSplitView`
   crossfade — don't replace it.

Everything below serves one of those three. "Feels like Apple Notes" is
not a wishlist item; it is a function of these three being right.

---

## Current state (baseline)

Shipped in the scaffold:

- `NavigationSplitView` shell (`RootView.swift`)
- Connect sheet with Keychain persistence
- Note list (plain rows), select → detail
- Plain `TextEditor` on raw markdown
- ⌘N creates draft, ⌘S saves full body via PATCH
- Error surfacing via `.alert`

Intentionally deferred, to be picked up below:

- Folders sidebar, trash, search UI
- Inline markdown rendering / checkbox UI
- Pin affordance, relative-time labels in list, sort by pinned then updated
- Live CRDT sync (WebSocket + yswift)
- Attachments
- Window chrome polish (titlebar, sidebar blur)

---

## Phased build-out

Each phase is scoped small enough that you can ship it, dogfood for a day,
then commit to the next. That cadence is deliberate — the trap with an
"Apple Notes clone" is building the whole thing in one 3-week push and
discovering in week four that the editor doesn't feel right.

### Phase 1 — Shell & visual language (est. 1.5 sittings)

**What to build**

- Three-column `NavigationSplitView`:
  - Sidebar (folders + smart lists)
  - Middle column: note list for the selected source
  - Detail: editor
- Apply `.listStyle(.sidebar)` to the first column,
  `.listStyle(.inset)` to the middle.
- **Translucent titlebar, sidebar extends to top.**
  - `.windowStyle(.hiddenTitleBar)` on the `WindowGroup`.
  - `.toolbarBackground(.hidden, for: .windowToolbar)` on the root view.
  - `.background(.ultraThinMaterial)` on the sidebar — verify the
    material reads up through the traffic-light area in both light and
    dark modes before sign-off.
- **Multi-window support.** Add a secondary scene for single-note
  windows:

  ```swift
  WindowGroup("Note", for: Note.ID.self) { $noteID in
      if let id = noteID { NoteWindowView(noteID: id) }
  }
  ```

  A `NoteWindowView` renders just the editor, no sidebar, no list.
  ⌥⌘N and the context-menu item call `@Environment(\.openWindow)` with
  the note ID. Shared `AppModel` via `@EnvironmentObject`.
- SF Pro throughout — macOS uses it by default, but pin sizes explicitly:
  - Note title: `.system(size: 22, weight: .semibold)`
  - Body: `.system(size: 16)`
  - Metadata: `.system(size: 11)` + `.secondary`
- Design tokens in a `Theme.swift`, with light + dark variants from
  day 1 (dark-mode bugs found late are painful to track):

  ```swift
  enum Theme {
      static let pinYellow = Color(red: 254/255, green: 206/255, blue: 79/255)   // #FECE4F
      static let sidebarLight = Color(red: 245/255, green: 245/255, blue: 247/255) // #F5F5F7
      // Dark-mode sidebar bg comes from .ultraThinMaterial; no explicit token.
      static let listSelection = Color.accentColor.opacity(0.15)
  }
  ```

**What it buys**

The surface area is now big enough to tell whether the chrome feels right
— including the translucent titlebar, which is the single most
"Apple Notes vs. generic-SwiftUI" cue. If this doesn't feel right,
nothing else matters, so this comes first.

### Phase 2 — Note list cell (est. 1 sitting)

**What to build**

A custom `NoteRowView` that matches Apple Notes' cell:

```
┌─────────────────────────────────────────┐
│  ●  Bootstrap complete         Yesterday│  ← title (1 line) + date
│     Hello notekeeper — this is the first│  ← preview (2 lines)
│     real note seeded via the admin…     │
└─────────────────────────────────────────┘
```

- Yellow dot (8 pt) rendered when `note.pinned`; empty 8 pt gutter when not,
  so titles align whether pinned or not.
- Title: 1 line, `.headline`, truncating with ellipsis.
- Preview: take `note.body`, strip the first line if it matches the title,
  strip leading `#`/`-`/`*` markers, coalesce whitespace, then take the
  first ~2 lines. Extract this into a `NotePreview.derive(from:)` in
  `NotekeeperCore` — it's the same logic the CLI's `ls` column uses,
  and iOS will want it too.
- Date: relative when within 7 days (`Text(note.updatedAt, style: .relative)`),
  absolute short date otherwise. Wire a custom formatter that switches
  based on `Date.now.timeIntervalSince(note.updatedAt)`.
- Pinned notes float to the top of the list with a subtle "Pinned" section
  header. The current API returns them in order (`pinned DESC, updated_at
  DESC`), so the client just has to render the section break.

**Why it matters**

This cell is what the user's eye hits hundreds of times a day. A 15%
improvement here has more perceived-quality impact than any other single
piece of UI.

### Phase 3 — Inline markdown rendering in the editor (est. 3-5 sittings)

**This is the make-or-break phase.** Don't skip it, don't paper over it.
Estimate bumped from the original 2-3 to 3-5 because the animated
checkbox attachment (decision #4) is a proper sub-project.

**The three real options**

1. **`NSTextView` + custom `NSTextStorage` subclass.** You subclass
   `NSTextStorage`, override `processEditing()`, and on every change you
   run a markdown parser over the edited range and apply `NSAttributedString`
   attributes to hide the `#`/`*`/`_` syntax markers and style what they
   wrap. This is how Bear, Craft, and Paper do it.
   - Pros: the *only* approach that actually hides syntax while the caret
     is outside the line. Native performance. Full AppKit integration
     (find, spellcheck, services).
   - Cons: you're writing real AppKit. `NSViewRepresentable` boundary.
     Harder to preview in SwiftUI.

2. **SwiftUI `TextEditor` + AttributedString** via the iOS 15+ Markdown
   parser.
   - Pros: stays in SwiftUI.
   - Cons: `TextEditor` doesn't support attributed display — it's a
     `NSTextView` under the hood but with the attributedText bridge
     deliberately hidden. You can't make it render markdown inline. Non-starter
     for our goal.

3. **A custom SwiftUI editor** built from `Text` + input handling.
   - Pros: full control.
   - Cons: you'd be writing a text editor from scratch. Text editors are
     harder than they look — selection, IME, accessibility, undo. Years
     of work. Non-starter unless this becomes a multi-year project.

**Recommendation: Option 1.** Wrap an `NSTextView` in `NSViewRepresentable`,
drop in a custom `NSTextStorage` that re-stylizes on edit.

**What to build, concretely**

- `MarkdownTextStorage: NSTextStorage` (in `NotekeeperMac/Sources/Editor/`):
  - Owns an `NSMutableAttributedString` backing store.
  - On `processEditing()`, find paragraphs overlapping `editedRange` and
    re-tokenize them. Pull a minimal markdown parser (or write one for
    our syntax subset: `#` headings, `**bold**`, `*italic*`, `-` list,
    `- [ ]` checkbox, `[link](url)`).
  - Apply attributes: headings = larger size + `.semibold`; bold/italic
    via `NSFontManager.shared.convert(_:toHaveTrait:)`; syntax markers
    get `NSForegroundColor` set to a low-contrast gray AND their font
    scaled to 0.01 pt when the caret is not in that paragraph, restoring
    full size when the caret enters it. (This is the trick that hides
    the `#` — don't delete the characters, just make them invisible.)
- `MarkdownTextView: NSViewRepresentable`:
  - Creates an `NSTextView` backed by the custom storage.
  - Forwards value changes as `Binding<String>` (markdown plaintext).
  - Handles ⌘B / ⌘I to toggle bold/italic syntax markers in selection.
- Checkbox rendering: in `processEditing()`, when a line matches
  `- [ ] ` or `- [x] `, replace the 6 characters with a custom
  `NSTextAttachment` subclass whose `attachmentCell` draws via a
  `CALayer` — an empty circle with a 1 pt tertiary-gray stroke, or
  a yellow-filled (#FECE4F) circle with an inset white checkmark.
  Toggle animation: 200 ms `CABasicAnimation` on `backgroundColor`,
  plus a 1.0 → 1.15 → 1.0 scale bounce via `CAKeyframeAnimation`.
  Click the attachment → toggle; rewrite the underlying markdown
  (`- [ ] ` ↔ `- [x] `) so the stored body stays portable. Click
  dispatch: register a sentinel `notekeeper-checkbox://<range>` URL as
  a link attribute on the attachment; intercept in
  `NSTextView.clickedOnLink(at:)`.

**Risks / open questions**

- Performance on very long notes. Mitigation: limit re-tokenization to
  paragraphs, not whole document. With typical Apple-Notes-sized notes
  (< 10K chars) this is imperceptible.
- Undo integration. `NSTextStorage` changes need to be wrapped in
  `NSTextView`'s undo manager via `beginEditing()`/`endEditing()` and
  `NSUndoManager` registrations. Get this right or the user will be
  frustrated.
- A 3-sitting estimate is optimistic. Budget 5 if it's your first time
  inside `NSTextStorage`.

### Phase 4 — Sidebar: folders tree, smart lists, trash (est. 2 sittings)

**What to build**

Sidebar sections, in this order:

```
iCloud                    ← static header, not interactive in v1
  All Notes       42
  Pinned           3
  …
Folders                   ← expandable
  Work              8
    Meetings        4
    Reviews         4
  Personal         11
Trash               2
```

- Pull folder tree via `APIClient.listFolders()`. Build a tree client-side
  from `parent_id` relationships.
- Badge each row with count (fire a `GET /v1/notes?folder_id=…&limit=1`
  with `Prefer: count` header — wait, we don't have that endpoint. Cheaper
  alternative: a new `GET /v1/folders/counts` server route returning
  `{folder_id: count}`. Server tech debt; add to P0 in ROADMAP).
- "All Notes" is just `listNotes()` with no folder filter.
- "Pinned" is `listNotes({ folder_id: nil })` client-filtered or a new
  `?pinned=true` server param.
- "Trash" is `listNotes({ trashed: true })`.
- Drag a note between folders: `updateNote(id, .init(folderId: …))`.
- **Inline folder create & rename** (per decision #5):
  - Right-click sidebar → `New Folder` → inserts an editable
    `TextField` row whose state lives on `AppModel.pendingFolder`.
    Auto-focus via `@FocusState`. ↵ commits (`POST /v1/folders` with
    the typed name + current `parent_id`). ⎋ or focus-loss cancels
    and removes the row.
  - Double-click a folder row → replaces the `Text` with a
    pre-populated `TextField`. ↵ commits (`PATCH /v1/folders/:id`).
  - The cancel-on-blur path is the fiddly part — use `.onSubmit` for
    the commit and `.onChange(of: isFocused)` for the cancel.

**What to build on the server**

- `GET /v1/folders/counts` — returns per-folder note count. Small SQL
  query, cheap to cache in KV for a few seconds if it gets hot.
- Consider `?pinned=true` filter on `GET /v1/notes`.

These belong in `ROADMAP.md` under P0 "Onboarding & admin" since the
sidebar wants them.

### Phase 5 — Interactions, shortcuts, context menus (est. 1 sitting)

- Keyboard:
  - `⌘N` — new note (done)
  - `⌘⌫` — move to trash (on selected note)
  - `⌘⇧⌫` — permanent delete with confirmation
  - `⌘L` — toggle pin
  - `⌘F` — focus search field
  - `⌘⇧F` — global search (command palette)
- Context menus on note-list rows: Pin/Unpin, Move to Folder, Duplicate,
  Delete.
- Context menus on folder rows: Rename, New Subfolder, Delete.
- Double-click on note title to edit title (separate from body).
- Implement via `.contextMenu { }` modifiers and a single `CommandsBuilder`
  scene extension for keyboard shortcuts.

### Phase 6 — Search UI (est. 1 sitting)

Two search surfaces:

1. **Sidebar search field** at the top, always visible. Typing filters
   the currently-visible note list in place (client-side if the current
   filter set returned < 200 notes, server-side via `?q=` otherwise).
2. **Command palette** (`⌘⇧F`) — full-screen overlay, searches across
   all notes regardless of filter. Shows `snippet` with `<mark>` parsed
   into an `AttributedString` with bold on the highlighted terms.

`APIClient.search(_:)` already exposes the endpoint; the UI is the last
mile.

### Phase 7 — CRDT sync, online editor (est. 2-4 sittings)

Until this lands, `NotekeeperMac` is a pretty fetch-and-PATCH client.
After it lands, it's a collaborative editor.

**What to build**

- Add `yswift` as a Swift Package dependency in `NotekeeperCore/Package.swift`.
- `NoteSyncEngine` — a per-open-note actor that:
  - Opens a `URLSessionWebSocketTask` to `/v1/notes/:id/ws?token=<apiKey>`.
  - Speaks the 3-byte sync protocol that `apps/api/src/do/note-do.ts`
    implements: `SYNC_STEP_1 = 0`, `SYNC_STEP_2 = 1`, `UPDATE = 2`.
  - Integrates the incoming updates into a `YDoc.getText("body")`.
  - Observes the `YText`, mirrors its content into the `MarkdownTextStorage`
    from Phase 3. Local edits flow back as `encodeStateAsUpdate` deltas.
- Offline buffer: if the WS is disconnected, updates accumulate in the
  local YDoc; on reconnect the engine sends the accumulated diff.
- Fallback: if the WS fails repeatedly (`> 3` retries in 30 seconds),
  degrade to REST `PATCH` on `body` and show a "Reconnecting…" badge.

**Risks**

- Protocol mismatches with the DO. Write a small diagnostic tool that
  speaks both sides of the protocol against a local wrangler dev server
  before integrating with the UI.
- yswift's API surface is not identical to Yjs's JS API. Budget time for
  porting the 3-byte protocol code — the `apps/api/src/do/note-do.ts`
  hand-rolled sync is a reference, not copy-paste.

### Phase 8 — Polish (est. ongoing)

- Hover highlights on note rows and folder rows (`.onHover { }`).
- Smooth 200 ms crossfade when switching notes (default SwiftUI is fine;
  override only if it's wrong).
- Empty states: "No notes in this folder. ⌘N to create." with an SF Symbol.
- Loading states: skeleton rows while the first list fetch is in flight.
- Subtle haptic-feedback-equivalent on pin toggle (macOS has
  `NSHapticFeedbackManager` — cute, not required).
- Menu bar icon with recent notes (Phase 9? later).

---

## Design decisions

All five resolved in favor of Apple Notes parity, regardless of
development cost.

1. **Multi-window: yes.** `⌥⌘N` opens the selected note in a dedicated
   window, same as Apple Notes' "Open Note in New Window."
   - Implementation: add a `WindowGroup(for: Note.ID.self)` secondary
     scene in `NotekeeperMacApp`. Invoke via `@Environment(\.openWindow)`
     from the context menu and the ⌥⌘N shortcut.
   - Per-note window uses simplified chrome — no sidebar, just the
     editor and title area. `AppModel` is shared via `@EnvironmentObject`
     so edits in one window flow to the main list immediately. Once CRDT
     sync lands (Phase 7), sync handles cross-window coherence naturally.
   - Effort: +0.5 sitting, folded into Phase 1.

2. **Titlebar: translucent, sidebar extends to the top.** The defining
   Apple Notes chrome trick.
   - Implementation: `.windowStyle(.hiddenTitleBar)` +
     `.toolbarBackground(.hidden, for: .windowToolbar)` so the sidebar's
     `.ultraThinMaterial` reads up through the traffic-light area.
     Traffic lights take their default positioning (no inset offset).
   - Verify on both light and dark modes before calling Phase 1 done —
     translucency behavior differs and you'll see it before anyone else.
   - Effort: already in Phase 1 as a sub-task; no estimate change.

3. **Title from first line, single editor.** No separate title field.
   The first non-empty line renders at title size (22 pt semibold);
   subsequent lines are body.
   - The server already derives `title` from the first non-empty line
     (`deriveTitle` in `apps/api/src/routes/notes.ts:408-414`). No
     server change needed; the client just renders it that way.
   - `note.title` is used in list cells and window titles only; editing
     "the title" means editing line 1 of the body. Integrates into
     Phase 3's markdown tokenizer as one more rule: if line is the first
     non-empty line and has no `#` prefix, treat as heading size.
   - Effort: no delta — folded into Phase 3 work.

4. **Animated toggleable circle for checkboxes.** Not SF Symbol swap.
   Empty circle (1 pt tertiary-gray stroke) → yellow-filled with white
   checkmark, 200 ms `CABasicAnimation` on `backgroundColor` + a 1.0 →
   1.15 → 1.0 scale bounce on toggle.
   - Implementation: custom `NSTextAttachment` subclass drawing via a
     `CALayer`. Attached in place of literal `- [ ] ` / `- [x] ` text
     by `MarkdownTextStorage` (Phase 3). Click handling routes through
     `NSTextView`'s link-click mechanism with a sentinel URL scheme
     like `notekeeper-checkbox://<paragraph-range>`.
   - Toggling the checkbox writes `- [x] ` / `- [ ] ` back into the
     underlying markdown, so the stored body stays plain markdown.
   - Effort: +1 sitting to Phase 3. New estimate: **3-5 sittings for
     Phase 3 total** (was 2-3).

5. **Inline "New Folder" with rename-in-place.** Not a modal dialog.
   - Right-click sidebar → `New Folder` inserts an empty row with an
     auto-focused `TextField`. ↵ commits (`POST /v1/folders` with the
     typed name + current `parent_id`), ⎋ or click-outside cancels and
     removes the row.
   - Same pattern covers **rename**: double-click a folder row →
     `TextField` replaces the `Text`. ↵ commits (`PATCH /v1/folders/:id`).
   - Uses `@FocusState` + a transient `PendingFolder` model in
     `AppModel`. Not trivial UX (cancel-on-blur is the fiddly part), but
     bounded scope.
   - Effort: +0.5 sitting to Phase 4. New estimate: **2 sittings**
     (was 1-2).

---

## Sequencing advice (the opinionated order)

If I were you, this is the order I'd actually run these phases, with
what you'd learn at each milestone:

```
Phase 1 — visual language       (~1.5 sittings) → does this look like a Notes app yet?
Phase 2 — note list cell        (~1 sitting)    → does scrolling the list feel premium?
Phase 3 — inline markdown        (3-5 sittings) → does editing feel like Notes, or like VSCode?
Phase 4 — sidebar & folders     (~2 sittings)   → does navigating a real workspace work?
Phase 5 — shortcuts / menus     (~1 sitting)    → does the keyboard get out of your way?
Phase 6 — search UI             (~1 sitting)    → can I actually find anything?
Phase 7 — CRDT sync             (2-4 sittings)  → does it feel live & offline-safe?
Phase 8 — polish                 (ongoing)      → continuously
```

Rough total through Phase 7: **12–16 sittings**. If a sitting is
~3 focused hours, that's ~36–48 hours of keyboard time, likely
stretched across 3–5 weeks of evenings.

The trap is attacking Phase 7 (CRDT) first because it's the most
technically interesting. Resist. A pretty fetch-and-PATCH app is more
dogfoodable than a collaborative-but-ugly one. If you get to Phase 6 and
are still using Apple Notes for daily notes, that's a signal to pause and
re-evaluate before committing weeks to CRDT work.

---

## Parallel concerns that aren't phases

- **iOS target.** `NotekeeperCore` already builds for iOS 17+. Spin up
  `NotekeeperIOS/project.yml` once Phase 3 is stable — the editor is the
  hardest thing to port, so we need it settled before forking a second
  target.
- **App icon + branding.** `NotekeeperMac/Assets.xcassets/AppIcon.appiconset/`
  needs a 1024×1024 PNG and Xcode generates the rest. Make it boring and
  clear, not clever.
- **TestFlight / notarization.** Deferred to Phase 8+. We can sign with a
  personal team for local runs indefinitely.
- **Analytics / crash reporting.** Not in scope for v1. Cloudflare Workers
  Analytics Engine (mentioned in ROADMAP) is server-side; Sentry/Bugsnag
  would be a separate add if you ever go public.
