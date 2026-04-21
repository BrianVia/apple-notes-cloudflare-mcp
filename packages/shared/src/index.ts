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

// ─── Errors ─────────────────────────────────────────────────────────────────

export const ErrorResponseSchema = z.object({
  error: z.object({
    code: z.string(),
    message: z.string(),
    details: z.unknown().optional(),
  }),
});
export type ErrorResponse = z.infer<typeof ErrorResponseSchema>;
