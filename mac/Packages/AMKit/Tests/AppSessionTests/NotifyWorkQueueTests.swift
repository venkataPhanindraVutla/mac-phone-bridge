import AMProtocol
import ConnectionCore
import CryptoKit
import FeatureCalls
import FeatureContacts
import FeatureNotify
import Foundation
import SwiftProtobuf
import Testing
import UserNotifications
@testable import AppSession

@MainActor
private final class FakePresenter: NotificationPresenter {
    var shown: [String] = []
    var removed: [String] = []
    /// While set, authorize() does not return: the system prompt is up and the user has not answered.
    var holdAuthorization = false
    private var pending: [CheckedContinuation<Bool, Never>] = []

    func authorize() async -> Bool {
        guard holdAuthorization else { return true }
        return await withCheckedContinuation { pending.append($0) }
    }
    func release() {
        holdAuthorization = false
        let waiting = pending
        pending = []
        for c in waiting { c.resume(returning: true) }
    }
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
    func deliver(id: String, content: UNNotificationContent) async throws {
        if !shown.contains(id) { shown.append(id) }
    }
    func remove(ids: [String]) { removed += ids; shown.removeAll { ids.contains($0) } }
    func deliveredIDs() async -> [String] { shown }
}

private func phone(_ id: String) -> PairedPhone {
    PairedPhone(id: id, name: "Phone \(id)", model: "Test", certificateDER: Data(), pairedAt: Date(timeIntervalSince1970: 0))
}

private let everything: Set<String> = ["notify.v1", "contacts.v1", "calls.v1"]

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ channel: AMChannel, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = channel
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

private func posted(_ key: String) -> AMEnvelope {
    var n = AMPhoneNotification()
    n.key = key; n.package = "com.chat"; n.appName = "Chat"; n.title = "Ann"; n.text = "hi"; n.alert = true
    return envelope(.notifyPosted, .notify, n)
}

private func ringing(_ id: String) -> AMEnvelope {
    var s = AMCallState()
    s.callID = id; s.phase = .ringing; s.incoming = true; s.canAnswer = true; s.number = "+15551234567"
    return envelope(.callsState, .calls, s)
}

private func contactsBatch() -> AMEnvelope {
    var c = AMContact()
    c.id = "1"; c.displayName = "Ann Lee"
    var p = AMContactPhone(); p.number = "+1 555 123 4567"
    c.phones = [p]
    var b = AMContactsBatch()
    b.upserts = [c]; b.full = true; b.last = true; b.syncMs = 10
    return envelope(.contactsBatch, .contacts, b)
}

@MainActor
private final class Rig {
    let presenter = FakePresenter()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-session-\(UUID().uuidString)")
    var sent: [MessageType] = []
    var removedStores: [String] = []
    var notifications: NotificationsModel!
    var calls: CallModel!
    var contacts: ContactsSession!
    var queue: NotifyWorkQueue!

    init() {
        let key = SymmetricKey(size: .bits256)
        contacts = ContactsSession(
            enabled: true,
            open: { [dir] id in ContactsStore(file: EncryptedFile(url: ContactsStore.fileURL(phoneID: id, in: dir), key: key)) },
            remove: { [weak self, dir] id in
                self?.removedStores.append(id)
                try? FileManager.default.removeItem(at: ContactsStore.fileURL(phoneID: id, in: dir))
            },
            pairedPhoneIDs: { ["P1", "P2"] },
            requestSync: { [weak self] _ in self?.sent.append(.contactsSync) })
        notifications = NotificationsModel(
            presenter: presenter, icons: IconCache(directory: dir.appendingPathComponent("icons")),
            load: { _ in NotifySettings() }, save: { _, _ in }, copy: { _ in },
            nameFor: { [weak self] in self?.contacts.name(forNumber: $0) },
            attachmentDirectory: dir.appendingPathComponent("att"),
            send: { [weak self] type, _ in self?.sent.append(type) })
        calls = CallModel(
            nameFor: { [weak self] in self?.contacts.name(forNumber: $0) }, presenter: presenter,
            send: { [weak self] type, _ in self?.sent.append(type) })
        queue = NotifyWorkQueue(notifications: notifications, calls: calls, contacts: contacts)
    }

    func url(_ id: String) -> URL { ContactsStore.fileURL(phoneID: id, in: dir) }
    func storeExists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }
    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    /// P1 connected, with a notification, a loaded contacts store and a missed call shown.
    func connectP1() async {
        queue.handle(.connected(phone("P1"), shared: everything))
        // The store opens once the phone says it shares contacts.
        var shared = AMFeatureAvailability()
        shared.enabled = true
        queue.handle(message: envelope(.contactsAvailability, .contacts, shared))
        queue.handle(message: contactsBatch())
        queue.handle(message: posted("k1"))
        var missed = AMMissedCall(); missed.number = "+15551234567"; missed.atMs = 1000
        queue.handle(message: envelope(.callsMissed, .calls, missed))
        await queue.drained()
    }
}

@MainActor @Test func forgetOtherPhoneKeepsActiveSession() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.connectP1()
    r.presenter.shown += ["n|P2|old", "m|P2|500", "i|P2|notice"]
    #expect(r.queue.plan(.unpaired(phone("P2"))) == [.notificationsForget("P2"), .contactsForget("P2"), .featureForget("P2")])

    r.queue.handle(.unpaired(phone("P2")))
    r.queue.handle(message: posted("k2"))
    r.queue.handle(message: ringing("c1"))
    await r.queue.drained()

    // P1's session goes on: its notifications, calls and contacts are all still in use.
    #expect(r.queue.connectedPhoneID == "P1")
    #expect(r.presenter.shown == ["n|P1|k1", "m|P1|1000", "n|P1|k2"])
    #expect(r.calls.ringing.map(\.callID) == ["c1"])
    #expect(r.calls.displayName(r.calls.ringing[0]) == "Ann Lee")
    #expect(r.contacts.storePhoneID == "P1")
    #expect(r.storeExists("P1"))
    // P2 leaves nothing behind.
    #expect(r.removedStores == ["P2"])
}

@MainActor @Test func forgetActivePhoneTearsDownAndWipes() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.connectP1()
    r.queue.handle(message: ringing("c1"))
    r.presenter.shown += ["n|P2|other"]
    #expect(r.queue.plan(.unpaired(phone("P1"))) == [
        .disconnected, .contactsDisconnected, .callsDisconnected, .featureDisconnected,
        .notificationsForget("P1"), .contactsForget("P1"), .featureForget("P1"),
    ])
    #expect(r.queue.connectedPhoneID == nil)

    // As the server sends it: the forgotten phone was the connected one.
    r.queue.handle(.connected(phone("P1"), shared: everything))
    r.queue.handle(.unpaired(phone("P1")))
    r.queue.handle(message: posted("late"))
    await r.queue.drained()

    #expect(r.presenter.shown == ["n|P2|other"])
    #expect(r.calls.ringing.isEmpty)
    #expect(r.contacts.store == nil)
    #expect(!r.storeExists("P1"))
    #expect(r.removedStores == ["P1"])
}

@MainActor @Test func disconnectOfAnotherPhoneIsIgnored() async {
    let r = Rig(); defer { r.cleanUp() }
    await r.connectP1()
    #expect(r.queue.plan(.disconnected(phone("P2"))).isEmpty)
    #expect(r.queue.plan(.disconnected(phone("P1"))) == [
        .disconnected, .contactsDisconnected, .callsDisconnected, .featureDisconnected,
    ])
}

@MainActor @Test func pendingPermissionPromptDoesNotHoldUpCalls() async throws {
    let r = Rig(); defer { r.cleanUp() }
    r.presenter.holdAuthorization = true
    r.queue.handle(.connected(phone("P1"), shared: everything))
    r.queue.handle(message: ringing("c1"))
    // Wait (bounded) for the call: it must not wait for the user to answer the prompt.
    let deadline = ContinuousClock.now + .seconds(30)
    while r.calls.ringing.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(r.calls.ringing.map(\.callID) == ["c1"])
    #expect(r.sent.contains(.notifyFilter))
    r.presenter.release()
}
