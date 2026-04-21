import XCTest
@testable import NotekeeperCore

final class ModelsTests: XCTestCase {
    func testNoteDecodesServerPayload() throws {
        let json = #"""
        {
          "id": "6vr5askf6vsogid424oggpyl",
          "user_id": "9kjd4y3bd1247f4jdfgf6bg0",
          "folder_id": null,
          "title": "Hello notekeeper",
          "body": "# Hello\n\nbody",
          "pinned": false,
          "locked": false,
          "tags": ["bootstrap", "test"],
          "created_at": "2026-04-21T14:21:20.822Z",
          "updated_at": "2026-04-21T14:21:50.648Z",
          "trashed_at": null
        }
        """#.data(using: .utf8)!

        let decoder = APIClient.makeDecoder()
        let note = try decoder.decode(Note.self, from: json)

        XCTAssertEqual(note.id, "6vr5askf6vsogid424oggpyl")
        XCTAssertEqual(note.title, "Hello notekeeper")
        XCTAssertEqual(note.tags, ["bootstrap", "test"])
        XCTAssertFalse(note.pinned)
        XCTAssertNil(note.folderId)
        XCTAssertNil(note.trashedAt)
        // Created date is within a millisecond of expected (822ms fractional).
        XCTAssertEqual(note.createdAt.timeIntervalSinceReferenceDate, 798474080.822, accuracy: 0.01)
    }

    func testNoteCreateOmitsNilKeys() throws {
        let encoder = APIClient.makeEncoder()
        let create = NoteCreate(body: "# hi")
        let data = try encoder.encode(create)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj.keys.sorted(), ["body"])
    }

    func testSearchResponseDecodes() throws {
        let json = #"""
        {
          "query": "bootstrap",
          "results": [{
            "id": "6vr5askf6vsogid424oggpyl",
            "title": "Hello notekeeper",
            "folder_id": null,
            "pinned": false,
            "updated_at": "2026-04-21T14:28:00.399Z",
            "snippet": "…<mark>bootstrap</mark>…",
            "score": -0.000001375
          }]
        }
        """#.data(using: .utf8)!
        let decoder = APIClient.makeDecoder()
        let response = try decoder.decode(SearchResponse.self, from: json)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertTrue(response.results[0].snippet.contains("<mark>"))
    }

    func testErrorPayloadDecodes() throws {
        let json = #"""
        {"error":{"code":"unauthorized","message":"missing bearer token"}}
        """#.data(using: .utf8)!
        let decoder = APIClient.makeDecoder()
        let payload = try decoder.decode(ServerErrorPayload.self, from: json)
        XCTAssertEqual(payload.error.code, "unauthorized")
        XCTAssertEqual(payload.error.message, "missing bearer token")
    }
}
