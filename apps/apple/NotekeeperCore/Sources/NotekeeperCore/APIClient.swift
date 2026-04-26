// `@preconcurrency` is needed on Linux (swift-corelibs-foundation) where URL
// and URLSession aren't yet Sendable. On Apple platforms these types already
// conform, and @preconcurrency is a no-op there.
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

public struct APIClientConfig: Sendable {
    public let endpoint: URL
    public let apiKey: String
    public let session: URLSession

    public init(endpoint: URL, apiKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.session = session
    }
}

/// Mirrors apps/cli/src/client.ts. Thread-safe: wrapped as an actor so
/// the shared encoder/decoder can't be raced across tasks.
public actor APIClient {
    private let config: APIClientConfig
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(_ config: APIClientConfig) {
        self.config = config
        self.decoder = Self.makeDecoder()
        self.encoder = Self.makeEncoder()
    }

    // MARK: - Auth

    /// Lightweight health+auth probe — used by login flows before saving creds.
    public func verify() async throws {
        _ = try await request(TagListResponse.self, method: "GET", path: "/v1/tags")
    }

    // MARK: - Notes

    public struct NoteListQuery: Sendable {
        public var folderId: String?
        public var tag: String?
        public var q: String?
        public var trashed: Bool = false
        public var limit: Int = 50
        public var cursor: String?

        public init(
            folderId: String? = nil,
            tag: String? = nil,
            q: String? = nil,
            trashed: Bool = false,
            limit: Int = 50,
            cursor: String? = nil
        ) {
            self.folderId = folderId
            self.tag = tag
            self.q = q
            self.trashed = trashed
            self.limit = limit
            self.cursor = cursor
        }
    }

    public func listNotes(_ query: NoteListQuery = .init()) async throws -> NoteListResponse {
        var items: [URLQueryItem] = []
        if let v = query.folderId { items.append(.init(name: "folder_id", value: v)) }
        if let v = query.tag { items.append(.init(name: "tag", value: v)) }
        if let v = query.q { items.append(.init(name: "q", value: v)) }
        if query.trashed { items.append(.init(name: "trashed", value: "true")) }
        items.append(.init(name: "limit", value: String(query.limit)))
        if let v = query.cursor { items.append(.init(name: "cursor", value: v)) }
        return try await request(NoteListResponse.self, method: "GET", path: "/v1/notes", query: items)
    }

    public func createNote(_ body: NoteCreate) async throws -> Note {
        try await request(Note.self, method: "POST", path: "/v1/notes", jsonBody: body)
    }

    public func getNote(id: String) async throws -> Note {
        try await request(Note.self, method: "GET", path: "/v1/notes/\(id)")
    }

    public func updateNote(id: String, _ body: NoteUpdate) async throws -> Note {
        try await request(Note.self, method: "PATCH", path: "/v1/notes/\(id)", jsonBody: body)
    }

    public func deleteNote(id: String, hard: Bool = false) async throws {
        let query = hard ? [URLQueryItem(name: "hard", value: "true")] : []
        try await requestVoid(method: "DELETE", path: "/v1/notes/\(id)", query: query)
    }

    public func restoreNote(id: String) async throws {
        try await requestVoid(method: "POST", path: "/v1/notes/\(id)/restore")
    }

    // MARK: - Folders

    public struct FolderListResponse: Codable, Sendable {
        public let folders: [Folder]
    }

    public func listFolders() async throws -> [Folder] {
        let response = try await request(FolderListResponse.self, method: "GET", path: "/v1/folders")
        return response.folders
    }

    public func createFolder(_ body: FolderCreate) async throws -> Folder {
        try await request(Folder.self, method: "POST", path: "/v1/folders", jsonBody: body)
    }

    public func deleteFolder(id: String) async throws {
        try await requestVoid(method: "DELETE", path: "/v1/folders/\(id)")
    }

    // MARK: - Tags

    public func listTags() async throws -> [Tag] {
        let response = try await request(TagListResponse.self, method: "GET", path: "/v1/tags")
        return response.tags
    }

    // MARK: - Sync

    /// Fetch the delta of changes since the given cursor. Pass `nil` on the
    /// first call. Iterate until `truncated == false`, advancing `since` to
    /// the previous response's `serverTime` each time.
    public func sync(since: Date?, limit: Int = 500) async throws -> SyncResponse {
        var items: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
        ]
        if let since {
            // The server expects an ISO8601 string with fractional seconds —
            // matches what its own `updated_at` columns use.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(.init(name: "since", value: formatter.string(from: since)))
        }
        return try await request(SyncResponse.self, method: "GET", path: "/v1/sync", query: items)
    }

    // MARK: - Search

    public func search(_ q: String, limit: Int = 25) async throws -> SearchResponse {
        let items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return try await request(SearchResponse.self, method: "GET", path: "/v1/search", query: items)
    }

    // MARK: - Internals

    private func buildURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false) else {
            throw NotekeeperError.invalidResponse
        }
        // Preserve any endpoint path prefix the user configured, then append.
        let trimmed = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = trimmed + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NotekeeperError.invalidResponse }
        return url
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        jsonBody: Encodable? = nil
    ) async throws -> T {
        let data = try await rawRequest(method: method, path: path, query: query, jsonBody: jsonBody)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NotekeeperError.decoding("\(error)")
        }
    }

    private func requestVoid(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        jsonBody: Encodable? = nil
    ) async throws {
        _ = try await rawRequest(method: method, path: path, query: query, jsonBody: jsonBody)
    }

    private func rawRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        jsonBody: Encodable?
    ) async throws -> Data {
        let url = try buildURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try encoder.encode(AnyEncodable(jsonBody))
            } catch {
                throw NotekeeperError.decoding("encoding body: \(error)")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataAsync(for: req)
        } catch {
            throw NotekeeperError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NotekeeperError.invalidResponse
        }

        if http.statusCode == 204 {
            return Data()
        }

        if (200..<300).contains(http.statusCode) {
            return data
        }

        // Non-2xx — try to parse the server's structured error envelope.
        if let payload = try? decoder.decode(ServerErrorPayload.self, from: data) {
            throw NotekeeperError.http(
                status: http.statusCode,
                code: payload.error.code,
                message: payload.error.message,
                details: payload.error.details?.raw
            )
        }
        let fallback = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw NotekeeperError.http(
            status: http.statusCode,
            code: "http_error",
            message: "HTTP \(http.statusCode): \(fallback)",
            details: nil
        )
    }

    // `URLSession.data(for:)` exists on Apple but not in swift-corelibs
    // FoundationNetworking. This continuation wrapper is portable and behaves
    // identically on both. Slight overhead on Apple platforms; not measurable.
    private func dataAsync(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = config.session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }

    // MARK: - Encoder / decoder

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let str = try container.decode(String.self)
            // Server sends fractional seconds ("...822Z"). The stdlib's
            // .iso8601 strategy can't parse those, so use ISO8601DateFormatter
            // with the fractional-seconds option and fall back without.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "could not parse ISO8601 date: \(str)"
            )
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Allows encoding of `Encodable` existentials, which Swift's generics
/// can't handle directly.
private struct AnyEncodable: Encodable {
    let wrapped: Encodable
    init(_ wrapped: Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
