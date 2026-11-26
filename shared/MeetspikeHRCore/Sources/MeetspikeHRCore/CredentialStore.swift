#if canImport(Security)
import Foundation
import Security

public enum CredentialStore {
    private struct KeychainError: Error {
        let status: OSStatus
    }

    static func item(protected: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.meetspike.hr",
            kSecAttrAccount as String: "worker-ingest"
        ]
        if protected { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    static func newItem(data: Data, protected: Bool) -> [String: Any] {
        var query = item(protected: protected)
        query[kSecValueData as String] = data
        if protected {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    public static func load() throws -> Credentials? {
        #if os(iOS)
        return try load(protected: true)
        #else
        do {
            if let credentials = try load(protected: true) { return credentials }
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // Local ad hoc bundles may only have access to the login keychain.
        }
        return try load(protected: false)
        #endif
    }

    private static func load(protected: Bool) throws -> Credentials? {
        var query = item(protected: protected)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        #if os(iOS)
        try save(data, protected: true)
        #else
        do {
            try save(data, protected: true)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            try save(data, protected: false)
        }
        #endif
    }

    private static func save(_ data: Data, protected: Bool) throws {
        let status = SecItemAdd(newItem(data: data, protected: protected) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var updates: [String: Any] = [kSecValueData as String: data]
            if protected {
                updates[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let updated = SecItemUpdate(item(protected: protected) as CFDictionary, updates as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}
#endif
