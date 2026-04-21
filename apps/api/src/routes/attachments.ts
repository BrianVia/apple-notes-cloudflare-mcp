import { Hono } from "hono";
import type { HonoBindings } from "../lib/env";
import { newId, isValidId } from "../lib/ids";
import { BadRequest, NotFound, TooLarge } from "../lib/errors";
import { requireScope } from "../lib/auth";
import { hmacSign, timingSafeEqual } from "../lib/crypto";

const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024; // 25 MB

/**
 * Nested under /v1/notes — shapes: /:note_id/attachments (POST, GET)
 */
export const notesAttachments = new Hono<HonoBindings>();

/** POST /v1/notes/:note_id/attachments */
notesAttachments.post("/:note_id/attachments", requireScope("write"), async (c) => {
  const note_id = c.req.param("note_id");
  if (!isValidId(note_id)) throw BadRequest("invalid_id", "invalid note id");
  const user_id = c.var.auth.user_id;

  const owns = await c.env.DB.prepare(
    `SELECT 1 FROM notes WHERE id = ? AND user_id = ?`,
  )
    .bind(note_id, user_id)
    .first();
  if (!owns) throw NotFound("note not found");

  const form = await c.req.formData().catch(() => null);
  if (!form) throw BadRequest("invalid_body", "expected multipart/form-data");
  const file = form.get("file");
  if (!(file instanceof File)) throw BadRequest("missing_file", "file field is required");
  if (file.size > MAX_ATTACHMENT_BYTES) throw TooLarge(`max ${MAX_ATTACHMENT_BYTES} bytes`);

  const id = newId();
  const r2_key = `${user_id}/${note_id}/${id}`;
  await c.env.ATTACHMENTS.put(r2_key, file.stream(), {
    httpMetadata: { contentType: file.type || "application/octet-stream" },
  });

  await c.env.DB.prepare(
    `INSERT INTO attachments (id, note_id, user_id, r2_key, filename, content_type, size_bytes)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      note_id,
      user_id,
      r2_key,
      file.name || "attachment",
      file.type || "application/octet-stream",
      file.size,
    )
    .run();

  return c.json(
    {
      id,
      note_id,
      filename: file.name || "attachment",
      content_type: file.type || "application/octet-stream",
      size_bytes: file.size,
      created_at: new Date().toISOString(),
      url: await signAttachmentUrl(c.env, c.req.url, id),
    },
    201,
  );
});

/** GET /v1/notes/:note_id/attachments */
notesAttachments.get("/:note_id/attachments", requireScope("read"), async (c) => {
  const note_id = c.req.param("note_id");
  if (!isValidId(note_id)) throw BadRequest("invalid_id", "invalid note id");
  const user_id = c.var.auth.user_id;

  const { results } = await c.env.DB.prepare(
    `SELECT id, filename, content_type, size_bytes, created_at
       FROM attachments WHERE note_id = ? AND user_id = ?
       ORDER BY created_at DESC`,
  )
    .bind(note_id, user_id)
    .all<{
      id: string;
      filename: string;
      content_type: string;
      size_bytes: number;
      created_at: string;
    }>();

  const attachments = await Promise.all(
    results.map(async (r) => ({
      ...r,
      note_id,
      url: await signAttachmentUrl(c.env, c.req.url, r.id),
    })),
  );
  return c.json({ attachments });
});

/**
 * Top-level /v1/attachments/:id/download — signed URL, no auth header.
 * Lets you drop <img> tags pointing at notekeeper in rendered markdown.
 */
export const attachmentsDownload = new Hono<HonoBindings>();

attachmentsDownload.get("/:id/download", async (c) => {
  const id = c.req.param("id");
  if (!isValidId(id)) throw BadRequest("invalid_id", "invalid id");

  const exp = Number(c.req.query("exp"));
  const sig = c.req.query("sig");
  if (!exp || !sig) throw BadRequest("invalid_signature", "missing exp or sig");
  if (Date.now() / 1000 > exp) throw BadRequest("expired", "signature expired");

  const expected = await hmacSign(c.env.ATTACHMENT_SIGNING_SECRET, `${id}:${exp}`);
  if (!timingSafeEqual(expected, sig)) throw BadRequest("invalid_signature", "bad sig");

  const att = await c.env.DB.prepare(
    `SELECT r2_key, filename, content_type FROM attachments WHERE id = ?`,
  )
    .bind(id)
    .first<{ r2_key: string; filename: string; content_type: string }>();
  if (!att) throw NotFound("attachment not found");

  const obj = await c.env.ATTACHMENTS.get(att.r2_key);
  if (!obj) throw NotFound("attachment missing from storage");

  return new Response(obj.body, {
    headers: {
      "content-type": att.content_type,
      "content-disposition": `inline; filename="${att.filename.replaceAll('"', '')}"`,
      "cache-control": "private, max-age=3600",
    },
  });
});

async function signAttachmentUrl(
  env: HonoBindings["Bindings"],
  reqUrl: string,
  id: string,
): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const sig = await hmacSign(env.ATTACHMENT_SIGNING_SECRET, `${id}:${exp}`);
  const origin = new URL(reqUrl).origin;
  return `${origin}/v1/attachments/${id}/download?exp=${exp}&sig=${sig}`;
}
