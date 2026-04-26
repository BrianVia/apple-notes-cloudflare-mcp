# notekeeper — Feature Backlog

A working list of features that could be built on top of the v0.1 backend (Cloudflare Workers + D1 + R2 + Durable Objects + Yjs CRDT). Each entry includes the value proposition, the implementation sketch, and the rough cost/complexity.

These are deliberately **not yet** in `ROADMAP.md` — they're candidates for prioritization once the core API + clients are stable.

---

## 1. Hybrid retrieval (vectorization + semantic search)

**What it is.** Move beyond D1's FTS5 keyword search to a QMD-style pipeline: BM25 + vector search + LLM reranking. Inspired by [tobi/qmd](https://github.com/tobi/qmd).

**Why it matters.** FTS5 misses conceptual queries — "what did I write about that bike thing" won't match a note titled "Olympic tri prep" even though it's the same topic. Embeddings catch the meaning, BM25 catches the exact phrase, reranking decides which result wins.

**Three implementation paths:**

### 1a. Native Cloudflare (recommended)
- **Embeddings**: Workers AI `@cf/baai/bge-base-en-v1.5` on every D1 flush
- **Vector store**: Cloudflare Vectorize (native, no extra infra)
- **Rerank**: Workers AI `@cf/baai/bge-reranker-base` for top-30 → top-10
- **Query expansion**: one Claude Haiku call to generate 2 variants
- **Pipeline**: query → expand → parallel (FTS5 + Vectorize) → RRF fusion → rerank → top-N
- **Endpoint**: `GET /v1/search?mode=hybrid&q=...`

**Cost:** ~$0.011 per 1k embedding tokens. For 5k notes averaging 500 tokens, full re-index is ~$0.03. Per-query: 2 Haiku calls + 1 embed + 1 rerank ≈ $0.001/query.

**Effort:** 200-300 lines on top of existing search route. ~1 weekend.

### 1b. QMD as sidecar
- New CLI command: `nk export --qmd-collection ~/notekeeper-export`
- Pulls all notes as `.md` files to disk, registers as a QMD collection
- User runs `qmd query` locally against the export
- Doubles as **backup/portability story** — never locked in

**Effort:** ~2 days. Mostly file I/O + a watch mode that re-pulls on changes.

### 1c. Don't bother yet
- FTS5 is genuinely fine for personal scale (≤10k notes)
- Revisit when search misses things you actually want to find
- The right answer until proven otherwise

**Recommendation:** Ship 1c (default). Add 1b as a power-user escape hatch + backup story. Build 1a only after dogfooding reveals FTS5 limits.

---

## 2. Smart titles + auto-tagging

**What it is.** On D1 flush, fire a Claude Haiku call to suggest a title (if blank or auto-derived) and 2-3 tags. User confirms or ignores via a "suggested" badge in the client.

**Why it matters.** Apple Notes' "first line as title" is fine but lossy — you end up with notes called "Hey can you" or "Quick thought". LLM-suggested titles are dramatically better, and tags emerge naturally from content rather than requiring discipline.

**Implementation.**
- New column: `notes.suggested_title TEXT, notes.suggested_tags TEXT (JSON)`
- Trigger on flush: if `body` length > 100 chars and no user-set title/tags, call Haiku with system prompt "Suggest a title (max 8 words) and 2-3 lowercase tags for this note: ..."
- Client surfaces suggestions inline; one tap to accept
- Rate-limit: max 1 suggestion per note per 5 minutes

**Cost:** ~$0.0008 per suggestion (Haiku is cheap). For 50 notes/day → $0.04/day → $1.20/month.

**Effort:** ~1 day backend, ~1 day client UI per platform.

---

## 3. "Ask my notes" endpoint

**What it is.** `POST /v1/ask {"question": "..."}` → semantic top-K → Claude prompt → cited answer with note IDs.

**Why it matters.** This is the killer feature Apple Notes can't ship. It's also the feature that justifies a paid tier on its own.

**Implementation.**
- Depends on #1a (hybrid retrieval) — needs embeddings to find conceptually relevant notes
- Top 5-10 retrieved notes → context window → Claude Sonnet prompt
- Response format: `{ answer: "...", citations: [{ note_id, snippet }] }`
- Streaming SSE response so clients can render the answer as it generates

**Cost:** ~$0.02 per question (Sonnet, ~3k context tokens). 20 questions/day → $0.40/day.

**Effort:** ~3 days. Most of it is good prompt design + citation extraction. The retrieval is reused from #1a.

**UX:** Command palette (`⌘K`) opens a "ask anything" input. Answer renders inline with note links. Tap a citation to jump to the source note.

---

## 4. Email-to-note

**What it is.** A dedicated email address (e.g. `notes-{user_id}@notekeeper.app`) that ingests forwarded emails as new notes. Subject becomes title, body becomes markdown.

**Why it matters.** Inbox-zero workflow — forward any email worth keeping into your notes. Removes the friction of "I should save this somewhere".

**Implementation.**
- Cloudflare Email Routing → Email Worker
- Email Worker parses the message (use `postal-mime` library)
- Maps `To: notes-{user_id}@...` → user_id
- Markdown body: convert HTML email to MD via `turndown`, fall back to plaintext
- Attachments → R2, linked from note body
- Subject prefix `#tag` parsing: `Subject: #recipes Pasta carbonara` → tagged "recipes"

**Quirks.**
- Need DNS configured for `notekeeper.app` MX records pointing to Cloudflare
- Need spam filtering (verify forwarder is the user — match `From:` against verified email)
- Reply-to-thread: future enhancement, append to existing note

**Effort:** ~2 days. Email parsing is the long pole.

---

## 5. Web clipper

**What it is.** Save any web page as a markdown note with one click.

**Two delivery surfaces:**

### 5a. Browser extension
- Manifest v3 extension (Chrome/Firefox/Safari)
- "Save to Notekeeper" context menu + toolbar button
- Reads page via `Readability.js` (Mozilla's readability extraction)
- Converts to markdown via `turndown`
- POSTs to `/v1/notes` with the user's API key (stored in extension settings)
- Optional: tag picker, folder picker, highlight selection-only

### 5b. URL ingest endpoint
- `POST /v1/clip { "url": "https://..." }` → fetches via Browser Rendering API
- Server-side extraction → markdown → new note
- Useful for shortcuts ("Add to Reading List"), zapier-style integrations, mobile share sheets

**Implementation.**
- Browser Rendering API extracts main content + metadata
- `turndown` converts HTML → MD (already in the stack from #4)
- Auto-tag with domain (`source:nytimes.com`) and detected language

**Cost:** Browser Rendering is $0.09 per browser-hour, but fetches typically take <2s, so effective cost is fractions of a cent.

**Effort:** Extension ~3 days. URL endpoint ~1 day. Build the endpoint first; the extension is a thin client over it.

---

## 6. Voice notes

**What it is.** Upload an audio file (or record in the client), transcribe to markdown, attach the original audio.

**Why it matters.** Walking-the-dog thoughts → notes without thumb-typing. Aligns with the "transcript as source of truth" pattern from your Transcriptor project.

**Implementation.**
- New endpoint: `POST /v1/notes/:id/voice` (multipart upload)
- Audio → R2 (already supported by attachments infra)
- Trigger transcription via one of:
  - **OpenAI Whisper API** (`whisper-1`, $0.006/minute) — simple, hosted, well-known
  - **Deepgram Nova-3** ($0.0043/minute) — faster, better diarization
  - **Cloudflare Workers AI** `@cf/openai/whisper-large-v3-turbo` — native, but quality varies
- Default to OpenAI Whisper for simplicity; expose a setting to swap providers
- Transcript → Note body. Audio file remains as an attachment.
- Optional post-processing: Claude Haiku call to clean up "umm"/"uhh" and add paragraph breaks

**Mobile/desktop UX.**
- Apple client: in-app recording with `AVAudioRecorder`, push-to-talk button in editor
- Tauri client: `tauri-plugin-microphone` or web `MediaRecorder` API
- iOS Shortcut: "Hey Siri, take a note" → records → uploads

**Cost.** Whisper at $0.006/min: ~$0.36/hour of audio. Heavy use (1 hour/day) = ~$10/month.

**Effort:** ~3 days backend (transcription pipeline + post-processing), ~3 days per client for in-app recording.

---

## 7. Backlinks + `[[wikilinks]]`

**What it is.** Parse `[[other note title]]` and `[[id:abc123]]` syntax in markdown. Build a graph. Render "Linked from" footer in each note showing other notes that link to it.

**Why it matters.** This is what makes a notes app sticky vs. a notes API. Roam/Obsidian users won't use anything without it. Cheap to build, transformative to UX.

**Implementation.**
- New table: `note_links (source_note_id, target_note_id, link_text, position)`
- On D1 flush, parse body for `[[...]]` syntax via regex
- Resolve `[[title]]` → first note with matching title (case-insensitive)
- Resolve `[[id:xxx]]` → exact ID lookup
- Insert/upsert into `note_links` table
- New endpoint: `GET /v1/notes/:id/backlinks` returns notes that link to this one
- Client renders backlinks footer + autocomplete dropdown when typing `[[`

**Edge cases.**
- Renaming a note: links by title remain valid (they're resolved on render). Optionally re-resolve and rewrite to `[[id:...]]` for permanence.
- Deletion: leave broken links visible (rendered red), let user fix manually

**Effort:** ~2 days backend, ~2 days per client for autocomplete + backlinks UI.

---

## 8. Reminders / due dates

**What it is.** Notes with a `due_at` timestamp that fire push notifications when due.

**Why it matters.** Apple Notes shipped this years ago and people miss it. It's also the bridge between "notes" and "tasks" — a note with a due date is a todo.

**Implementation.**
- New column: `notes.due_at TEXT NULL`
- New endpoint: `POST /v1/notes/:id/reminder { "due_at": "..." }`
- Cloudflare Cron Trigger runs every minute
- Cron Worker: `SELECT * FROM notes WHERE due_at BETWEEN now AND now+1min AND notified_at IS NULL`
- For each: send push notification via APNs (Apple), web push (browser), or email
- Update `notified_at` to prevent re-fires

**Push notification delivery.**
- iOS/macOS: APNs via `node-apn` or direct HTTP/2. Requires APNs certificate setup.
- Web/Tauri: Web Push protocol with VAPID keys
- Email fallback: SendGrid or Resend if no push subscription registered

**Recurring reminders.**
- Add `notes.recurrence TEXT` (RRULE format like iCal)
- Cron computes next occurrence after firing

**Effort:** ~3 days for one-shot reminders + push infra. ~2 more days for recurrence.

---

## 9. Templates

**What it is.** Stored markdown templates with placeholders (`{{date}}`, `{{title}}`, `{{cursor}}`). `nk new --template meeting` or "New from template" in the UI expands them.

**Why it matters.** Daily notes, meeting notes, project briefs all benefit from consistent structure. Removes friction from "what should I write".

**Implementation.**
- New table: `templates (id, user_id, name, body, created_at, updated_at)`
- CRUD endpoints under `/v1/templates`
- Placeholder syntax: `{{date}}`, `{{date:YYYY-MM-DD}}`, `{{time}}`, `{{prompt:What's the topic?}}`, `{{cursor}}` (where to place insertion point in client)
- CLI: `nk new --template meeting`, `nk templates ls`, `nk templates new --name daily --file ./daily.md`
- Client: "New from template" shows picker, prompts for any `{{prompt:...}}` placeholders, expands the rest

**Bundled defaults.**
- `daily` — date + sections for "Today's focus", "Notes", "Tomorrow"
- `meeting` — attendees, agenda, action items
- `project` — goal, scope, milestones, links

**Effort:** ~2 days backend + CLI, ~2 days per client.

---

## 10. Webhooks

**What it is.** Notify external systems on note events. `note.created`, `note.updated`, `note.deleted`, `note.shared`.

**Why it matters.** Turns notekeeper into a building block for your other projects. Brian-Bot can react to new notes, SlackPipe can fan-out to a Slack channel, anything you build later can subscribe.

**Implementation.**
- New table: `webhooks (id, user_id, url, secret, events, active, created_at)`
- CRUD endpoints under `/v1/webhooks`
- On note events: enqueue via Cloudflare Queues
- Queue consumer: HTTP POST to webhook URL with HMAC-SHA256 signature header
- Retries: 5 attempts with exponential backoff (Queues handles this natively)
- Failure threshold: auto-deactivate after 20 consecutive failures, email user

**Payload format.**
```json
{
  "event": "note.created",
  "timestamp": "2026-04-20T14:30:00Z",
  "data": { "note": { /* full note */ } }
}
```

**Signature verification.**
- Header: `X-Notekeeper-Signature: sha256=<hex>`
- Receivers verify with `HMAC-SHA256(secret, raw_body)`

**Cost.** Queues are $0.40 per million operations. At 100 events/day → $0.001/month. Effectively free.

**Effort:** ~2 days. Most of it is webhook delivery semantics (signing, retries, deactivation). Familiar territory given SlackPipe.

---

## Suggested order of operations

If everything above is on the table, this is the order I'd actually build them — based on **leverage per day of work**:

1. **Templates** (2 days) — daily notes is the "make this app sticky" feature
2. **Backlinks** (4 days) — wikilink syntax + backlinks panel transforms the UX
3. **Webhooks** (2 days) — unblocks integration with your other projects
4. **MCP server** (2 days, see ROADMAP P3) — Brian-Bot can read your notes natively
5. **Smart titles** (2 days) — high-impact, low-cost, very visible polish
6. **Web clipper endpoint** (1 day) — `POST /v1/clip` is the foundation for everything else
7. **Web clipper extension** (3 days) — once endpoint exists
8. **Email-to-note** (2 days) — relies on having a real domain set up
9. **Voice notes** (6 days) — only if you actually want the dog-walk capture loop
10. **Reminders** (5 days) — push infra is the long pole
11. **Hybrid retrieval (1a)** (3 days) — only after FTS5 actually fails you
12. **Ask my notes** (3 days) — depends on #11

**Total if you built everything:** ~35 days of focused work. Most of the value lands in the first 15 days (items 1-7).

The honest answer: **don't build all of these.** Pick 3-4, ship them, see what you actually use. The rest can wait.
