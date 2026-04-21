# notekeeper — Roadmap & Open Work

Last updated: 2026-04-20

This is the honest list of what's done, what's half-done, and what's ahead.
Status is tracked at the task level. Use `[ ]` → `[~]` (in progress) → `[x]`.

---

## Shipped (v0.1)

- [x] D1 schema: users, notes, folders, tags, attachments, api_keys, oauth_clients, oauth_codes, oauth_refresh_tokens, notes_fts (FTS5)
- [x] Cloudflare Worker (Hono) with CORS, logging, typed error handling
- [x] Auth middleware — API keys (SHA-256 at rest) + OAuth JWT, scope enforcement
- [x] `NoteDO` — Yjs CRDT per note, hibernation-safe WebSocket, debounced D1 flush (2s idle / 10s max)
- [x] Notes routes: CRUD, keyset-paginated list, FTS5 search, soft-delete + restore, WS upgrade
- [x] Folders routes with cycle detection on reparent
- [x] Tags routes with counts
- [x] Search with `<mark>` snippets and bm25 ranking
- [x] API keys: create (secret returned once), list, revoke
- [x] OAuth 2.0 with PKCE (S256) + refresh token rotation
- [x] Attachments: multipart upload to R2, HMAC-signed download URLs, 25 MB cap
- [x] Shared Zod schemas in `packages/shared` consumed by API + CLI
- [x] CLI (`nk`): login/logout/whoami, new/ls/get/edit/rm/restore/pin/unpin, folders, tags, search, keys
- [x] CLI config at `~/.config/notekeeper/config.json` (mode 0600)
- [x] CLI prefix-based ID resolution (`nk rm abc12345`)
- [x] CLI `edit` opens `$EDITOR`, mtime-checks before saving

---

## Priority 0 — Before you use this in anger

### Onboarding & admin

- [ ] **`POST /v1/bootstrap`** — single-call endpoint that creates a user + admin API key when the DB has zero users. Disabled after first use. Removes the manual SQL dance from the README.
- [ ] **`POST /v1/users/invite`** (admin-scoped) — create a second user with a starter API key, for when you add your wife or a collaborator later
- [ ] **`GET /v1/me`** — current user info (id, email, created_at). Clients need this to key local state.

### Cleanup & correctness

- [ ] **Drop unused `y-durableobjects` dep** from `apps/api/package.json`. The hand-rolled sync works; the library was aspirational. Saves bundle size.
- [ ] **DO storage cleanup on hard-delete** — currently the DO's Y.Doc lingers after `DELETE ?hard=true`. Add a sweep alarm that reaps DO state for notes no longer in D1, or call `state.storage.deleteAll()` via a new DO method invoked from the delete handler.
- [ ] **Rate limiting** — KV-backed sliding window keyed by `(user_id, route_class)`. Already have CACHE bound. Targets: 60 req/min for writes, 600/min for reads, 10 key-creates per hour.
- [ ] **Request ID middleware** — attach `X-Request-Id` to every response; include in error logs. Tiny, makes debugging tractable.
- [ ] **Tests** — Vitest + `@cloudflare/vitest-pool-workers`. Start with auth, notes CRUD, cycle detection on folder reparent, FTS5 search.

### Secrets & config hardening

- [ ] Real per-environment secrets via `wrangler secret put` (JWT_SECRET, ATTACHMENT_SIGNING_SECRET) — document the rotation story
- [ ] Tighten CORS origin reflection in prod (whitelist `notekeeper.app` and the Tauri `tauri://localhost` origin)

---

## Priority 1 — The Apple Notes-feel macOS + iOS client (SwiftUI)

Target: feels native on both platforms, no Catalyst compromise — separate iOS and macOS targets sharing a SwiftUI + Combine core.

### Project setup

- [ ] Xcode workspace at `apps/apple/` — `NotekeeperCore` (shared package), `NotekeeperMac`, `NotekeeperIOS`
- [ ] Shared Swift package `NotekeeperCore`:
  - [ ] `APIClient` mirroring `apps/cli/src/client.ts` (URLSession + async/await)
  - [ ] Codable types generated from or mirrored from the Zod schemas
  - [ ] Keychain-backed `CredentialStore`
  - [ ] `NoteStore` — `ObservableObject` with local SQLite cache (GRDB), reconciles against API on boot and on app-foreground

### CRDT sync

- [ ] Integrate **yswift** (the Swift Yjs port) for live collaboration
- [ ] `NoteSyncEngine` — maintains a `URLSessionWebSocketTask` per open note, speaks the same 3-byte sync protocol as `NoteDO` (SYNC_STEP_1 / SYNC_STEP_2 / UPDATE)
- [ ] Offline queue — edits while offline accumulate locally; on reconnect, replay as a single `encodeStateAsUpdate` diff
- [ ] Cold-storage fallback — if WS fails repeatedly, fall back to REST PATCH on body

### macOS UI (Apple Notes parity)

- [ ] Three-column `NavigationSplitView`: Folders | Note list | Editor
- [ ] Sidebar blur (`.background(.ultraThinMaterial)`) with the exact Notes sidebar chrome
- [ ] Note list cell: title (first line), preview (line 2-3, truncated), relative date, yellow pin badge
- [ ] Editor: SF Pro, 16pt body / 22pt title, markdown rendered inline (no raw syntax visible) — `AttributedString` + `Markdown` parser, with live formatting on `.textDidChange`
- [ ] Checkboxes via `- [ ]` syntax rendered as tappable bullets
- [ ] Pinned section always at top of note list; collapsible
- [ ] Folder context menu: New Folder, Rename, Delete, New Subfolder
- [ ] Trash folder as special node at bottom of sidebar
- [ ] `⌘N` new note, `⌘⌫` trash, `⌘⇧⌫` permanent, `⌘F` search
- [ ] Top-bar search field with live FTS results as dropdown
- [ ] Attachment drag-and-drop into editor → uploads to API, inserts `![filename](signed_url)`

### iOS UI

- [ ] Tabbed navigation: Folders → Notes (stack push on iPhone, split on iPad)
- [ ] Pull-to-refresh on note list
- [ ] Swipe actions: pin, delete
- [ ] Haptic feedback on pin/unpin
- [ ] iPad: adopt the full three-column `NavigationSplitView`, identical to macOS
- [ ] Share Sheet extension: "Send to Notekeeper" creates a new note with the shared text/URL
- [ ] Shortcuts app actions: Create Note, Append to Note, Search

### Auth

- [ ] **Apple Sign In** → backend `/v1/oauth/apple` (new endpoint) exchanges the Apple identity token for a notekeeper JWT. Schema already has `users.apple_sub`.
- [ ] Keychain-stored refresh token; silent refresh in `APIClient`
- [ ] Biometric unlock for `locked` notes (v2 feature — see Priority 3)

### Distribution

- [ ] TestFlight (iOS) + notarized DMG for macOS
- [ ] `sparkle` for macOS auto-updates outside the App Store, OR ship through MAS — decide based on whether you want IAP/subscriptions

---

## Priority 2 — The Tauri desktop client (Linux + Windows)

Target: one binary per OS, reuses the TypeScript `Client` from the CLI.

### Project setup

- [ ] Scaffold at `apps/tauri/` with `pnpm create tauri-app` — React + Vite + TypeScript template
- [ ] Move the CLI's `client.ts` and shared types into `packages/shared` where both the Tauri app and CLI can import them
- [ ] Tauri config: signing keys for Windows code-signing, AppImage + deb + rpm bundles for Linux

### UI

- [ ] Reuse the Apple Notes three-pane layout in React — CSS Grid + `backdrop-filter: blur(20px)` for sidebar
- [ ] **`y-codemirror.next`** + `y-websocket` (the original JS libraries) for the editor, talking to `NoteDO` over the same WS protocol the Swift client uses
- [ ] Shared design tokens: derive Apple Notes colors (`#FECE4F` pin yellow, `#F5F5F7` sidebar bg light, etc.) into a Tailwind theme
- [ ] System-theme aware (light/dark via `prefers-color-scheme`)
- [ ] Menu bar integration: global shortcut (`Ctrl+Shift+N`) to create a note from anywhere

### Tauri-specific

- [ ] Secure credential storage via `tauri-plugin-stronghold` (encrypted vault) instead of the plain config file the CLI uses
- [ ] Autostart on login (opt-in)
- [ ] Tray icon with recent notes submenu
- [ ] Deep links: `notekeeper://note/<id>` opens the app to that note

### Distribution

- [ ] GitHub Actions: build Linux (AppImage/deb/rpm), Windows (MSI signed), macOS (not needed — Swift app covers this, but Tauri on macOS could be a fallback)
- [ ] Self-hosted updater endpoint on Cloudflare Pages serving `latest.json`

---

## Priority 3 — v2 features (post-MVP)

### E2E encryption (locked notes)

- [ ] Per-note symmetric key, derived from a user passphrase via Argon2id
- [ ] Ciphertext stored in the Y.Doc — server never sees plaintext
- [ ] `locked: true` flag already in schema; wire up client-side encrypt/decrypt
- [ ] Biometric unlock integration (Keychain on Apple, Windows Hello on Tauri/Windows, kwallet/gnome-keyring on Linux)

### Collaborative features

- [ ] **Shared notes** — invite a user by email; they get read or write access. New table `note_shares(note_id, user_id, permission)`.
- [ ] **Presence** in the editor — cursor positions and user colors via Yjs awareness protocol
- [ ] **Comments** — sidecar Y.Array of comment anchors, doesn't pollute the main Y.Text

### Version history

- [ ] Periodic Y.Doc snapshots to R2 (every 100 updates or hourly, whichever first)
- [ ] `GET /v1/notes/:id/history` lists snapshots with timestamps
- [ ] `POST /v1/notes/:id/restore/:snapshot_id` reverts

### Import/export

- [ ] Apple Notes importer (reads `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` on macOS)
- [ ] Bear, Obsidian, Evernote importers
- [ ] Bulk export as `.zip` of markdown files with folder structure preserved

### Public API polish

- [ ] OpenAPI 3.1 spec served at `/v1/openapi.json`, generated from Zod schemas via `zod-openapi`
- [ ] Published OpenAPI → TypeScript SDK (`@notekeeper/sdk`) on npm
- [ ] Docs site on Cloudflare Pages (Astro + `starlight`)

### Monetization (if you ever want to flip this public)

- [ ] Tiers: Free (1 device, 100 notes), Pro ($3/mo: unlimited, shared notes, version history), Team ($8/user/mo: admin panel, SSO)
- [ ] Stripe billing via Cloudflare Workers webhook handler
- [ ] Per-user quota enforcement in the Worker (quota stored in KV, checked on write)

---

## Known issues / tech debt

- [ ] CLI `resolveId` pulls up to 200 notes for a prefix lookup — fine for small workspaces, won't scale. Add `GET /v1/notes/resolve/:prefix` server-side when needed.
- [ ] `handleWebSocket` in `NoteDO` accepts the socket via `state.acceptWebSocket` (hibernation-enabled) but the initial `sendSyncStep1` is called synchronously from the upgrade path rather than the hibernation handler — works but worth a re-read to confirm it's actually being hibernated correctly
- [ ] Title derivation duplicated in `notes.ts` and `note-do.ts` — extract to `lib/title.ts`
- [ ] No migration tooling for D1 schema v2 — when you change schema, you're hand-writing `0002_*.sql` files. Fine for now; document the convention.
- [ ] No telemetry. Consider Cloudflare Workers Analytics Engine for request volume, error rates, DO invocation counts (it's free up to 10M writes/day).

---

## How to prioritize

If I were you, this is the order I'd actually do it:

1. **`/v1/bootstrap` + `GET /v1/me` + rate limiting** (one afternoon). Makes the API self-sufficient.
2. **Tauri client first, not Swift.** Controversial, but: you can reuse 90% of the CLI code, validate the whole sync path end-to-end in React, and have a working desktop app in a week. The Swift client takes 3-4x longer because you're rewriting the client layer in Swift + learning SwiftUI for a real app (not a hobby project).
3. **Swift client second.** Now you know the sync protocol is sound, the API shape is stable, and you have design references from the Tauri build.
4. **E2E encryption.** Only if users ask for it or if you're selling Pro.
5. **Monetization.** Only if this starts getting organic traffic.

The trap here is spending weeks perfecting the Swift client before validating that anyone (even you) actually uses the thing daily. Ship the Tauri app to yourself, dogfood it for two weeks, then commit to the Swift build.
