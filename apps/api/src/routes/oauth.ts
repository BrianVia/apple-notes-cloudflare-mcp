import { Hono } from "hono";
import { z } from "zod";
import { SignJWT } from "jose";
import type { HonoBindings } from "../lib/env";
import { BadRequest, Unauthorized } from "../lib/errors";
import { sha256Hex, randomToken, timingSafeEqual } from "../lib/crypto";

const app = new Hono<HonoBindings>();

/**
 * OAuth 2.0 Authorization Code Flow with PKCE.
 *
 * This is a deliberately minimal implementation — enough for first-party
 * and trusted third-party apps. If you plan to open this up broadly,
 * you'll want scopes-per-client, consent UX, token introspection, etc.
 *
 * Flow:
 *   1. Client redirects user to /v1/oauth/authorize?client_id=...&code_challenge=...
 *   2. User authenticates (out of scope here — you'd plug in Apple Sign In,
 *      email magic link, or similar). For now, we expect an `Authorization:
 *      Bearer <session_jwt>` header which the UI shell would have set.
 *   3. We issue an authorization `code` and redirect back with it.
 *   4. Client POSTs to /v1/oauth/token with code + code_verifier → gets
 *      access_token (JWT, 1h) + refresh_token (opaque, 90d).
 */

const AuthorizeSchema = z.object({
  client_id: z.string(),
  redirect_uri: z.string().url(),
  response_type: z.literal("code"),
  code_challenge: z.string().min(43).max(128),
  code_challenge_method: z.literal("S256"),
  scope: z.string().optional(),
  state: z.string().optional(),
});

app.post("/authorize", async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = AuthorizeSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_request", "invalid authorize params", parsed.error.format());

  // Expect a session token from the host app's UI.
  const session = c.req.header("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!session) throw Unauthorized("login required");
  const { authenticateForWs } = await import("../lib/auth-ws");
  const auth = await authenticateForWs(session, c.env);
  if (!auth) throw Unauthorized("invalid session");

  const client = await c.env.DB.prepare(
    `SELECT id, redirect_uris FROM oauth_clients WHERE id = ?`,
  )
    .bind(parsed.data.client_id)
    .first<{ id: string; redirect_uris: string }>();
  if (!client) throw BadRequest("invalid_client", "unknown client");

  const allowed: string[] = JSON.parse(client.redirect_uris);
  if (!allowed.includes(parsed.data.redirect_uri)) {
    throw BadRequest("invalid_redirect_uri", "redirect_uri not registered");
  }

  const code = randomToken(32);
  const expires_at = new Date(Date.now() + 10 * 60_000).toISOString(); // 10 min
  const scopes = parsed.data.scope?.split(/\s+/).filter(Boolean) ?? ["read", "write"];

  await c.env.DB.prepare(
    `INSERT INTO oauth_codes (code, client_id, user_id, redirect_uri, code_challenge, code_challenge_method, scopes, expires_at, used)
     VALUES (?, ?, ?, ?, ?, 'S256', ?, ?, 0)`,
  )
    .bind(
      code,
      client.id,
      auth.user_id,
      parsed.data.redirect_uri,
      parsed.data.code_challenge,
      JSON.stringify(scopes),
      expires_at,
    )
    .run();

  const redirect = new URL(parsed.data.redirect_uri);
  redirect.searchParams.set("code", code);
  if (parsed.data.state) redirect.searchParams.set("state", parsed.data.state);
  return c.json({ redirect_uri: redirect.toString(), code_expires_at: expires_at });
});

const TokenSchema = z.discriminatedUnion("grant_type", [
  z.object({
    grant_type: z.literal("authorization_code"),
    code: z.string(),
    redirect_uri: z.string().url(),
    client_id: z.string(),
    code_verifier: z.string().min(43).max(128),
  }),
  z.object({
    grant_type: z.literal("refresh_token"),
    refresh_token: z.string(),
    client_id: z.string(),
  }),
]);

app.post("/token", async (c) => {
  const body = await c.req.json().catch(() => null);
  const parsed = TokenSchema.safeParse(body);
  if (!parsed.success) throw BadRequest("invalid_request", "invalid token request", parsed.error.format());

  if (parsed.data.grant_type === "authorization_code") {
    const codeRow = await c.env.DB.prepare(
      `SELECT * FROM oauth_codes WHERE code = ?`,
    )
      .bind(parsed.data.code)
      .first<{
        code: string;
        client_id: string;
        user_id: string;
        redirect_uri: string;
        code_challenge: string;
        scopes: string;
        expires_at: string;
        used: number;
      }>();
    if (!codeRow) throw BadRequest("invalid_grant", "unknown code");
    if (codeRow.used) throw BadRequest("invalid_grant", "code already used");
    if (new Date(codeRow.expires_at) < new Date()) throw BadRequest("invalid_grant", "code expired");
    if (codeRow.client_id !== parsed.data.client_id) throw BadRequest("invalid_grant", "client mismatch");
    if (codeRow.redirect_uri !== parsed.data.redirect_uri) throw BadRequest("invalid_grant", "redirect mismatch");

    // PKCE verify: SHA-256(code_verifier) base64url == code_challenge
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(parsed.data.code_verifier),
    );
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replaceAll("=", "");
    if (!timingSafeEqual(challenge, codeRow.code_challenge)) {
      throw BadRequest("invalid_grant", "pkce verification failed");
    }

    // Mark code used (atomic; prevents replay).
    const markUsed = await c.env.DB.prepare(
      `UPDATE oauth_codes SET used = 1 WHERE code = ? AND used = 0`,
    )
      .bind(parsed.data.code)
      .run();
    if (markUsed.meta.changes === 0) throw BadRequest("invalid_grant", "code race");

    const scopes: string[] = JSON.parse(codeRow.scopes);
    return c.json(await issueTokens(c.env, codeRow.user_id, codeRow.client_id, scopes));
  }

  // refresh_token grant
  const hash = await sha256Hex(parsed.data.refresh_token);
  const rt = await c.env.DB.prepare(
    `SELECT * FROM oauth_refresh_tokens WHERE token_hash = ?`,
  )
    .bind(hash)
    .first<{
      token_hash: string;
      client_id: string;
      user_id: string;
      scopes: string;
      expires_at: string;
      revoked: number;
    }>();
  if (!rt || rt.revoked) throw BadRequest("invalid_grant", "invalid refresh token");
  if (rt.client_id !== parsed.data.client_id) throw BadRequest("invalid_grant", "client mismatch");
  if (new Date(rt.expires_at) < new Date()) throw BadRequest("invalid_grant", "refresh token expired");

  // Rotate: revoke old, issue new.
  await c.env.DB.prepare(
    `UPDATE oauth_refresh_tokens SET revoked = 1 WHERE token_hash = ?`,
  )
    .bind(hash)
    .run();

  return c.json(await issueTokens(c.env, rt.user_id, rt.client_id, JSON.parse(rt.scopes)));
});

async function issueTokens(
  env: HonoBindings["Bindings"],
  user_id: string,
  client_id: string,
  scopes: string[],
) {
  const access_token = await new SignJWT({ scopes })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(user_id)
    .setIssuer("notekeeper")
    .setAudience("notekeeper-api")
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(env.JWT_SECRET));

  const refresh_token = randomToken(48);
  const refresh_hash = await sha256Hex(refresh_token);
  const refresh_exp = new Date(Date.now() + 90 * 86400_000).toISOString();

  await env.DB.prepare(
    `INSERT INTO oauth_refresh_tokens (token_hash, client_id, user_id, scopes, expires_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(refresh_hash, client_id, user_id, JSON.stringify(scopes), refresh_exp)
    .run();

  return {
    access_token,
    token_type: "Bearer",
    expires_in: 3600,
    refresh_token,
    scope: scopes.join(" "),
  };
}

export default app;
