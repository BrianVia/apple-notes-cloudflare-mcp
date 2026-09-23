# apple-notes-cloudflare-mcp

A **read-only mirror** of Apple Notes. The API and MCP endpoint can never modify
Apple Notes: data flows one way (Mac → Worker) and refreshes every 5 minutes.

- `apps/api`: authenticated Cloudflare Worker storing an index and Markdown notes in KV.
- `apps/cli`: `nk push` exports Apple Notes and replaces the Worker mirror.
- `ops`: a launchd agent that pushes every 5 minutes.

All routes require `Authorization: Bearer <API_TOKEN>`.

## HTTP API

- `PUT /notes` replaces the mirror from the Mac exporter.
- `GET /notes` returns the note index.
- `GET /notes/:id` returns one note as Markdown.

## MCP

Connect an MCP client to `https://api.brianvia.com/mcp` using the same bearer
token. The stateless Streamable HTTP endpoint exposes two read-only tools:

- `list_notes` returns the note index. Call it first.
- `get_note` returns one note's Markdown by id.

Install dependencies with `pnpm install`, deploy the Worker from `apps/api`, then follow
[`ops/README.md`](ops/README.md) to configure the Mac exporter.
