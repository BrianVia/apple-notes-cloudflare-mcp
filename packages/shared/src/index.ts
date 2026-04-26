import { z } from "zod";

// ─── Primitive schemas ──────────────────────────────────────────────────────

export const IdSchema = z.string().regex(/^[a-z0-9]{24}$/, "invalid id");
export const TimestampSchema = z.string().datetime();

// ─── Note ───────────────────────────────────────────────────────────────────

export const NoteSchema = z.object({
  id: IdSchema,
  user_id: IdSchema,
  folder_id: IdSchema.nullable(),
  title: z.string().max(500),
  body: z.string(), // markdown
  pinned: z.boolean(),
  locked: z.boolean(),
  tags: z.array(z.string().max(64)),
  created_at: TimestampSchema,
  updated_at: TimestampSchema,
  trashed_at: TimestampSchema.nullable(),
});
export type Note = z.infer<typeof NoteSchema>;

export const NoteCreateSchema = z.object({
  title: z.string().max(500).optional(),
  body: z.string().optional().default(""),
  folder_id: IdSchema.nullable().optional(),
  tags: z.array(z.string().max(64)).optional().default([]),
  pinned: z.boolean().optional().default(false),
  // When importing notes from another source (e.g., Apple Notes export),
  // callers can preserve the original timestamps. Omitted ⇒ server sets both
  // to "now" at create time.
  created_at: TimestampSchema.optional(),
  updated_at: TimestampSchema.optional(),
});
export type NoteCreate = z.infer<typeof NoteCreateSchema>;

export const NoteUpdateSchema = NoteCreateSchema.partial().extend({
  locked: z.boolean().optional(),
});
export type NoteUpdate = z.infer<typeof NoteUpdateSchema>;

export const NoteListQuerySchema = z.object({
  folder_id: IdSchema.nullable().optional(),
  tag: z.string().optional(),
  q: z.string().optional(),
  trashed: z.coerce.boolean().optional().default(false),
  limit: z.coerce.number().int().min(1).max(200).optional().default(50),
  cursor: z.string().optional(),
});
export type NoteListQuery = z.infer<typeof NoteListQuerySchema>;

// ─── Folder ─────────────────────────────────────────────────────────────────

export const FolderSchema = z.object({
  id: IdSchema,
  user_id: IdSchema,
  parent_id: IdSchema.nullable(),
  name: z.string().min(1).max(255),
  created_at: TimestampSchema,
  updated_at: TimestampSchema,
});
export type Folder = z.infer<typeof FolderSchema>;

export const FolderCreateSchema = z.object({
  name: z.string().min(1).max(255),
  parent_id: IdSchema.nullable().optional(),
});
export type FolderCreate = z.infer<typeof FolderCreateSchema>;

export const FolderUpdateSchema = FolderCreateSchema.partial();
export type FolderUpdate = z.infer<typeof FolderUpdateSchema>;

// ─── Tag ────────────────────────────────────────────────────────────────────

export const TagSchema = z.object({
  name: z.string().max(64),
  count: z.number().int().nonnegative(),
});
export type Tag = z.infer<typeof TagSchema>;

// ─── API keys ───────────────────────────────────────────────────────────────

export const ApiKeyScopeSchema = z.enum(["read", "write", "admin"]);
export type ApiKeyScope = z.infer<typeof ApiKeyScopeSchema>;

export const ApiKeySchema = z.object({
  id: IdSchema,
  name: z.string().max(100),
  prefix: z.string(), // first 12 chars for display (nk_live_abcd)
  scopes: z.array(ApiKeyScopeSchema),
  last_used_at: TimestampSchema.nullable(),
  created_at: TimestampSchema,
  expires_at: TimestampSchema.nullable(),
});
export type ApiKey = z.infer<typeof ApiKeySchema>;

export const ApiKeyCreateSchema = z.object({
  name: z.string().min(1).max(100),
  scopes: z.array(ApiKeyScopeSchema).min(1),
  expires_in_days: z.number().int().min(1).max(3650).optional(),
});
export type ApiKeyCreate = z.infer<typeof ApiKeyCreateSchema>;

// Returned ONCE on creation, never again
export const ApiKeyWithSecretSchema = ApiKeySchema.extend({
  secret: z.string(), // full nk_live_... token
});
export type ApiKeyWithSecret = z.infer<typeof ApiKeyWithSecretSchema>;

// ─── Attachments ────────────────────────────────────────────────────────────

export const AttachmentSchema = z.object({
  id: IdSchema,
  note_id: IdSchema,
  filename: z.string(),
  content_type: z.string(),
  size_bytes: z.number().int().nonnegative(),
  created_at: TimestampSchema,
  url: z.string().url(), // signed R2 URL
});
export type Attachment = z.infer<typeof AttachmentSchema>;

// ─── Sync (delta) ───────────────────────────────────────────────────────────
//
// Powers the local SQLite cache on Mac/iOS clients. Clients call
// GET /v1/sync?since=<ISO> and apply the response to their local store. The
// `server_time` field is the cursor for the next call.

export const TombstoneEntitySchema = z.enum(["note", "folder"]);
export type TombstoneEntity = z.infer<typeof TombstoneEntitySchema>;

export const TombstoneSchema = z.object({
  entity: TombstoneEntitySchema,
  id: IdSchema,
  deleted_at: TimestampSchema,
});
export type Tombstone = z.infer<typeof TombstoneSchema>;

export const SyncQuerySchema = z.object({
  since: TimestampSchema.optional(),
  limit: z.coerce.number().int().min(1).max(2000).optional().default(500),
});
export type SyncQuery = z.infer<typeof SyncQuerySchema>;

export const SyncResponseSchema = z.object({
  notes: z.array(NoteSchema),
  folders: z.array(FolderSchema),
  tags: z.array(TagSchema),
  deleted: z.array(TombstoneSchema),
  // Cursor for the next call. Equals the largest updated_at/deleted_at this
  // page actually returned (NOT now()) so a paused or paginated client can't
  // skip changes that landed mid-request.
  server_time: TimestampSchema,
  // True if the page was capped at `limit`. Clients should re-issue with
  // since=server_time until this is false.
  truncated: z.boolean(),
});
export type SyncResponse = z.infer<typeof SyncResponseSchema>;

// ─── Errors ─────────────────────────────────────────────────────────────────

export const ErrorResponseSchema = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
    details: z.unknown().optional(),
  }),
});
export type ErrorResponse = z.infer<typeof ErrorResponseSchema>;
