import { Hono } from "hono";
import { FolderCreateSchema, FolderUpdateSchema } from "@notekeeper/shared";
import type { HonoBindings } from "../lib/env";
import { newId, isValidId } from "../lib/ids";
import { BadRequest, NotFound, Conflict } from "../lib/errors";
import { requireScope } from "../lib/auth";

const app = new Hono<HonoBindings>();

interface FolderRow {
  id: string;
  user_id: string;
  parent_id: string | null;
  name: string;
  created_at: string;
  updated_at: string;
}

/** GET /v1/folders — returns flat list; clients build the tree. */
app.get("/", requireScope("read"), async (c) => {
  const user_id = c.var.auth.user_id;
  const { results } = await c.env.DB.prepare(
    `SELECT * FROM folders WHERE user_id = ? ORDER BY name COLLATE NOCASE`,
  )
    .bind(user_id)
    .all<FolderRow>();
  return c.json({ folders: results });
});

/** POST /v1/folders */
app.post("/", requireScope("write"), async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = FolderCreateSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_body", "invalid body", parsed.error.format());

  const user_id = c.var.auth.user_id;
  if (parsed.data.parent_id) {
    const parent = await c.env.DB.prepare(
      `SELECT 1 FROM folders WHERE id = ? AND user_id = ?`,
    )
      .bind(parsed.data.parent_id, user_id)
      .first();
    if (!parent) throw BadRequest("invalid_parent", "parent folder not found");
  }

  const id = newId();
  const now = new Date().toISOString();
  await c.env.DB.prepare(
    `INSERT INTO folders (id, user_id, parent_id, name, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(id, user_id, parsed.data.parent_id ?? null, parsed.data.name, now, now)
    .run();

  const row = await c.env.DB.prepare(`SELECT * FROM folders WHERE id = ?`)
    .bind(id)
    .first<FolderRow>();
  return c.json(row, 201);
});

/** PATCH /v1/folders/:id */
app.patch("/:id", requireScope("write"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid folder id");

  const body = await c.req.json().catch(() => null);
  const parsed = FolderUpdateSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_body", "invalid body", parsed.error.format());

  const user_id = c.var.auth.user_id;
  const existing = await c.env.DB.prepare(
    `SELECT * FROM folders WHERE id = ? AND user_id = ?`,
  )
    .bind(id, user_id)
    .first<FolderRow>();
  if (!existing) throw NotFound("folder not found");

  // Cycle check: if parent_id is being changed, walk up from the new parent
  // and ensure we never see our own id.
  if (parsed.data.parent_id !== undefined && parsed.data.parent_id !== null) {
    if (parsed.data.parent_id === id) {
      throw Conflict("cycle", "folder cannot be its own parent");
    }
    let cursor: string | null = parsed.data.parent_id;
    const seen = new Set<string>();
    while (cursor) {
      if (cursor === id) throw Conflict("cycle", "move would create a cycle");
      if (seen.has(cursor)) break; // already-bad data; bail rather than loop
      seen.add(cursor);
      const row: { parent_id: string | null } | null = await c.env.DB.prepare(
        `SELECT parent_id FROM folders WHERE id = ? AND user_id = ?`,
      )
        .bind(cursor, user_id)
        .first();
      if (!row) throw BadRequest("invalid_parent", "parent folder not found");
      cursor = row.parent_id;
    }
  }

  const updates: string[] = [];
  const binds: unknown[] = [];
  if (parsed.data.name !== undefined) {
    updates.push("name = ?");
    binds.push(parsed.data.name);
  }
  if (parsed.data.parent_id !== undefined) {
    updates.push("parent_id = ?");
    binds.push(parsed.data.parent_id);
  }
  if (updates.length === 0) return c.json(existing);

  updates.push("updated_at = ?");
  binds.push(new Date().toISOString());
  binds.push(id);

  await c.env.DB.prepare(`UPDATE folders SET ${updates.join(", ")} WHERE id = ?`)
    .bind(...binds)
    .run();

  const row = await c.env.DB.prepare(`SELECT * FROM folders WHERE id = ?`)
    .bind(id)
    .first<FolderRow>();
  return c.json(row);
});

/** DELETE /v1/folders/:id — children cascade via FK; notes are SET NULL */
app.delete("/:id", requireScope("write"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid folder id");
  const user_id = c.var.auth.user_id;
  const res = await c.env.DB.prepare(
    `DELETE FROM folders WHERE id = ? AND user_id = ?`,
  )
    .bind(id, user_id)
    .run();
  if (res.meta.changes === 0) throw NotFound("folder not found");
  return c.body(null, 204);
});

export default app;
