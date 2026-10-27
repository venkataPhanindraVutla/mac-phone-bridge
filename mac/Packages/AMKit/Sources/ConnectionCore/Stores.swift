import AMProtocol
import Foundation

public protocol PairedPhoneStore: Sendable {
    func all() throws -> [PairedPhone]
    /// Inserts, or replaces the phone with the same `id`.
    func save(_ phone: PairedPhone) throws
    func remove(id: String) throws
}

public protocol SecretStore: Sendable {
    /// The discovery key (32 bytes); created on first use and stable afterwards.
    func discoveryKey() throws -> Data
}

public final class InMemoryPairedPhoneStore: PairedPhoneStore, @unchecked Sendable {
    private let lock = NSLock()
    private var phones: [PairedPhone] = []

    public init() {}

    public func all() throws -> [PairedPhone] {
        lock.lock(); defer { lock.unlock() }
        return phones
    }

    public func save(_ phone: PairedPhone) throws {
        lock.lock(); defer { lock.unlock() }
        if let i = phones.firstIndex(where: { $0.id == phone.id }) {
            phones[i] = phone
        } else {
            phones.append(phone)
        }
    }

    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        phones.removeAll { $0.id == id }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    public init() {}

    public func discoveryKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let key { return key }
        let created = PairingCrypto.randomBytes(32)
        key = created
        return created
    }
}
