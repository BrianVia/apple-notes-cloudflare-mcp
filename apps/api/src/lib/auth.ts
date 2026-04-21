import type { MiddlewareHandler } from "hono";
import { jwtVerify } from "jose";
import type { HonoBindings, AuthContext } from "./env";
import { sha256Hex } from "./crypto";
import { Unauthorized, Forbidden } from "./errors";

const API_KEY_PREFIX = "nk_live_";

async function authenticateApiKey(
  token: string,
  env: HonoBindings["Bindings"],
): Promise<AuthContext | null> {
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    `SELECT id, user_id, scopes, expires_at FROM api_keys WHERE secret_hash = ?`,
  )
    .bind(hash)
    .first<{
      id: string;
      user_id: string;
      scopes: string;
      expires_at: string | null;
    }>();

  if (!row) return null;
  if (row.expires_at && new Date(row.expires_at) < new Date()) return null;

  // Fire-and-forget touch of last_used_at (don't block the request)
  // In Workers, we'd wrap this in c.executionCtx.waitUntil at the call site.
  return {
    user_id: row.user_id,
    auth_method: "api_key",
    scopes: JSON.parse(row.scopes),
    api_key_id: row.id,
  };
}

async function authenticateJwt(
  token: string,
  env: HonoBindings["Bindings"],
): Promise<AuthContext | null> {
  try {
    const { payload } = await jwtVerify(
      token,
      new TextEncoder().encode(env.JWT_SECRET),
      { issuer: "notekeeper", audience: "notekeeper-api" },
    );
    if (!payload.sub || typeof payload.sub !== "string") return null;
    const scopes = Array.isArray(payload.scopes)
      ? (payload.scopes as string[])
      : ["read", "write"];
    return {
      user_id: payload.sub,
      auth_method: "oauth",
      scopes,
    };
  } catch {
    return null;
  }
}

/**
 * Main auth middleware. Checks Bearer token against either API keys or JWTs.
 * Attaches AuthContext to c.var.auth on success.
 */
export const requireAuth: MiddlewareHandler<HonoBindings> = async (c, next) => {
  const header = c.req.header("Authorization");
  if (!header?.startsWith("Bearer ")) {
    throw Unauthorized("missing bearer token");
  }
  const token = header.slice(7).trim();

  const auth = token.startsWith(API_KEY_PREFIX)
    ? await authenticateApiKey(token, c.env)
    : await authenticateJwt(token, c.env);

  if (!auth) throw Unauthorized("invalid or expired token");

  // Touch last_used_at for API keys, async.
  if (auth.api_key_id) {
    c.executionCtx.waitUntil(
      c.env.DB.prepare(
        `UPDATE api_keys SET last_used_at = ? WHERE id = ?`,
      )
        .bind(new Date().toISOString(), auth.api_key_id)
        .run(),
    );
  }

  c.set("auth", auth);
  await next();
};

/** Require a specific scope. Admin always satisfies. */
export function requireScope(scope: "read" | "write" | "admin"): MiddlewareHandler<HonoBindings> {
  return async (c, next) => {
    const auth = c.var.auth;
    if (!auth) throw Unauthorized();
    if (auth.scopes.includes("admin") || auth.scopes.includes(scope)) {
      await next();
      return;
    }
    throw Forbidden(`missing required scope: ${scope}`);
  };
}
