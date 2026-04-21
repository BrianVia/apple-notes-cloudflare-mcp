import { Hono } from "hono";
import { ApiKeyCreateSchema } from "@notekeeper/shared";
import type { HonoBindings } from "../lib/env";
import { newId, isValidId } from "../lib/ids";
import { BadRequest, NotFound } from "../lib/errors";
import { requireScope } from "../lib/auth";
import { sha256Hex, randomToken } from "../lib/crypto";

const app = new Hono<HonoBindings>();

interface KeyRow {
  id: string;
  name: string;
  prefix: string;
  scopes: string;
  last_used_at: string | null;
  expires_at: string | null;
  created_at: string;
}

/** POST /v1/api-keys — creates. Returns the plaintext secret ONCE. */
app.post("/", requireScope("admin"), async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = ApiKeyCreateSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_body", "invalid body", parsed.error.format());

  const user_id = c.var.auth.user_id;
  const id = newId();
  const secret = `nk_live_${randomToken(32)}`;
  const prefix = secret.slice(0, 12); // "nk_live_" + 4 chars
  const hash = await sha256Hex(secret);
  const now = new Date().toISOString();
  const expires_at = parsed.data.expires_in_days
    ? new Date(Date.now() + parsed.data.expires_in_days * 86400_000).toISOString()
    : null;

  await c.env.DB.prepare(
    `INSERT INTO api_keys (id, user_id, name, prefix, secret_hash, scopes, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      user_id,
      parsed.data.name,
      prefix,
      hash,
      JSON.stringify(parsed.data.scopes),
      expires_at,
      now,
    )
    .run();

  // Secret is returned ONCE — never readable again.
  return c.json(
    {
      id,
      name: parsed.data.name,
      prefix,
      scopes: parsed.data.scopes,
      last_used_at: null,
      expires_at,
      created_at: now,
      secret,
    },
    201,
  );
});

/** GET /v1/api-keys — metadata only; no secrets. */
app.get("/", requireScope("admin"), async (c) => {
  const user_id = c.var.auth.user_id;
  const { results } = await c.env.DB.prepare(
    `SELECT id, name, prefix, scopes, last_used_at, expires_at, created_at
       FROM api_keys WHERE user_id = ? ORDER BY created_at DESC`,
  )
    .bind(user_id)
    .all<KeyRow>();
  return c.json({
    keys: results.map((r) => ({ ...r, scopes: JSON.parse(r.scopes) })),
  });
});

/** DELETE /v1/api-keys/:id — revoke. */
app.delete("/:id", requireScope("admin"), async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid key id");
  const user_id = c.var.auth.user_id;
  const res = await c.env.DB.prepare(
    `DELETE FROM api_keys WHERE id = ? AND user_id = ?`,
  )
    .bind(id, user_id)
    .run();
  if (res.meta.changes === 0) throw NotFound("key not found");
  return c.body(null, 204);
});

export default app;
