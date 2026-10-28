import AMProtocol
import CryptoKit
import Foundation
import Testing
@testable import FeatureContacts

private func contact(_ id: String, _ name: String, _ numbers: String...) -> AMContact {
    var c = AMContact()
    c.id = id
    c.displayName = name
    c.phones = numbers.map { n in var p = AMContactPhone(); p.number = n; p.label = "Mobile"; return p }
    return c
}

private func batch(_ upserts: [AMContact] = [], deleted: [String] = [], full: Bool = false, last: Bool = true, syncMs: Int64 = 0) -> AMContactsBatch {
    var b = AMContactsBatch()
    b.upserts = upserts
    b.deletedIds = deleted
    b.full = full
    b.last = last
    b.syncMs = syncMs
    return b
}

private struct Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-contacts-\(UUID().uuidString)")
    let key = SymmetricKey(size: .bits256)
    var url: URL { dir.appendingPathComponent("contacts.bin") }
    @MainActor func store(key: SymmetricKey? = nil) -> ContactsStore {
        ContactsStore(file: EncryptedFile(url: url, key: key ?? self.key))
    }
    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

@MainActor @Test func fullSyncReplacesOnlyOnLast() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Old Friend", "+91 98765 43210")], full: true, syncMs: 10))
    #expect(store.name(forNumber: "9876543210") == "Old Friend")

    try store.apply(batch([contact("2", "Alice", "(415) 555-0100")], full: true, last: false))
    // Mid-sequence the old data is still in use.
    #expect(store.name(forNumber: "9876543210") == "Old Friend")
    #expect(store.name(forNumber: "4155550100") == nil)
    #expect(store.count == 1)

    try store.apply(batch([contact("3", "Bob", "+44 20 7946 0958")], full: true, last: true, syncMs: 99))
    #expect(store.name(forNumber: "9876543210") == nil)
    #expect(store.name(forNumber: "4155550100") == "Alice")
    #expect(store.name(forNumber: "+44 20 7946 0958") == "Bob")
    #expect(store.count == 2)
    #expect(store.syncMs == 99)
}

@MainActor @Test func abandonedFullSyncLeavesTheOldStore() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Old Friend", "9876543210")], full: true, syncMs: 10))
    try store.apply(batch([contact("2", "Alice", "4155550100")], full: true, last: false))
    store.abandonSync()
    try store.apply(batch([contact("3", "Bob", "4155550111")], full: true, last: true, syncMs: 20))
    #expect(store.name(forNumber: "4155550100") == nil) // the abandoned batch is gone
    #expect(store.name(forNumber: "4155550111") == "Bob")
    #expect(store.name(forNumber: "9876543210") == nil)
}

@MainActor @Test func incrementalUpsertsAndDeletes() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Alice", "4155550100"), contact("2", "Bob", "4155550111")], full: true, syncMs: 10))
    try store.apply(batch([contact("1", "Alice B", "4155550199")], deleted: ["2"], syncMs: 20))
    #expect(store.name(forNumber: "4155550100") == nil) // replaced, not merged
    #expect(store.name(forNumber: "4155550199") == "Alice B")
    #expect(store.name(forNumber: "4155550111") == nil)
    #expect(store.count == 1)
    #expect(store.syncMs == 20)
}

@MainActor @Test func incrementalNonLastBatchDoesNotAdvanceSyncMs() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Alice", "4155550100")], full: true, syncMs: 10))
    try store.apply(batch([contact("2", "Bob", "4155550111")], last: false, syncMs: 50))
    #expect(store.name(forNumber: "4155550111") == "Bob") // applied early, idempotent
    #expect(store.syncMs == 10)
    #expect(f.store().syncMs == 10) // and not persisted either
    try store.apply(batch([contact("3", "Cy", "4155550122")], last: true, syncMs: 50))
    #expect(store.syncMs == 50)
    #expect(f.store().syncMs == 50)
}

@MainActor @Test func contactWithoutNumbersIsNotStored() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Alice", "4155550100")], full: true, syncMs: 10))
    try store.apply(batch([contact("1", "Alice")], syncMs: 20)) // lost its number
    #expect(store.count == 0)
    #expect(store.name(forNumber: "4155550100") == nil)
}

@MainActor @Test func nameForNumberMatchesFormattedVariants() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Asha", "+91 98765 43210")], full: true, syncMs: 1))
    #expect(store.name(forNumber: "098765 43210") == "Asha")
    #expect(store.name(forNumber: "+919876543210") == "Asha")
    #expect(store.name(forNumber: "98765-43210") == "Asha")
    #expect(store.name(forNumber: "\u{2066}+91 98765 43210\u{2069}") == "Asha")
    #expect(store.name(forNumber: "+91\u{00A0}98765\u{00A0}43210") == "Asha")
    #expect(store.name(forNumber: "112") == nil)
    #expect(store.name(forNumber: "Alice") == nil)
}

@MainActor @Test func severalMatchesPickTheFirstByDisplayName() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([
        contact("1", "Zoe", "4155550100"),
        contact("2", "amy", "(415) 555-0100"),
        contact("3", "Bea", "415.555.0100"),
    ], full: true, syncMs: 1))
    #expect(store.name(forNumber: "4155550100") == "amy")
}

@MainActor @Test func persistsEncryptedAndReloads() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Zebediah Quux", "+91 98765 43210")], full: true, syncMs: 42))
    let raw = try Data(contentsOf: f.url)
    #expect(raw.range(of: Data("Zebediah".utf8)) == nil)
    #expect(raw.range(of: Data("9876543210".utf8)) == nil)

    let reloaded = f.store()
    #expect(reloaded.count == 1)
    #expect(reloaded.syncMs == 42)
    #expect(reloaded.name(forNumber: "9876543210") == "Zebediah Quux")
}

@MainActor @Test func wrongKeyFailsToRead() throws {
    let f = Fixture(); defer { f.cleanUp() }
    try f.store().apply(batch([contact("1", "Alice", "4155550100")], full: true, syncMs: 42))
    let other = f.store(key: SymmetricKey(size: .bits256))
    // Unreadable data is treated as no data: the Mac asks for a full sync again.
    #expect(other.count == 0)
    #expect(other.syncMs == 0)
    #expect(other.name(forNumber: "4155550100") == nil)
}

@MainActor @Test func wipeDeletesFileAndClears() throws {
    let f = Fixture(); defer { f.cleanUp() }
    let store = f.store()
    try store.apply(batch([contact("1", "Alice", "4155550100")], full: true, syncMs: 42))
    #expect(FileManager.default.fileExists(atPath: f.url.path))
    try store.wipe()
    #expect(!FileManager.default.fileExists(atPath: f.url.path))
    #expect(store.count == 0)
    #expect(store.syncMs == 0)
    #expect(store.name(forNumber: "4155550100") == nil)
}

@Test func fileNameIsFilenameSafe() {
    let dir = URL(fileURLWithPath: "/tmp/x")
    #expect(ContactsStore.fileURL(phoneID: "ab12", in: dir).lastPathComponent == "contacts-ab12.bin")
    #expect(ContactsStore.fileURL(phoneID: "../a/b c", in: dir).lastPathComponent == "contacts-___a_b_c.bin")
}
