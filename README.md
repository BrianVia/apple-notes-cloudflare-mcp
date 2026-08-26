# notekeeper

A read-only HTTP mirror of Apple Notes, exported from a Mac.

- `apps/api`: authenticated Cloudflare Worker storing an index and Markdown notes in KV.
- `apps/cli`: `nk push` exports Apple Notes and replaces the Worker mirror.
- `ops`: a launchd agent that pushes every 30 minutes.

Install dependencies with `pnpm install`, deploy the Worker from `apps/api`, then follow
[`ops/README.md`](ops/README.md) to configure the Mac exporter.
