-- Tombstones for hard-deletes. Soft-deleted notes (trashed_at IS NOT NULL)
-- still appear in /v1/sync via their updated_at, so they don't need rows
-- here. This table only records permanent removals so caches can drop the
-- corresponding local rows. Tags are derivable from notes/note_tags on the
-- client side, so we only tombstone notes and folders.
CREATE TABLE IF NOT EXISTS tombstones (
  entity      TEXT NOT NULL,            -- 'note' | 'folder'
  id          TEXT NOT NULL,            -- the deleted entity's id
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  deleted_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (entity, id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_tombstones_user_deleted ON tombstones(user_id, deleted_at);
