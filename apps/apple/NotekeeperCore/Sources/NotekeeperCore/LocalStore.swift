import Foundation
import GRDB

/// Local SQLite mirror of the user's notes/folders/tags. Powers instant cold-
/// start paint and offline reads on the Mac client. Wraps a `DatabasePool`
/// so reads don't block writes; the actor keeps higher-level mutation
/// sequences serialized.
///
/// One database file per install (`cache.sqlite`). Account changes wipe and
/// resync — handled at the AppModel layer when the keychain user_id flips.
public actor LocalStore {
    private let dbPool: DatabasePool
    private let path: String

    public var databasePath: String { path }

    // MARK: - Init

    public init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = appSupport.appendingPathComponent("Notekeeper", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.sqlite")
        var config = Configuration()
        config.label = "notekeeper-localstore"
        let pool = try DatabasePool(path: url.path, configuration: config)
        try LocalStore.migrator.migrate(pool)
        self.dbPool = pool
        self.path = url.path
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("folder_id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("pinned", .integer).notNull().defaults(to: 0)
                t.column("locked", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("trashed_at", .text)
                t.column("server_updated_at", .text)
                t.column("dirty", .integer).notNull().defaults(to: 0)
            }
            try db.create(indexOn: "notes", columns: ["pinned", "updated_at"])
            try db.create(indexOn: "notes", columns: ["folder_id"])
            try db.create(indexOn: "notes", columns: ["dirty"])

            try db.create(table: "folders") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("parent_id", .text)
                t.column("name", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "tags") { t in
                t.column("name", .text).primaryKey()
                t.column("count", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "note_tags") { t in
                t.column("note_id", .text).notNull()
                t.column("tag_name", .text).notNull()
                t.primaryKey(["note_id", "tag_name"])
            }

            try db.create(table: "sync_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        return m
    }

    // MARK: - Snapshot for instant paint

    public struct Snapshot: Sendable {
        public let notes: [Note]
        public let folders: [Folder]
        public let tags: [Tag]
    }

    /// Pull every locally-known note. Trashed notes are included so the
    /// AppModel can filter them out (or in, for the "Recently Deleted"
    /// sidebar) without a second query.
    public func snapshot() throws -> Snapshot {
        try dbPool.read { db in
            let localNotes = try LocalNote
                .order(
                    Column("pinned").desc,
                    Column("updated_at").desc
                )
                .fetchAll(db)

            let tagsByNote = try LocalStore.fetchTagsByNote(noteIds: localNotes.map(\.id), db: db)

            let notes = localNotes.map { $0.toNote(tags: tagsByNote[$0.id] ?? []) }

            let localFolders = try LocalFolder
                .order(Column("name").collating(.nocase))
                .fetchAll(db)
            let folders = localFolders.map { $0.toFolder() }

            let tagRows = try LocalTag
                .order(
                    Column("count").desc,
                    Column("name")
                )
                .fetchAll(db)
            let tags = tagRows.map { Tag(name: $0.name, count: $0.count) }

            return Snapshot(notes: notes, folders: folders, tags: tags)
        }
    }

    public func fetchNote(id: String) throws -> Note? {
        try dbPool.read { db in
            guard let local = try LocalNote.fetchOne(db, key: id) else { return nil }
            let tagRows = try Row.fetchAll(
                db,
                sql: "SELECT tag_name FROM note_tags WHERE note_id = ? ORDER BY tag_name",
                arguments: [id]
            )
            let tags = tagRows.map { $0["tag_name"] as String }
            return local.toNote(tags: tags)
        }
    }

    // MARK: - Sync apply

    /// Apply a server delta to the local store. Last-writer-wins on the
    /// `dirty` rows: if the server's `updated_at` is newer than the local
    /// dirty value, the server wins (any local edit is dropped). Tags are
    /// replaced wholesale because the server returns the full set.
    public func apply(_ response: SyncResponse) throws {
        try dbPool.write { db in
            for note in response.notes {
                try LocalStore.upsertNote(note, in: db)
            }
            for folder in response.folders {
                try LocalFolder(from: folder).save(db)
            }
            // Replace tag counts wholesale — server returns the full list.
            try LocalTag.deleteAll(db)
            for tag in response.tags {
                try LocalTag(name: tag.name, count: tag.count).save(db)
            }
            for tomb in response.deleted {
                switch tomb.entity {
                case .note:
                    try db.execute(
                        sql: "DELETE FROM note_tags WHERE note_id = ?",
                        arguments: [tomb.id]
                    )
                    _ = try LocalNote.deleteOne(db, key: tomb.id)
                case .folder:
                    _ = try LocalFolder.deleteOne(db, key: tomb.id)
                }
            }
            try SyncMeta(key: "cursor", value: ISODate.string(response.serverTime)).save(db)
        }
    }

    /// Upsert a single note (after a local create / pin toggle). Doesn't
    /// touch tags or folders — those land via the next sync. Bypasses the
    /// dirty-protection in `apply` because the caller is asserting this is
    /// the authoritative server response.
    public func upsertServerNote(_ note: Note) throws {
        try dbPool.write { db in
            var local = LocalNote(from: note)
            try local.save(db)
            try db.execute(
                sql: "DELETE FROM note_tags WHERE note_id = ?",
                arguments: [note.id]
            )
            for t in note.tags {
                try LocalNoteTag(note_id: note.id, tag_name: t).save(db)
            }
        }
    }

    private static func upsertNote(_ note: Note, in db: Database) throws {
        if let existing = try LocalNote.fetchOne(db, key: note.id), existing.dirty == 1 {
            // Local has unsaved edits. Keep them unless the server's copy is
            // strictly newer (last-writer-wins). Same-timestamp ⇒ keep local.
            let existingDate = ISODate.parse(existing.updated_at)
            if note.updatedAt <= (existingDate ?? .distantPast) {
                return
            }
        }
        var local = LocalNote(from: note)
        try local.save(db)
        try db.execute(
            sql: "DELETE FROM note_tags WHERE note_id = ?",
            arguments: [note.id]
        )
        for t in note.tags {
            try LocalNoteTag(note_id: note.id, tag_name: t).save(db)
        }
    }

    // MARK: - Cursor

    public func cursor() throws -> Date? {
        try dbPool.read { db in
            guard let row = try SyncMeta.fetchOne(db, key: "cursor") else { return nil }
            return ISODate.parse(row.value)
        }
    }

    // MARK: - Dirty queue

    public struct PendingNote: Sendable, Equatable {
        public let id: String
        public let title: String
        public let body: String
        public let updatedAt: Date
    }

    /// Mark a note's body (and optionally title) as dirty so the next push
    /// cycle PATCHes it. Updates the local `updated_at` to now() so the
    /// optimistic UI ordering stays correct.
    public func markDirty(noteId: String, body: String, title: String?) throws {
        try dbPool.write { db in
            guard var note = try LocalNote.fetchOne(db, key: noteId) else {
                throw LocalStoreError.noteNotFound(noteId)
            }
            note.body = body
            if let title { note.title = title }
            note.updated_at = ISODate.string(Date())
            note.dirty = 1
            try note.update(db)
        }
    }

    public func nextDirty(limit: Int = 25) throws -> [PendingNote] {
        try dbPool.read { db in
            try LocalNote
                .filter(Column("dirty") == 1)
                .order(Column("updated_at"))
                .limit(limit)
                .fetchAll(db)
                .map { row in
                    PendingNote(
                        id: row.id,
                        title: row.title,
                        body: row.body,
                        updatedAt: ISODate.parse(row.updated_at) ?? Date()
                    )
                }
        }
    }

    /// Mark a dirty note as flushed — replaces the local row with the
    /// server's authoritative version returned from the PATCH response.
    public func clearDirty(noteId: String, serverNote: Note) throws {
        try dbPool.write { db in
            // Force overwrite even though dirty=1 — this is exactly the path
            // we just confirmed succeeded server-side.
            var local = LocalNote(from: serverNote)
            try local.save(db)
            try db.execute(
                sql: "DELETE FROM note_tags WHERE note_id = ?",
                arguments: [serverNote.id]
            )
            for t in serverNote.tags {
                try LocalNoteTag(note_id: serverNote.id, tag_name: t).save(db)
            }
        }
    }

    /// Wipe everything. Called when the credential's userId changes.
    public func wipe() throws {
        try dbPool.write { db in
            try LocalNote.deleteAll(db)
            try LocalFolder.deleteAll(db)
            try LocalTag.deleteAll(db)
            try LocalNoteTag.deleteAll(db)
            try SyncMeta.deleteAll(db)
        }
    }

    // MARK: - Helpers

    private static func fetchTagsByNote(noteIds: [String], db: Database) throws -> [String: [String]] {
        guard !noteIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: noteIds.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT note_id, tag_name FROM note_tags WHERE note_id IN (\(placeholders)) ORDER BY tag_name",
            arguments: StatementArguments(noteIds)
        )
        var byNote: [String: [String]] = [:]
        for row in rows {
            let noteId = row["note_id"] as String
            let tagName = row["tag_name"] as String
            byNote[noteId, default: []].append(tagName)
        }
        return byNote
    }
}

// MARK: - Errors

public enum LocalStoreError: Error, Sendable {
    case noteNotFound(String)
}

// MARK: - Internal record types

fileprivate struct LocalNote: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var user_id: String
    var folder_id: String?
    var title: String
    var body: String
    var pinned: Int
    var locked: Int
    var created_at: String
    var updated_at: String
    var trashed_at: String?
    var server_updated_at: String?
    var dirty: Int

    static let databaseTableName = "notes"

    init(from note: Note) {
        self.id = note.id
        self.user_id = note.userId
        self.folder_id = note.folderId
        self.title = note.title
        self.body = note.body
        self.pinned = note.pinned ? 1 : 0
        self.locked = note.locked ? 1 : 0
        self.created_at = ISODate.string(note.createdAt)
        self.updated_at = ISODate.string(note.updatedAt)
        self.trashed_at = note.trashedAt.map(ISODate.string)
        self.server_updated_at = self.updated_at
        self.dirty = 0
    }

    func toNote(tags: [String]) -> Note {
        Note(
            id: id,
            userId: user_id,
            folderId: folder_id,
            title: title,
            body: body,
            pinned: pinned == 1,
            locked: locked == 1,
            tags: tags,
            createdAt: ISODate.parse(created_at) ?? .distantPast,
            updatedAt: ISODate.parse(updated_at) ?? .distantPast,
            trashedAt: trashed_at.flatMap(ISODate.parse)
        )
    }
}

fileprivate struct LocalFolder: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var user_id: String
    var parent_id: String?
    var name: String
    var created_at: String
    var updated_at: String

    static let databaseTableName = "folders"

    init(from folder: Folder) {
        self.id = folder.id
        self.user_id = folder.userId
        self.parent_id = folder.parentId
        self.name = folder.name
        self.created_at = ISODate.string(folder.createdAt)
        self.updated_at = ISODate.string(folder.updatedAt)
    }

    func toFolder() -> Folder {
        Folder(
            id: id,
            userId: user_id,
            parentId: parent_id,
            name: name,
            createdAt: ISODate.parse(created_at) ?? .distantPast,
            updatedAt: ISODate.parse(updated_at) ?? .distantPast
        )
    }
}

fileprivate struct LocalTag: Codable, FetchableRecord, PersistableRecord {
    var name: String
    var count: Int

    static let databaseTableName = "tags"
}

fileprivate struct LocalNoteTag: Codable, FetchableRecord, PersistableRecord {
    var note_id: String
    var tag_name: String

    static let databaseTableName = "note_tags"
}

fileprivate struct SyncMeta: Codable, FetchableRecord, PersistableRecord {
    var key: String
    var value: String

    static let databaseTableName = "sync_meta"
}

// MARK: - ISO date helper

/// Stringly-typed dates. Stored as ISO8601 with fractional seconds so they
/// sort lexicographically and exactly match the server's `updated_at` format.
fileprivate enum ISODate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func parse(_ s: String) -> Date? {
        if let d = formatter.date(from: s) { return d }
        // Fallback for strings without fractional seconds.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
