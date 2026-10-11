import Foundation
import Security
import GoMiningCore

enum CredentialError: LocalizedError {
    case keychain(OSStatus)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Schlüsselbund-Fehler \(status)"
        case .unreadable: return "Gespeicherte Zugangsdaten sind nicht lesbar"
        }
    }
}

/// Legt den BingX-Lesezugang im macOS-Schluesselbund ab (gleicher Dienstname wie in der Vorgaengerversion).
enum CredentialStore {
    static let service = "com.sebastian.gominingbot.bingx.readonly"
    private static let account = "credentials"

    static func save(_ credentials: BingXCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    static func load() throws -> BingXCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = item as? Data, let credentials = try? JSONDecoder().decode(BingXCredentials.self, from: data),
              !credentials.apiKey.isEmpty, !credentials.secretKey.isEmpty else { throw CredentialError.unreadable }
        return credentials
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
