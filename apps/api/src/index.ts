import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { HonoBindings } from "./lib/env";
import { errorHandler } from "./lib/errors";
import { requireAuth } from "./lib/auth";

import notes from "./routes/notes";
import folders from "./routes/folders";
import tags from "./routes/tags";
import search from "./routes/search";
import apiKeys from "./routes/api-keys";
import oauth from "./routes/oauth";
import { notesAttachments, attachmentsDownload } from "./routes/attachments";

export { NoteDO } from "./do/note-do";

const app = new Hono<HonoBindings>();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: (origin) => origin,
    credentials: true,
    allowHeaders: ["Authorization", "Content-Type"],
    exposeHeaders: ["X-Request-Id"],
    maxAge: 600,
  }),
);

// ─── Unauthenticated ────────────────────────────────────────────────────────
app.get("/", (c) => c.json({ service: "notekeeper", version: "0.1.0", ok: true }));
app.get("/health", (c) => c.json({ ok: true, ts: new Date().toISOString() }));

// Signed-URL attachment downloads — auth is in the signature.
app.route("/v1/attachments", attachmentsDownload);

// OAuth endpoints — handle their own auth.
app.route("/v1/oauth", oauth);

// ─── Authenticated ──────────────────────────────────────────────────────────
app.use("/v1/*", requireAuth);

app.route("/v1/notes", notes);
app.route("/v1/notes", notesAttachments);
app.route("/v1/folders", folders);
app.route("/v1/tags", tags);
app.route("/v1/search", search);
app.route("/v1/api-keys", apiKeys);

app.onError(errorHandler);
app.notFound((c) =>
  c.json({ error: { code: "not_found", message: "route not found" } }, 404),
);

export default app;
