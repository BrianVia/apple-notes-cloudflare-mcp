import type { NoteDO } from "../do/note-do";

export interface Env {
  DB: D1Database;
  CACHE: KVNamespace;
  ATTACHMENTS: R2Bucket;
  NOTE_DO: DurableObjectNamespace;

  ENVIRONMENT: "development" | "production";
  JWT_SECRET: string;
  ATTACHMENT_SIGNING_SECRET: string;
}

// What our auth middleware attaches to the Hono context.
export interface AuthContext {
  user_id: string;
  auth_method: "api_key" | "oauth";
  scopes: string[];
  // For api_key auth, the key id (so we can update last_used_at async)
  api_key_id?: string;
}

export type HonoBindings = {
  Bindings: Env;
  Variables: {
    auth: AuthContext;
  };
};
