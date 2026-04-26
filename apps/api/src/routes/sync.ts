import { Hono } from "hono";
import { SyncQuerySchema, type SyncResponse } from "@notekeeper/shared";
import type { HonoBindings } from "../lib/env";
import { BadRequest } from "../lib/errors";
import { requireScope } from "../lib/auth";

const app = new Hono<HonoBindings>();

const EPOCH = "1970-01-01T00:00:00.000Z";

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

interface FolderRow {
  id: string;
  user_id: string;
  parent_id: string | null;
  name: string;
  created_at: string;
  updated_at: string;
}

interface TombstoneRow {
  entity: "note" | "folder";
  id: string;
  deleted_at: string;
}

/**
 * GET /v1/sync — delta endpoint for local-cache clients.
 *
 * Cursor semantics: clients pass `since=<ISO>` (omit on first call). The
 * response's `server_time` is the cursor for the next call. When `truncated`
 * is true, server_time equals the largest updated_at returned in this page;
 * the client should re-issue immediately with the new cursor. We bound only
 * the `notes` page; folders/tombstones are small and returned in full,
 * filtered to <= server_time when truncated so they stay consistent with the
 * notes slice.
 */
app.get("/", requireScope("read"), async (c) => {
  const parsed = SyncQuerySchema.safeParse(c.req.query());
  if (!parsed.success) {
    throw BadRequest("invalid_query", "invalid query", parsed.error.format());
  }
  const since = parsed.data.since ?? EPOCH;
  const limit = parsed.data.limit;
  const user_id = c.var.auth.user_id;

  // Notes — bounded page. Fetch limit+1 to detect truncation.
  const notesPlus = await c.env.DB.prepare(
    `SELECT * FROM notes
       WHERE user_id = ? AND updated_at > ?
       ORDER BY updated_at ASC, id ASC
       LIMIT ?`,
  )
    .bind(user_id, since, limit + 1)
    .all<NoteRow>();

  const truncated = notesPlus.results.length > limit;
  const notesPage = truncated
    ? notesPlus.results.slice(0, limit)
    : notesPlus.results;

  // When truncated, the cursor advances only as far as the last note in the
  // page. Folders and tombstones beyond that timestamp will appear on the
  // next call.
  const truncationCeiling = truncated
    ? notesPage[notesPage.length - 1]!.updated_at
    : null;

  // Folders — full list of changes since cursor (small).
  const foldersSql = truncationCeiling
    ? `SELECT * FROM folders
         WHERE user_id = ? AND updated_at > ? AND updated_at <= ?
         ORDER BY updated_at ASC`
    : `SELECT * FROM folders
         WHERE user_id = ? AND updated_at > ?
         ORDER BY updated_at ASC`;
  const foldersBinds: unknown[] = truncationCeiling
    ? [user_id, since, truncationCeiling]
    : [user_id, since];
  const foldersQ = await c.env.DB.prepare(foldersSql)
    .bind(...foldersBinds)
    .all<FolderRow>();

  // Tombstones — same pattern.
  const tombsSql = truncationCeiling
    ? `SELECT entity, id, deleted_at FROM tombstones
         WHERE user_id = ? AND deleted_at > ? AND deleted_at <= ?
         ORDER BY deleted_at ASC`
    : `SELECT entity, id, deleted_at FROM tombstones
         WHERE user_id = ? AND deleted_at > ?
         ORDER BY deleted_at ASC`;
  const tombsBinds: unknown[] = truncationCeiling
    ? [user_id, since, truncationCeiling]
    : [user_id, since];
  const tombsQ = await c.env.DB.prepare(tombsSql)
    .bind(...tombsBinds)
    .all<TombstoneRow>();

  // Tags — always returned in full. Cheap and avoids a tombstone path for
  // tags (which are auto-created/auto-removed alongside notes).
  const tagsQ = await c.env.DB.prepare(
    `SELECT t.name, COUNT(nt.note_id) AS count
       FROM tags t
       LEFT JOIN note_tags nt ON nt.tag_id = t.id
       LEFT JOIN notes n ON n.id = nt.note_id AND n.trashed_at IS NULL
       WHERE t.user_id = ?
       GROUP BY t.id
       HAVING count > 0
       ORDER BY count DESC, t.name`,
  )
    .bind(user_id)
    .all<{ name: string; count: number }>();

  // Pull tags-per-note for the page so the client doesn't need a second
  // round-trip per note. Joining inside the page query would be cleaner but
  // D1's prepared-statement binding for variable-length IN lists is awkward;
  // a single grouped fetch is simpler and still O(N) on the page size.
  const noteIds = notesPage.map((n) => n.id);
  const tagsByNote = new Map<string, string[]>();
  if (noteIds.length > 0) {
    const placeholders = noteIds.map(() => "?").join(",");
    const rows = await c.env.DB.prepare(
      `SELECT nt.note_id, t.name
         FROM note_tags nt
         JOIN tags t ON t.id = nt.tag_id
         WHERE nt.note_id IN (${placeholders})
         ORDER BY t.name`,
    )
      .bind(...noteIds)
      .all<{ note_id: string; name: string }>();
    for (const r of rows.results) {
      const list = tagsByNote.get(r.note_id) ?? [];
      list.push(r.name);
      tagsByNote.set(r.note_id, list);
    }
  }

  const notes = notesPage.map((r) => ({
    id: r.id,
    user_id: r.user_id,
    folder_id: r.folder_id,
    title: r.title,
    body: r.body,
    pinned: r.pinned === 1,
    locked: r.locked === 1,
    tags: tagsByNote.get(r.id) ?? [],
    created_at: r.created_at,
    updated_at: r.updated_at,
    trashed_at: r.trashed_at,
  }));

  // Compute server_time: when truncated, anchor to the page boundary so the
  // next call picks up exactly where this one left off. Otherwise, the max
  // across everything we returned (or the request's `since` if nothing
  // changed — that keeps the cursor from drifting past unseen writes).
  let server_time: string;
  if (truncationCeiling) {
    server_time = truncationCeiling;
  } else {
    server_time = since;
    for (const n of notes) if (n.updated_at > server_time) server_time = n.updated_at;
    for (const f of foldersQ.results) if (f.updated_at > server_time) server_time = f.updated_at;
    for (const t of tombsQ.results) if (t.deleted_at > server_time) server_time = t.deleted_at;
  }

  const body: SyncResponse = {
    notes,
    folders: foldersQ.results,
    tags: tagsQ.results,
    deleted: tombsQ.results.map((t) => ({
      entity: t.entity,
      id: t.id,
      deleted_at: t.deleted_at,
    })),
    server_time,
    truncated,
  };
  return c.json(body);
});

export default app;
