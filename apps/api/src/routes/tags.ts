import { Hono } from "hono";
import type { HonoBindings } from "../lib/env";
import { requireScope } from "../lib/auth";

const app = new Hono<HonoBindings>();

/** GET /v1/tags — all tags with note counts (trashed notes excluded). */
app.get("/", requireScope("read"), async (c) => {
  const user_id = c.var.auth.user_id;
  const { results } = await c.env.DB.prepare(
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
  return c.json({ tags: results });
});

export default app;
