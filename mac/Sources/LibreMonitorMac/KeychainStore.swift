import Foundation
import Security

/// Keeps the follower login in the macOS Keychain (the counterpart of CredentialStore.cs, which uses DPAPI on Windows).
enum KeychainStore {
    private static let service = "io.github.bsalgueiro.LibreMonitor"
    private static let account = "follower-login"

    private struct Stored: Codable {
        let email: String
        let password: String
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not save the login to the Keychain (error \(status))." }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> (email: String, password: String)? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }

        return (stored.email, stored.password)
    }

    static func save(email: String, password: String) throws {
        let data = try JSONEncoder().encode(Stored(email: email, password: password))

        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
