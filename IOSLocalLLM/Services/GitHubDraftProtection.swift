import Foundation
import CryptoKit
import Security

/// Repository snapshots may contain credentials being removed. Only encrypted
/// snapshots reach conversation storage; the device-only key stays in Keychain.
nonisolated enum GitHubDraftProtection {
    // Tests can supply a transient key through Codable's explicit context.
    // Production encoders leave this absent and always require Keychain.
    static let keyInfo = CodingUserInfoKey(rawValue: "ondevice.github.draft.key")!
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.token.TokenAI.github.drafts",
         kSecAttrAccount as String: "snapshot-key.v1"]
    }
    private static func key(create: Bool) throws -> SymmetricKey {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw GitHubError.keychain }
        let generated = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let inserted = SecItemAdd(item as CFDictionary, nil)
        if inserted == errSecDuplicateItem { return try key(create: false) }
        guard inserted == errSecSuccess else { throw GitHubError.keychain }
        return generated
    }
    static func seal(_ data: Data, context: String, using suppliedKey: SymmetricKey? = nil) throws -> Data {
        guard data.count <= 3_000_000 else { throw GitHubError.tooLarge }
        do {
            guard let combined = try AES.GCM.seal(data, using: suppliedKey ?? key(create: true), authenticating: Data(context.utf8)).combined else { throw GitHubError.keychain }
            return combined
        } catch { throw GitHubError.keychain }
    }
    static func open(_ data: Data, context: String, using suppliedKey: SymmetricKey? = nil) throws -> Data {
        guard data.count <= 3_000_028 else { throw GitHubError.tooLarge }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: suppliedKey ?? key(create: false), authenticating: Data(context.utf8)) }
        catch { throw GitHubError.keychain }
    }
    static func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubError.keychain }
    }
}
