import CryptoKit
import Foundation
import Testing
@testable import FeatureContacts

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("am-contacts-test-\(UUID().uuidString)/store.bin")
}

@Test func roundTripsAndHidesPlaintext() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = EncryptedFile(url: url, key: SymmetricKey(size: .bits256))
    try file.write(Data("Alice Example 9876543210".utf8))
    #expect(try file.read() == Data("Alice Example 9876543210".utf8))
    let raw = try Data(contentsOf: url)
    #expect(raw.range(of: Data("Alice".utf8)) == nil)
}

@Test func missingFileReadsAsNil() throws {
    let file = EncryptedFile(url: tempURL(), key: SymmetricKey(size: .bits256))
    #expect(try file.read() == nil)
}

@Test func wrongKeyThrows() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try EncryptedFile(url: url, key: SymmetricKey(size: .bits256)).write(Data("x".utf8))
    #expect(throws: (any Error).self) { try EncryptedFile(url: url, key: SymmetricKey(size: .bits256)).read() }
}

@Test func tamperedFileThrows() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let key = SymmetricKey(size: .bits256)
    let file = EncryptedFile(url: url, key: key)
    try file.write(Data("hello world".utf8))
    var raw = try Data(contentsOf: url)
    raw[raw.count - 1] ^= 0xFF
    try raw.write(to: url)
    #expect(throws: (any Error).self) { try file.read() }
}

@Test func deleteRemovesAndIsIdempotent() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = EncryptedFile(url: url, key: SymmetricKey(size: .bits256))
    try file.write(Data("x".utf8))
    try file.delete()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try file.delete()
}

@Test func fileIsOwnerOnly() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try EncryptedFile(url: url, key: SymmetricKey(size: .bits256)).write(Data("x".utf8))
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}
