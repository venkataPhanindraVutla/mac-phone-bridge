import AMProtocol
import ConnectionCore
import CryptoKit
import Foundation
import Observation

/// The phone's contacts as this Mac keeps them: names and number keys in one encrypted file per
/// paired phone, used to name callers and notification titles. Never shown as a list.
@MainActor
@Observable
public final class ContactsStore {
    private struct Entry: Codable {
        var id: String
        var name: String
        var keys: [String]
    }

    private struct Snapshot: Codable {
        var syncMs: Int64
        var contacts: [Entry]
    }

    /// Contacts with at least one usable number.
    public private(set) var count: Int = 0
    /// The phone's high-water mark from the last complete sync; 0 asks for a full one.
    public private(set) var syncMs: Int64 = 0

    @ObservationIgnored private let file: EncryptedFile
    @ObservationIgnored private var entries: [String: Entry] = [:]
    /// Number key to display names, sorted so the first wins.
    @ObservationIgnored private var index: [String: [String]] = [:]
    /// A full sync in progress: invisible until its last batch arrives.
    @ObservationIgnored private var staged: [String: Entry]?

    /// Loads the file. One that cannot be read (wrong key, damaged) counts as empty, so the next
    /// request is a full sync.
    public init(file: EncryptedFile) {
        self.file = file
        if let data = try? file.read(), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            entries = Dictionary(snapshot.contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            syncMs = snapshot.syncMs
        }
        reindex()
    }

    /// Where a phone's store lives: `contacts-<phoneID>.bin`, the ID made filename-safe.
    public nonisolated static func fileURL(phoneID: String, in directory: URL) -> URL {
        let safe = String(phoneID.unicodeScalars.map { s in
            (s.isASCII && (s.properties.isAlphabetic || s.properties.numericType == .decimal || s == "-" || s == "_"))
                ? Character(s) : "_"
        })
        return directory.appendingPathComponent("contacts-\(safe).bin")
    }

    /// `~/Library/Application Support/Android Mirroring`.
    public nonisolated static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Android Mirroring")
    }

    /// Applies one batch. A `full` sequence is staged and replaces the store on `last`; until then the
    /// old data stays. Incremental batches upsert and delete at once.
    public func apply(_ b: AMContactsBatch) throws {
        if b.full {
            var next = staged ?? [:]
            for c in b.upserts { Self.put(c, into: &next) }
            guard b.last else { staged = next; return }
            staged = nil
            entries = next
            syncMs = b.syncMs
        } else {
            for c in b.upserts { Self.put(c, into: &entries) }
            for id in b.deletedIds { entries[id] = nil }
            syncMs = max(syncMs, b.syncMs)
        }
        reindex()
        try persist()
    }

    /// Drops a full sync that did not finish (the connection ended); the old data stays.
    public func abandonSync() { staged = nil }

    /// The display name for a number as it appears anywhere, nil if no contact has it.
    public func name(forNumber raw: String) -> String? {
        guard let key = PhoneNumberKey.key(raw) else { return nil }
        return index[key]?.first
    }

    /// Deletes the file and forgets everything.
    public func wipe() throws {
        entries = [:]
        staged = nil
        syncMs = 0
        reindex()
        try file.delete()
    }

    private static func put(_ c: AMContact, into dict: inout [String: Entry]) {
        let keys = c.phones.compactMap { PhoneNumberKey.key($0.number) }
        // A contact that lost its numbers is of no use here.
        dict[c.id] = keys.isEmpty ? nil : Entry(id: c.id, name: c.displayName, keys: keys)
    }

    private func reindex() {
        var byKey: [String: [String]] = [:]
        for e in entries.values where !e.name.isEmpty {
            for k in e.keys { byKey[k, default: []].append(e.name) }
        }
        for k in byKey.keys {
            byKey[k]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        index = byKey
        count = entries.count
    }

    private func persist() throws {
        let snapshot = Snapshot(syncMs: syncMs, contacts: entries.values.sorted { $0.id < $1.id })
        try file.write(try JSONEncoder().encode(snapshot))
    }
}

/// The AES key that seals a phone's contacts file: 32 random bytes in the login keychain, made on
/// first use.
public enum ContactsKey {
    private static func item(phoneID: String) -> KeychainItem {
        KeychainItem(service: KeychainPairedPhoneStore.defaultService, account: "contacts-key-" + phoneID)
    }

    public static func load(phoneID: String) throws -> SymmetricKey {
        let item = item(phoneID: phoneID)
        if let data = try item.read(), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try item.write(key.withUnsafeBytes { Data($0) })
        return key
    }

    /// Removes the key; the file is unreadable without it.
    public static func delete(phoneID: String) throws {
        try item(phoneID: phoneID).delete()
    }
}
