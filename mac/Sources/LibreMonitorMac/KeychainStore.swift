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

        #if DEBUG
        try saveReadableByAnyBuild(data)
        #else
        try saveRestrictedToThisApp(data)
        #endif
    }

    /// Debug (test) builds only. Every build is ad-hoc signed with a new signature, and a Keychain item is normally
    /// readable only by the exact app that created it, so macOS asked for permission again after every new build.
    /// Here the item allows any application to read it without asking. That is weaker: any program running as the
    /// user could read this login. Release builds never do this.
    ///
    /// SecAccess is deprecated (the compiler says so once, in debug builds only), but it is the only way to build such
    /// an access list for the file-based keychain, which is the only keychain an app without an Apple Developer account
    /// can use. The whole function is compiled out of release builds.
    #if DEBUG
    private static func saveReadableByAnyBuild(_ data: Data) throws {
        // An item made earlier keeps its old restrictions on update, so replace it.
        SecItemDelete(baseQuery() as CFDictionary)

        var add = baseQuery()
        add[kSecValueData as String] = data

        var access: SecAccess?
        // A nil trusted-application list means "any application".
        if SecAccessCreate("Libre Monitor test login" as CFString, nil, &access) == errSecSuccess, let access {
            add[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    #endif

    /// Release builds: only the app that stored the login may read it (the default Keychain behaviour).
    private static func saveRestrictedToThisApp(_ data: Data) throws {
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
