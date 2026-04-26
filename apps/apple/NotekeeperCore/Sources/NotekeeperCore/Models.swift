import Foundation

// Types mirror the Zod schemas in packages/shared/src/index.ts. Keep them
// in sync. When the server adds a field, add it here as optional first so
// old clients keep decoding, then make it required in a follow-up.

public struct Note: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let userId: String
    public let folderId: String?
    public let title: String
    public let body: String
    public let pinned: Bool
    public let locked: Bool
    public let tags: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let trashedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, body, pinned, locked, tags
        case userId = "user_id"
        case folderId = "folder_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case trashedAt = "trashed_at"
    }
}

public struct NoteCreate: Codable, Sendable {
    public var title: String?
    public var body: String?
    public var folderId: String?
    public var tags: [String]?
    public var pinned: Bool?

    enum CodingKeys: String, CodingKey {
        case title, body, tags, pinned
        case folderId = "folder_id"
    }

    public init(
        title: String? = nil,
        body: String? = nil,
        folderId: String? = nil,
        tags: [String]? = nil,
        pinned: Bool? = nil
    ) {
        self.title = title
        self.body = body
        self.folderId = folderId
        self.tags = tags
        self.pinned = pinned
    }
}

public struct NoteUpdate: Codable, Sendable {
    public var title: String?
    public var body: String?
    public var folderId: String?
    public var tags: [String]?
    public var pinned: Bool?
    public var locked: Bool?

    enum CodingKeys: String, CodingKey {
        case title, body, tags, pinned, locked
        case folderId = "folder_id"
    }

    public init(
        title: String? = nil,
        body: String? = nil,
        folderId: String? = nil,
        tags: [String]? = nil,
        pinned: Bool? = nil,
        locked: Bool? = nil
    ) {
        self.title = title
        self.body = body
        self.folderId = folderId
        self.tags = tags
        self.pinned = pinned
        self.locked = locked
    }
}

public struct NoteListResponse: Codable, Sendable {
    public let notes: [Note]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case notes
        case nextCursor = "next_cursor"
    }
}

public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let userId: String
    public let parentId: String?
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case userId = "user_id"
        case parentId = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct FolderCreate: Codable, Sendable {
    public var name: String
    public var parentId: String?

    enum CodingKeys: String, CodingKey {
        case name
        case parentId = "parent_id"
    }

    public init(name: String, parentId: String? = nil) {
        self.name = name
        self.parentId = parentId
    }
}

public struct Tag: Codable, Hashable, Sendable {
    public let name: String
    public let count: Int
}

public struct TagListResponse: Codable, Sendable {
    public let tags: [Tag]
}

public struct SearchResult: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let folderId: String?
    public let pinned: Bool
    public let updatedAt: Date
    public let snippet: String
    public let score: Double

    enum CodingKeys: String, CodingKey {
        case id, title, pinned, snippet, score
        case folderId = "folder_id"
        case updatedAt = "updated_at"
    }
}

public struct SearchResponse: Codable, Sendable {
    public let query: String
    public let results: [SearchResult]
}

// MARK: - Sync (delta endpoint)

public enum TombstoneEntity: String, Codable, Sendable {
    case note
    case folder
}

public struct Tombstone: Codable, Hashable, Sendable {
    public let entity: TombstoneEntity
    public let id: String
    public let deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case entity, id
        case deletedAt = "deleted_at"
    }
}

public struct SyncResponse: Codable, Sendable {
    public let notes: [Note]
    public let folders: [Folder]
    public let tags: [Tag]
    public let deleted: [Tombstone]
    public let serverTime: Date
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case notes, folders, tags, deleted, truncated
        case serverTime = "server_time"
    }
}
