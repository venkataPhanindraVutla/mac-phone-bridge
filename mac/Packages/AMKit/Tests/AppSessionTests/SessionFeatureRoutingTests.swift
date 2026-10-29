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

/// What happened, across the notifications model and the features, in order.
@MainActor
private final class EventLog {
    var lines: [String] = []
}

@MainActor
private final class LoggingPresenter: NotificationPresenter {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func authorize() async -> Bool { true }
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
    func deliver(id: String, content: UNNotificationContent) async throws { log.lines.append("shown \(id)") }
    func remove(ids: [String]) { for id in ids { log.lines.append("removed \(id)") } }
    func deliveredIDs() async -> [String] { [] }
}

/// A feature that writes everything it is told to the log, and is slow to handle messages.
@MainActor
private final class RecordingFeature: SessionFeature {
    let name: String
    let messagePrefixes: [String]
    let log: EventLog

    init(_ name: String, prefixes: [String], log: EventLog) {
        self.name = name
        messagePrefixes = prefixes
        self.log = log
    }

    func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        log.lines.append("\(name) connected \(phoneID) \(phoneName) \(shared.sorted().joined(separator: ","))")
    }

    func disconnected() { log.lines.append("\(name) disconnected") }

    func message(_ envelope: AMEnvelope) async {
        // Suspends for a while: anything queued behind it must still wait.
        try? await Task.sleep(for: .milliseconds(30))
        log.lines.append("\(name) \(envelope.type)")
    }

    func forget(phoneID: String) async { log.lines.append("\(name) forget \(phoneID)") }
}

private func phone(_ id: String) -> PairedPhone {
    PairedPhone(id: id, name: "Phone \(id)", model: "Test", certificateDER: Data(), pairedAt: Date(timeIntervalSince1970: 0))
}

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ channel: AMChannel, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = channel
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

@MainActor
private final class Rig {
    let log = EventLog()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-routing-\(UUID().uuidString)")
    let queue: NotifyWorkQueue

    init() {
        let key = SymmetricKey(size: .bits256)
        let dir = self.dir
        let contacts = ContactsSession(
            enabled: true,
            open: { id in ContactsStore(file: EncryptedFile(url: ContactsStore.fileURL(phoneID: id, in: dir), key: key)) },
            remove: { _ in }, pairedPhoneIDs: { [] }, requestSync: { _ in })
        let presenter = LoggingPresenter(log: log)
        let notifications = NotificationsModel(
            presenter: presenter, icons: IconCache(directory: dir.appendingPathComponent("icons")),
            load: { _ in NotifySettings() }, save: { _, _ in }, copy: { _ in },
            nameFor: { _ in nil }, attachmentDirectory: dir.appendingPathComponent("att"),
            send: { _, _ in })
        let calls = CallModel(nameFor: { _ in nil }, presenter: presenter, send: { _, _ in })
        queue = NotifyWorkQueue(notifications: notifications, calls: calls, contacts: contacts)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

@MainActor @Test func featureReceivesConnectedWithShared() async {
    let r = Rig(); defer { r.cleanUp() }
    r.queue.register(RecordingFeature("files", prefixes: ["files."], log: r.log))
    r.queue.register(RecordingFeature("clip", prefixes: ["clipboard."], log: r.log))
    let shared: Set<String> = ["files.v1", "clipboard.v1"]
    #expect(r.queue.plan(.connected(phone("P1"), shared: shared)).last == .featureConnected("P1", "Phone P1", shared))

    r.queue.handle(.connected(phone("P1"), shared: shared))
    await r.queue.drained()
    // Registration order.
    #expect(r.log.lines == [
        "files connected P1 Phone P1 clipboard.v1,files.v1",
        "clip connected P1 Phone P1 clipboard.v1,files.v1",
    ])

    r.queue.handle(.disconnected(phone("P1")))
    await r.queue.drained()
    #expect(r.log.lines.suffix(2) == ["files disconnected", "clip disconnected"])
}

@MainActor @Test func featureMessagesKeepArrivalOrderWithNotify() async {
    let r = Rig(); defer { r.cleanUp() }
    r.queue.register(RecordingFeature("files", prefixes: ["files."], log: r.log))
    r.queue.handle(.connected(phone("P1"), shared: ["notify.v1", "files.v1"]))
    await r.queue.drained()
    r.log.lines = []

    var n = AMPhoneNotification()
    n.key = "k1"; n.package = "com.chat"; n.appName = "Chat"; n.title = "Ann"; n.text = "hi"; n.alert = true
    var removed = AMNotificationRemoved()
    removed.key = "k1"
    #expect(r.queue.handle(message: envelope(.notifyPosted, .notify, n)))
    #expect(r.queue.handle(message: envelope(.filesOffer, .files, AMTransferOffer())))
    #expect(r.queue.handle(message: envelope(.notifyRemoved, .notify, removed)))
    await r.queue.drained()

    #expect(r.log.lines == ["shown n|P1|k1", "files files.offer", "removed n|P1|k1"])
}

@MainActor @Test func unclaimedPrefixReturnsFalse() async {
    let r = Rig(); defer { r.cleanUp() }
    #expect(!r.queue.handle(message: envelope(.filesOffer, .files, AMTransferOffer())))
    r.queue.register(RecordingFeature("files", prefixes: ["files."], log: r.log))
    #expect(r.queue.handle(message: envelope(.filesOffer, .files, AMTransferOffer())))
    #expect(!r.queue.handle(message: envelope(.photosItems, .photos, AMPhotosList())))
    #expect(!r.queue.handle(message: envelope(.statusUpdate, .status, AMStatusUpdate())))
    // A prefix matches on the whole "files." part only.
    var odd = AMEnvelope()
    odd.type = "filesystem.x"
    #expect(!r.queue.handle(message: odd))
    await r.queue.drained()
}

@MainActor @Test func unpairedForgetsInEveryFeature() async {
    let r = Rig(); defer { r.cleanUp() }
    r.queue.register(RecordingFeature("files", prefixes: ["files."], log: r.log))
    r.queue.register(RecordingFeature("clip", prefixes: ["clipboard."], log: r.log))
    r.queue.handle(.connected(phone("P1"), shared: ["files.v1"]))
    await r.queue.drained()
    r.log.lines = []

    // Another phone: forgotten everywhere, the session goes on.
    r.queue.handle(.unpaired(phone("P2")))
    await r.queue.drained()
    #expect(r.log.lines == ["files forget P2", "clip forget P2"])

    // The connected phone: torn down first, then forgotten.
    r.log.lines = []
    r.queue.handle(.unpaired(phone("P1")))
    await r.queue.drained()
    #expect(r.log.lines == ["files disconnected", "clip disconnected", "files forget P1", "clip forget P1"])
}

@MainActor @Test func registeringTwiceDeliversOnce() async {
    let r = Rig(); defer { r.cleanUp() }
    let files = RecordingFeature("files", prefixes: ["files."], log: r.log)
    r.queue.register(files)
    r.queue.register(files)
    r.queue.handle(.connected(phone("P1"), shared: ["files.v1"]))
    r.queue.handle(message: envelope(.filesOffer, .files, AMTransferOffer()))
    await r.queue.drained()
    #expect(r.log.lines == ["files connected P1 Phone P1 files.v1", "files files.offer"])
}
