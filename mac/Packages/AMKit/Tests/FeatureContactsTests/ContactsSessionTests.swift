import AMProtocol
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureContacts

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .contacts
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

private func availability(_ enabled: Bool, _ reason: AMAvailabilityReason = .offByUser) -> AMEnvelope {
    var a = AMFeatureAvailability()
    a.enabled = enabled
    if !enabled { a.reason = reason }
    return envelope(.contactsAvailability, a)
}

private func fullBatch(syncMs: Int64 = 10) -> AMEnvelope {
    var c = AMContact()
    c.id = "1"; c.displayName = "Ann Lee"
    var p = AMContactPhone(); p.number = "+91 98765 43210"
    c.phones = [p]
    var b = AMContactsBatch()
    b.upserts = [c]; b.full = true; b.last = true; b.syncMs = syncMs
    return envelope(.contactsBatch, b)
}

/// A session over real encrypted files in a temporary directory; "keys" live in a dictionary.
@MainActor
private final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-contacts-session-\(UUID().uuidString)")
    var keys: [String: SymmetricKey] = [:]
    var paired = ["P1", "P2"]
    var syncs: [Int64] = []
    var removed: [String] = []
    var session: ContactsSession!

    init() {
        session = ContactsSession(
            enabled: true,
            open: { [unowned self] id in
                let key = self.keys[id] ?? SymmetricKey(size: .bits256)
                self.keys[id] = key
                return ContactsStore(file: EncryptedFile(url: self.url(id), key: key))
            },
            remove: { [unowned self] id in
                self.removed.append(id)
                try? FileManager.default.removeItem(at: self.url(id))
                self.keys[id] = nil
            },
            pairedPhoneIDs: { [unowned self] in self.paired },
            requestSync: { [unowned self] since in self.syncs.append(since) })
    }

    func url(_ id: String) -> URL { ContactsStore.fileURL(phoneID: id, in: dir) }
    func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }
    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

@MainActor @Test func phoneSharingOffWipesStore() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.session.connected(phoneID: "P1")
    await r.session.message(fullBatch())
    #expect(r.session.name(forNumber: "9876543210") == "Ann Lee")
    #expect(r.exists("P1"))

    // The phone turned "Share contacts with your Mac" off (or lost the permission).
    await r.session.message(availability(false))
    #expect(r.session.store == nil)
    #expect(r.session.name(forNumber: "9876543210") == nil)
    #expect(!r.exists("P1"))
    #expect(r.keys["P1"] == nil)
    // A batch now has nowhere to go.
    await r.session.message(fullBatch())
    #expect(!r.exists("P1"))

    // Sharing back on: a full sync from nothing.
    await r.session.message(availability(true))
    #expect(r.session.store != nil)
    #expect(r.syncs == [0, 0])
}

@MainActor @Test func permissionLossAlsoWipesStore() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.session.connected(phoneID: "P1")
    await r.session.message(fullBatch())
    await r.session.message(availability(false, .needsPermission))
    #expect(r.session.store == nil)
    #expect(!r.exists("P1"))
}

@MainActor @Test func forgettingAnotherPhoneKeepsLoadedStore() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.session.connected(phoneID: "P1")
    await r.session.message(fullBatch())
    r.session.forget(phoneID: "P2")
    #expect(r.removed == ["P2"])
    #expect(r.session.storePhoneID == "P1")
    #expect(r.session.name(forNumber: "9876543210") == "Ann Lee")
    #expect(r.exists("P1"))

    r.session.forget(phoneID: "P1")
    #expect(r.session.store == nil)
    #expect(!r.exists("P1"))
}

@MainActor @Test func switchOffWipesEveryPairedPhone() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.session.connected(phoneID: "P1")
    await r.session.message(fullBatch())
    await r.session.toggled(on: false)
    #expect(r.session.store == nil)
    #expect(r.removed == ["P1", "P2"])
    #expect(!r.exists("P1"))
    await r.session.toggled(on: true)
    #expect(r.session.storePhoneID == "P1")
    #expect(r.syncs == [0, 0])
}

@MainActor @Test func switchOnWaitsWhileThePhoneDoesNotShare() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.session.connected(phoneID: "P1")
    await r.session.toggled(on: false)
    await r.session.message(availability(false))   // heard while this Mac's switch is off
    await r.session.toggled(on: true)
    #expect(r.session.store == nil)
    #expect(r.syncs == [0])
    await r.session.message(availability(true))
    #expect(r.session.storePhoneID == "P1")
    #expect(r.syncs == [0, 0])
}
