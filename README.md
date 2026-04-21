# notekeeper

Apple Notes clone on Cloudflare. Markdown-native, CRDT-synced, API-first.

## What this is

An open-backend notes service where the Apple Notes-style clients are just one consumer. The backend is a Cloudflare Worker (Hono) + Durable Objects + D1 + R2. Notes are collaborative Y.Docs; metadata (folders, tags, pins, search) lives in D1.

## Repo layout

```
notekeeper/
├── apps/
│   ├── api/          Cloudflare Worker — REST + WS + Durable Objects
│   └── cli/          `nk` CLI — Node/Bun binary
├── packages/
│   └── shared/       Zod schemas, types, API client shared across all clients
├── migrations/       D1 SQL migrations
└── wrangler.toml     at apps/api/
```

## The stack

| Concern         | Choice                                                   |
| --------------- | -------------------------------------------------------- |
| Edge compute    | Cloudflare Workers (Hono)                                |
| Real-time sync  | Durable Objects + Yjs (`y-durableobjects`)               |
| Metadata        | D1 (SQLite at edge)                                      |
| Search          | D1 FTS5 virtual table                                    |
| Attachments     | R2                                                       |
| Caches / limits | KV                                                       |
| Auth            | API keys (hashed) + OAuth 2.0 (PKCE) + Apple Sign In     |
| Validation      | Zod                                                      |
| CLI             | Bun/Node + Commander + `keytar` for secure token storage |

## Why these choices

- **Yjs over last-write-wins.** Offline-first mobile and collaborative editing both need CRDTs. `y-durableobjects` wraps this natively on Cloudflare — each note is its own DO instance.
- **D1 as metadata-only.** Query performance matters for folder tree / tag listings / FTS. Putting CRDT blobs in D1 is slow; keep them in DO SQLite + R2 cold storage.
- **API keys AND OAuth.** Keys for your personal scripts and third-party integrations. OAuth for clients where users log in (iOS app, web companion).
- **Markdown as canonical format.** The Y.Doc stores markdown text; clients render however they want. Apple Notes rich formatting maps cleanly to markdown extensions (checkboxes, tables, attachments).

## Getting started

Prereqs: Node 20+, pnpm 9, a Cloudflare account, `wrangler` CLI (`npm i -g wrangler`).

```bash
pnpm install

# local dev (creates local D1, runs Worker on :8787)
cd apps/api
wrangler d1 create notekeeper       # note the database_id, paste into wrangler.toml
pnpm migrate:local
pnpm dev

# in another terminal, use the CLI against local
cd apps/cli
pnpm install
pnpm build
./dist/nk login --endpoint http://localhost:8787
./dist/nk new "hello world" --body "# My first note"
./dist/nk ls
```

## Deploying

```bash
cd apps/api
wrangler d1 create notekeeper-prod
# paste database_id into [env.production] in wrangler.toml
wrangler kv:namespace create CACHE
wrangler r2 bucket create notekeeper-attachments
pnpm migrate:prod
wrangler deploy --env production
```

## API surface (v1)

All endpoints require `Authorization: Bearer nk_live_...` (API key) or `Authorization: Bearer <jwt>` (OAuth session).

| Method | Path                           | Purpose                              |
| ------ | ------------------------------ | ------------------------------------ |
| GET    | `/v1/notes`                    | List notes (filters: folder, tag, q) |
| POST   | `/v1/notes`                    | Create note                          |
| GET    | `/v1/notes/:id`                | Get note (markdown body + metadata)  |
| PUT    | `/v1/notes/:id`                | Replace body/metadata                |
| PATCH  | `/v1/notes/:id`                | Partial update                       |
| DELETE | `/v1/notes/:id`                | Soft delete (moves to trash)         |
| POST   | `/v1/notes/:id/restore`        | Restore from trash                   |
| GET    | `/v1/notes/:id/ws`             | Upgrade to Yjs WebSocket             |
| GET    | `/v1/notes/:id/attachments`    | List attachments                     |
| POST   | `/v1/notes/:id/attachments`    | Upload (multipart)                   |
| GET    | `/v1/folders`                  | List folders (tree)                  |
| POST   | `/v1/folders`                  | Create folder                        |
| PATCH  | `/v1/folders/:id`              | Rename / reparent                    |
| DELETE | `/v1/folders/:id`              | Delete folder                        |
| GET    | `/v1/tags`                     | List tags with counts                |
| GET    | `/v1/search?q=...`             | FTS5 search                          |
| POST   | `/v1/api-keys`                 | Create API key (returns once)        |
| GET    | `/v1/api-keys`                 | List keys (metadata only)            |
| DELETE | `/v1/api-keys/:id`             | Revoke                               |
| POST   | `/v1/oauth/authorize`          | OAuth authorize endpoint             |
| POST   | `/v1/oauth/token`              | OAuth token exchange                 |

## Roadmap

- [x] v1: Worker API + CLI (this scaffold)
- [ ] v1.1: Tauri desktop client (React + CodeMirror + y-websocket) for Linux/Windows/macOS fallback
- [ ] v1.2: SwiftUI client (iOS + macOS) using yswift for CRDT — native Apple Notes feel
- [ ] v2: E2E encryption (locked notes), shared notes, version history UI

See [`ROADMAP.md`](./ROADMAP.md) for the full task list, priorities, and open tech debt.

## License

MIT
