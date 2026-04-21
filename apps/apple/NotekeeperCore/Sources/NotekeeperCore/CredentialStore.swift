import Foundation

#if canImport(Security)
import Security

public enum CredentialStoreError: Error, Sendable {
    case notFound
    case unexpectedStatus(OSStatus)
    case invalidPayload
}

public struct Credential: Codable, Sendable, Equatable {
    public let endpoint: URL
    public let apiKey: String
    public let userId: String?

    public init(endpoint: URL, apiKey: String, userId: String? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.userId = userId
    }
}

/// Keychain-backed credential storage. Uses kSecClassGenericPassword with
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly — the token stays on this
/// device, requires the keychain to be unlocked, and never leaves in
/// iCloud Keychain sync.
public final class KeychainCredentialStore {
    public let service: String
    public let account: String

    public init(
        service: String = "app.notekeeper.client",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)

        // Delete existing first — SecItemAdd fails with errSecDuplicateItem
        // if an entry already exists for this (service, account) pair.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func load() throws -> Credential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw CredentialStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data else {
            throw CredentialStoreError.invalidPayload
        }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }
}

#endif
