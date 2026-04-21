-- Fix FTS5 shadow table. The initial migration declared notes_fts with
-- `content='notes'` (external-content mode), but notes has no `tags`
-- column — tags are many-to-many via note_tags. SQLite errors with
-- "no such column: T.tags" on every read (SELECT, MATCH, count). Drop and
-- recreate as standalone FTS5, then backfill from the current data.

DROP TABLE IF EXISTS notes_fts;

CREATE VIRTUAL TABLE notes_fts USING fts5(
  title,
  body,
  tags,
  tokenize='porter unicode61'
);

-- Backfill. Preserve notes.rowid so existing join keys (`f.rowid = n.rowid`)
-- in search/list remain valid. Tags are aggregated as a space-separated string
-- so the FTS tokenizer can index them as individual terms.
INSERT INTO notes_fts (rowid, title, body, tags)
SELECT n.rowid,
       n.title,
       n.body,
       COALESCE(
         (SELECT group_concat(t.name, ' ')
            FROM note_tags nt
            JOIN tags t ON t.id = nt.tag_id
           WHERE nt.note_id = n.id),
         ''
       )
  FROM notes n;
