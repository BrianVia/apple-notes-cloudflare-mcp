import { jwtVerify } from "jose";
import type { AuthContext, Env } from "./env";
import { sha256Hex } from "./crypto";

/** Parallel to requireAuth, but callable inline for WS upgrades. */
export async function authenticateForWs(
  token: string,
  env: Env,
): Promise<AuthContext | null> {
  if (token.startsWith("nk_live_")) {
    const hash = await sha256Hex(token);
    const row = await env.DB.prepare(
      `SELECT id, user_id, scopes, expires_at FROM api_keys WHERE secret_hash = ?`,
    )
      .bind(hash)
      .first<{ id: string; user_id: string; scopes: string; expires_at: string | null }>();
    if (!row) return null;
    if (row.expires_at && new Date(row.expires_at) < new Date()) return null;
    return {
      user_id: row.user_id,
      auth_method: "api_key",
      scopes: JSON.parse(row.scopes),
      api_key_id: row.id,
    };
  }
  try {
    const { payload } = await jwtVerify(
      token,
      new TextEncoder().encode(env.JWT_SECRET),
      { issuer: "notekeeper", audience: "notekeeper-api" },
    );
    if (typeof payload.sub !== "string") return null;
    return {
      user_id: payload.sub,
      auth_method: "oauth",
      scopes: Array.isArray(payload.scopes) ? (payload.scopes as string[]) : ["read", "write"],
    };
  } catch {
    return null;
  }
}
