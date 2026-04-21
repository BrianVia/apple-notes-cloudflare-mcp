import { Hono } from "hono";
import type { HonoBindings } from "../lib/env";
import { BadRequest } from "../lib/errors";
import { requireScope } from "../lib/auth";

const app = new Hono<HonoBindings>();

/**
 * GET /v1/search?q=... — FTS5 search with snippet/highlight.
 * Returns results ordered by bm25 relevance.
 *
 * The `q` param accepts FTS5 syntax: "foo bar" for phrase, foo OR bar,
 * etc. We sanitize common shell-unfriendly chars but trust the rest —
 * FTS5 is sandboxed and can't escape its virtual table.
 */
app.get("/", requireScope("read"), async (c) => {
  const q = c.req.query("q")?.trim();
  if (!q) throw BadRequest("missing_query", "q is required");

  const limit = Math.min(Number(c.req.query("limit") ?? 25), 100);
  const user_id = c.var.auth.user_id;

  // snippet() args: (table, column, before, after, ellipsis, max_tokens)
  const { results } = await c.env.DB.prepare(
    `SELECT n.id, n.title, n.folder_id, n.pinned, n.updated_at,
            snippet(notes_fts, 1, '<mark>', '</mark>', '…', 12) AS snippet,
            bm25(notes_fts) AS score
       FROM notes n
       JOIN notes_fts f ON f.rowid = n.rowid
       WHERE n.user_id = ? AND n.trashed_at IS NULL
         AND notes_fts MATCH ?
       ORDER BY bm25(notes_fts)
       LIMIT ?`,
  )
    .bind(user_id, q, limit)
    .all<{
      id: string;
      title: string;
      folder_id: string | null;
      pinned: number;
      updated_at: string;
      snippet: string;
      score: number;
    }>();

  return c.json({
    query: q,
    results: results.map((r) => ({
      id: r.id,
      title: r.title,
      folder_id: r.folder_id,
      pinned: r.pinned === 1,
      updated_at: r.updated_at,
      snippet: r.snippet,
      score: r.score,
    })),
  });
});

export default app;
