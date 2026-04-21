import Foundation

public enum NotekeeperError: Error, Sendable, CustomStringConvertible {
    case http(status: Int, code: String, message: String, details: String?)
    case network(underlying: Error)
    case decoding(String)
    case invalidResponse

    public var description: String {
        switch self {
        case let .http(status, code, message, _):
            return "HTTP \(status) (\(code)): \(message)"
        case let .network(err):
            return "network error: \(err.localizedDescription)"
        case let .decoding(msg):
            return "decoding error: \(msg)"
        case .invalidResponse:
            return "invalid response"
        }
    }

    public var isUnauthorized: Bool {
        if case let .http(status, _, _, _) = self, status == 401 { return true }
        return false
    }
}

struct ServerErrorPayload: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
        let details: AnyDecodable?
    }
    let error: ErrorBody
}

struct AnyDecodable: Decodable {
    let raw: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) {
            raw = v
        } else if let v = try? container.decode([String: AnyDecodable].self) {
            raw = String(describing: v)
        } else if let v = try? container.decode([AnyDecodable].self) {
            raw = String(describing: v)
        } else {
            raw = "<unrepresentable>"
        }
    }
}
