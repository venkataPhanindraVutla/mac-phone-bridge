import CryptoKit
import Foundation

/// One file sealed with AES-GCM under a key the caller holds (the Keychain, in the app).
public struct EncryptedFile: Sendable {
    public let url: URL
    private let key: SymmetricKey

    public init(url: URL, key: SymmetricKey) {
        self.url = url
        self.key = key
    }

    /// The decrypted contents; nil if the file does not exist. Throws if it cannot be decrypted
    /// (wrong key, damaged file).
    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sealed = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
        return try AES.GCM.open(sealed, using: key)
    }

    /// Replaces the file atomically, readable by the owner only.
    public func write(_ data: Data) throws {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the file; nothing to do if it is already gone.
    public func delete() throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }
}
