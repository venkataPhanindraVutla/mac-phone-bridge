import AMProtocol
import Foundation
import Security

/// One generic-password item in the login keychain (legacy file keychain).
public struct KeychainItem: Sendable {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    public func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw IdentityError.keychain(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Android Mirroring (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }

    /// Removes the item; nothing to do if it is not there.
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
    }
}

/// Paired phones as one JSON array in the login keychain.
public final class KeychainPairedPhoneStore: PairedPhoneStore, @unchecked Sendable {
    public static let defaultService = "io.github.anmirror.mac"
    private let item: KeychainItem
    private let lock = NSLock()

    public init(service: String = KeychainPairedPhoneStore.defaultService) {
        item = KeychainItem(service: service, account: "paired-phones")
    }

    public func all() throws -> [PairedPhone] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    public func save(_ phone: PairedPhone) throws {
        lock.lock(); defer { lock.unlock() }
        var phones = try load()
        if let i = phones.firstIndex(where: { $0.id == phone.id }) { phones[i] = phone } else { phones.append(phone) }
        try item.write(try JSONEncoder().encode(phones))
    }

    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let phones = try load().filter { $0.id != id }
        try item.write(try JSONEncoder().encode(phones))
    }

    private func load() throws -> [PairedPhone] {
        guard let data = try item.read() else { return [] }
        return try JSONDecoder().decode([PairedPhone].self, from: data)
    }
}

/// The discovery key (32 random bytes, created on first use) in the login keychain.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let item: KeychainItem
    private let lock = NSLock()

    public init(service: String = KeychainPairedPhoneStore.defaultService) {
        item = KeychainItem(service: service, account: "discovery-key")
    }

    public func discoveryKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let key = try item.read(), key.count == 32 { return key }
        let key = PairingCrypto.randomBytes(32)
        try item.write(key)
        return key
    }
}
