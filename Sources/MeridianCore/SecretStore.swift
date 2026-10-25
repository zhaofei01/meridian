import Foundation
import Security

public protocol SecretStore: AnyObject {
    func save(account: String, secret: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case rejected
    case keychain(OSStatus)
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(account: String, secret: String) throws {
        guard SecretMaterial.isUsable(secret) else { throw SecretStoreError.rejected }
        lock.lock()
        values[account] = secret
        lock.unlock()
    }

    public func load(account: String) throws -> String? {
        lock.lock()
        let value = values[account]
        lock.unlock()
        return SecretMaterial.isUsable(value) ? value : nil
    }

    public func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}

public final class KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.meridian.desktop") {
        self.service = service
    }

    public func save(account: String, secret: String) throws {
        guard SecretMaterial.isUsable(secret) else { throw SecretStoreError.rejected }
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.keychain(status)
        }
        return SecretMaterial.isUsable(text) ? text : nil
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }
}
