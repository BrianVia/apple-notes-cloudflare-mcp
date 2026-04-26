import { Hono } from "hono";
import {
  NoteCreateSchema,
  NoteUpdateSchema,
  NoteListQuerySchema,
} from "@notekeeper/shared";
import type { HonoBindings } from "../lib/env";
import { newId, isValidId } from "../lib/ids";
import { BadRequest, NotFound } from "../lib/errors";
import { requireScope } from "../lib/auth";
import { deriveTitle } from "../lib/derive-title";

const app = new Hono<HonoBindings>();

// ─── Helpers ────────────────────────────────────────────────────────────────

async function upsertTags(
  db: D1Database,
  user_id: string,
  note_id: string,
  tagNames: string[],
): Promise<void> {
  const unique = [...new Set(tagNames.map((t) => t.trim().toLowerCase()).filter(Boolean))];

  // Clear existing
  await db.prepare(`DELETE FROM note_tags WHERE note_id = ?`).bind(note_id).run();
  if (unique.length === 0) return;

  // Batch insert tags (ignore if exist), then look up ids, then attach.
  const stmts: D1PreparedStatement[] = [];
  for (const name of unique) {
    stmts.push(
      db
        .prepare(`INSERT OR IGNORE INTO tags (user_id, name) VALUES (?, ?)`)
        .bind(user_id, name),
    );
  }
  await db.batch(stmts);

  const placeholders = unique.map(() => "?").join(",");
  const tagRows = await db
    .prepare(
      `SELECT id, name FROM tags WHERE user_id = ? AND name IN (${placeholders})`,
    )
    .bind(user_id, ...unique)
    .all<{ id: number; name: string }>();

  const linkStmts = tagRows.results.map((row) =>
    db
      .prepare(`INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)`)
      .bind(note_id, row.id),
  );
  if (linkStmts.length) await db.batch(linkStmts);
}

async function getTagsForNote(db: D1Database, note_id: string): Promise<string[]> {
  const rows = await db
    .prepare(
      `SELECT t.name FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = ? ORDER BY t.name`,
    )
    .bind(note_id)
    .all<{ name: string }>();
  return rows.results.map((r) => r.name);
}

interface NoteRow {
  id: string;
  user_id: string;
  folder_id: string | null;
  title: string;
  body: string;
  pinned: number;
  locked: number;
  created_at: string;
  updated_at: string;
  trashed_at: string | null;
}

function serializeNote(row: NoteRow, tags: string[]) {
  return {
    id: row.id,
    user_id: row.user_id,
    folder_id: row.folder_id,
    title: row.title,
    body: row.body,
    pinned: row.pinned === 1,
    locked: row.locked === 1,
    tags,
    created_at: row.created_at,
    updated_at: row.updated_at,
    trashed_at: row.trashed_at,
  };
}

// ─── Routes ─────────────────────────────────────────────────────────────────

/** GET /v1/notes — list (or search) */
app.get("/", requireScope("read"), async (c) => {
  const parsed = NoteListQuerySchema.safeParse(c.req.query());
  if (!parsed.success) throw BadRequest("invalid_query", "invalid query params", parsed.error.format());
  const q = parsed.data;
  const user_id = c.var.auth.user_id;

  // FTS path
  if (q.q) {
    const trashFilter = q.trashed ? "n.trashed_at IS NOT NULL" : "n.trashed_at IS NULL";
    const results = await c.env.DB.prepare(
      `SELECT n.* FROM notes n
         JOIN notes_fts f ON f.rowid = n.rowid
         WHERE n.user_id = ? AND ${trashFilter}
           AND notes_fts MATCH ?
         ORDER BY bm25(notes_fts)
         LIMIT ?`,
    )
      .bind(user_id, q.q, q.limit)
      .all<NoteRow>();

    const notes = await Promise.all(
      results.results.map(async (r) => serializeNote(r, await getTagsForNote(c.env.DB, r.id))),
    );
    return c.json({ notes, next_cursor: null });
  }

  // Regular list — keyset pagination by (pinned DESC, updated_at DESC, id)
  const filters: string[] = [`user_id = ?`];
  const binds: unknown[] = [user_id];

  if (q.trashed) filters.push(`trashed_at IS NOT NULL`);
  else filters.push(`trashed_at IS NULL`);

  if (q.folder_id !== undefined) {
    if (q.folder_id === null) filters.push(`folder_id IS NULL`);
    else {
      filters.push(`folder_id = ?`);
      binds.push(q.folder_id);
    }
  }

  if (q.tag) {
    filters.push(
      `id IN (SELECT nt.note_id FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE t.user_id = ? AND t.name = ?)`,
    );
    binds.push(user_id, q.tag.toLowerCase());
  }

  if (q.cursor) {
    // cursor format: base64(updated_at|id)
    try {
      const decoded = atob(q.cursor);
      const [ts, id] = decoded.split("|");
      if (!ts || !id) throw new Error();
      filters.push(`(updated_at, id) < (?, ?)`);
      binds.push(ts, id);
    } catch {
      throw BadRequest("invalid_cursor", "cursor is not valid");
    }
  }

  const sql = `SELECT * FROM notes WHERE ${filters.join(" AND ")}
               ORDER BY pinned DESC, updated_at DESC, id DESC
               LIMIT ?`;
  binds.push(q.limit + 1);

  const { results } = await c.env.DB.prepare(sql).bind(...binds).all<NoteRow>();
  const hasMore = results.length > q.limit;
  const page = hasMore ? results.slice(0, q.limit) : results;
  const last = page[page.length - 1];
  const next_cursor = hasMore && last ? btoa(`${last.updated_at}|${last.id}`) : null;

  const notes = await Promise.all(
    page.map(async (r) => serializeNote(r, await getTagsForNote(c.env.DB, r.id))),
  );
  return c.json({ notes, next_cursor });
});

/** POST /v1/notes — create */
app.post("/", requireScope("write"), async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = NoteCreateSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_body", "invalid body", parsed.error.format());

  const user_id = c.var.auth.user_id;
  const id = newId();
  const now = new Date().toISOString();
  const noteBody = parsed.data.body ?? "";
  const title = parsed.data.title ?? deriveTitle(noteBody);
  // Import-time timestamp preservation. When a caller (e.g. `nk import`)
  // passes created_at/updated_at, honor them so history survives the round
  // trip. No auth gate beyond requireScope("write") since the key owner is
  // already trusted to write any notes they want.
  const created_at = parsed.data.created_at ?? now;
  const updated_at = parsed.data.updated_at ?? now;

  await c.env.DB.prepare(
    `INSERT INTO notes (id, user_id, folder_id, title, body, pinned, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      user_id,
      parsed.data.folder_id ?? null,
      title,
      noteBody,
      parsed.data.pinned ? 1 : 0,
      created_at,
      updated_at,
    )
    .run();

  await upsertTags(c.env.DB, user_id, id, parsed.data.tags ?? []);

  // Seed FTS row
  await c.env.DB.prepare(
    `INSERT INTO notes_fts(rowid, title, body, tags) VALUES ((SELECT rowid FROM notes WHERE id = ?), ?, ?, ?)`,
  )
    .bind(id, title, noteBody, (parsed.data.tags ?? []).join(" "))
    .run();

  // Bind the Durable Object and seed its body.
  const stub = c.env.NOTE_DO.get(c.env.NOTE_DO.idFromName(id));
  c.executionCtx.waitUntil(
    (async () => {
      await stub.fetch("https://do/bind", {
        method: "POST",
        body: JSON.stringify({ note_id: id, user_id }),
      });
      if (noteBody) {
        // ?silent=1 — D1 already has the authoritative row. We're only
        // seeding the DO's Y.Doc so future WS clients start with text.
        // Without this, the flush alarm would stomp updated_at with now.
        await stub.fetch("https://do/body?silent=1", { method: "PUT", body: noteBody });
      }
    })(),
  );

  const row = await c.env.DB.prepare(`SELECT * FROM notes WHERE id = ?`)
    .bind(id)
    .first<NoteRow>();
  return c.json(serializeNote(row!, await getTagsForNote(c.env.DB, id)), 201);
});

/** GET /v1/notes/:id */
app.get("/:id", requireScope("read"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid note id");

  const user_id = c.var.auth.user_id;
  const row = await c.env.DB.prepare(
    `SELECT * FROM notes WHERE id = ? AND user_id = ?`,
  )
    .bind(id, user_id)
    .first<NoteRow>();
  if (!row) throw NotFound("note not found");

  // Prefer the DO's live body if it's dirty. We call /body on the DO which
  // returns the current Y.Doc text — authoritative.
  const stub = c.env.NOTE_DO.get(c.env.NOTE_DO.idFromName(id));
  const liveRes = await stub.fetch("https://do/body");
  if (liveRes.ok) {
    row.body = await liveRes.text();
  }

  return c.json(serializeNote(row, await getTagsForNote(c.env.DB, id)));
});

/** PUT /v1/notes/:id — replace */
/** PATCH /v1/notes/:id — partial */
for (const method of ["put", "patch"] as const) {
  app[method]("/:id", requireScope("write"), async (c) => {
    const id = c.req.param("id");
    if (!isValidId(id)) throw BadRequest("invalid_id", "invalid note id");

    const body = await c.req.json().catch(() => null);
    const parsed = NoteUpdateSchema.safeParse(body);
    if (!parsed.success) throw BadRequest("invalid_body", "invalid body", parsed.error.format());

    const user_id = c.var.auth.user_id;
    const existing = await c.env.DB.prepare(
      `SELECT * FROM notes WHERE id = ? AND user_id = ?`,
    )
      .bind(id, user_id)
      .first<NoteRow>();
    if (!existing) throw NotFound("note not found");

    const updates: string[] = [];
    const binds: unknown[] = [];
    if (parsed.data.title !== undefined) {
      updates.push("title = ?");
      binds.push(parsed.data.title);
    }
    if (parsed.data.folder_id !== undefined) {
      updates.push("folder_id = ?");
      binds.push(parsed.data.folder_id);
    }
    if (parsed.data.pinned !== undefined) {
      updates.push("pinned = ?");
      binds.push(parsed.data.pinned ? 1 : 0);
    }
    if (parsed.data.locked !== undefined) {
      updates.push("locked = ?");
      binds.push(parsed.data.locked ? 1 : 0);
    }

    const now = new Date().toISOString();
    updates.push("updated_at = ?");
    binds.push(now);
    binds.push(id);

    if (updates.length > 1) {
      await c.env.DB.prepare(
        `UPDATE notes SET ${updates.join(", ")} WHERE id = ?`,
      )
        .bind(...binds)
        .run();
    }

    // Body edits go through the DO so CRDT state stays consistent.
    if (parsed.data.body !== undefined) {
      const stub = c.env.NOTE_DO.get(c.env.NOTE_DO.idFromName(id));
      await stub.fetch("https://do/body", {
        method: "PUT",
        body: parsed.data.body,
      });
    }

    if (parsed.data.tags !== undefined) {
      await upsertTags(c.env.DB, user_id, id, parsed.data.tags);
    }

    const row = await c.env.DB.prepare(`SELECT * FROM notes WHERE id = ?`)
      .bind(id)
      .first<NoteRow>();
    const tags = await getTagsForNote(c.env.DB, id);

    // Keep FTS5 index in sync on content changes. notes.body may be stale
    // if the caller sent a body update (that goes through the DO and flushes
    // asynchronously), so prefer the intended value when we have it.
    if (
      parsed.data.title !== undefined ||
      parsed.data.body !== undefined ||
      parsed.data.tags !== undefined
    ) {
      await c.env.DB.prepare(
        `UPDATE notes_fts SET title = ?, body = ?, tags = ?
           WHERE rowid = (SELECT rowid FROM notes WHERE id = ?)`,
      )
        .bind(
          parsed.data.title ?? row!.title,
          parsed.data.body ?? row!.body,
          tags.join(" "),
          id,
        )
        .run();
    }

    return c.json(serializeNote(row!, tags));
  });
}

/** DELETE /v1/notes/:id — soft delete (moves to trash) */
app.delete("/:id", requireScope("write"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid note id");
  const user_id = c.var.auth.user_id;

  const hard = c.req.query("hard") === "true";
  const now = new Date().toISOString();

  if (hard) {
    // Permanent. Order matters: capture the rowid first, drop the FTS row,
    // then drop the note. The old code deleted from notes first, which made
    // the subselect in the FTS DELETE find nothing.
    const ex = await c.env.DB.prepare(
      `SELECT rowid FROM notes WHERE id = ? AND user_id = ?`,
    )
      .bind(id, user_id)
      .first<{ rowid: number }>();
    if (!ex) throw NotFound("note not found");
    await c.env.DB.prepare(`DELETE FROM notes_fts WHERE rowid = ?`)
      .bind(ex.rowid)
      .run();
    await c.env.DB.prepare(
      `DELETE FROM notes WHERE id = ? AND user_id = ?`,
    )
      .bind(id, user_id)
      .run();
    // Record the tombstone so /v1/sync clients can drop their local copy.
    // INSERT OR REPLACE keeps the most recent deletion timestamp if the same
    // id was deleted, recreated, then deleted again.
    await c.env.DB.prepare(
      `INSERT OR REPLACE INTO tombstones (entity, id, user_id, deleted_at)
       VALUES ('note', ?, ?, ?)`,
    )
      .bind(id, user_id, now)
      .run();
    // DO storage cleanup is best-effort — a future sweep alarm could
    // reap orphaned DO state. For now, we don't block.
    return c.body(null, 204);
  }

  const res = await c.env.DB.prepare(
    `UPDATE notes SET trashed_at = ?, updated_at = ? WHERE id = ? AND user_id = ? AND trashed_at IS NULL`,
  )
    .bind(now, now, id, user_id)
    .run();
  if (res.meta.changes === 0) throw NotFound("note not found or already trashed");
  return c.body(null, 204);
});

/** POST /v1/notes/:id/restore */
app.post("/:id/restore", requireScope("write"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid note id");
  const user_id = c.var.auth.user_id;
  const now = new Date().toISOString();
  const res = await c.env.DB.prepare(
    `UPDATE notes SET trashed_at = NULL, updated_at = ? WHERE id = ? AND user_id = ? AND trashed_at IS NOT NULL`,
  )
    .bind(now, id, user_id)
    .run();
  if (res.meta.changes === 0) throw NotFound("note not in trash");
  return c.body(null, 204);
});

/** GET /v1/notes/:id/ws — Yjs WebSocket sync */
app.get("/:id/ws", async (c) => {
  // We do auth manually here because WebSocket upgrade headers don't play
  // nicely with the normal middleware chain on some clients.
  const token = c.req.query("token") ?? c.req.header("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return c.text("unauthorized", 401);

  // Re-run auth inline (avoids needing the middleware to handle WS specially).
  const { authenticateForWs } = await import("../lib/auth-ws");
  const auth = await authenticateForWs(token, c.env);
  if (!auth) return c.text("unauthorized", 401);

  const id = c.req.param("id");
  if (!isValidId(id)) return c.text("invalid id", 400);

  const owner = await c.env.DB.prepare(
    `SELECT 1 FROM notes WHERE id = ? AND user_id = ? AND trashed_at IS NULL`,
  )
    .bind(id, auth.user_id)
    .first();
  if (!owner) return c.text("not found", 404);

  const stub = c.env.NOTE_DO.get(c.env.NOTE_DO.idFromName(id));
  return stub.fetch("https://do/ws", {
    headers: {
      Upgrade: "websocket",
      "X-User-Id": auth.user_id,
    },
  });
});

export default app;
