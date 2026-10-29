import AMProtocol
import FeatureClipboard
import FeatureNotify
import Foundation
import SwiftProtobuf
import Testing
import UserNotifications
@testable import FeatureShare

/// A pasteboard whose change count the test moves by hand; a write moves it too.
@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var types: [String] = []
    var string: String?
    var writes: [String] = []

    func readString() -> String? { string }

    func writeString(_ s: String) {
        writes.append(s)
        string = s
        types = ["public.utf8-plain-text"]
        changeCount += 1
    }

    /// What another app copying `text` looks like.
    func copy(_ text: String, types extra: [String] = []) {
        string = text
        types = ["public.utf8-plain-text"] + extra
        changeCount += 1
    }
}

private struct DeliverFailed: Error {}

@MainActor
private final class FakePresenter: NotificationPresenter {
    var delivered: [(id: String, content: UNNotificationContent)] = []
    var authorizeCalls = 0
    /// Notifications not allowed: every delivery throws.
    var failDeliver = false
    func authorize() async -> Bool {
        authorizeCalls += 1
        return !failDeliver
    }
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
    func deliver(id: String, content: UNNotificationContent) async throws {
        if failDeliver { throw DeliverFailed() }
        delivered.append((id, content))
    }
    func remove(ids: [String]) {}
    func deliveredIDs() async -> [String] { delivered.map(\.id) }
}

@MainActor
private final class Rig {
    let board = FakePasteboard()
    let presenter = FakePresenter()
    var opened: [URL] = []
    /// Everything sent, by the clipboard model and the share model alike.
    var sent: [(type: MessageType, message: any SwiftProtobuf.Message)] = []
    private(set) var clipboard: ClipboardModel!
    private(set) var share: ShareModel!

    init() {
        clipboard = ClipboardModel(
            pasteboard: board, sendEnabled: true,
            send: { [weak self] type, message in self?.sent.append((type, message)) },
            // The tests call poll() themselves.
            interval: .seconds(3600))
        share = ShareModel(
            clipboard: clipboard, presenter: presenter,
            openURL: { [weak self] in self?.opened.append($0) },
            send: { [weak self] type, message in self?.sent.append((type, message)) })
    }

    func connect(_ shared: Set<String> = ["clipboard.v1", "share.v1"]) async {
        await clipboard.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
        await share.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
    }

    func disconnect() {
        clipboard.disconnected()
        share.disconnected()
    }

    func deliver<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) async {
        var e = AMEnvelope()
        e.channel = .share
        e.type = type.rawValue
        e.payload = (try? message.serializedData()) ?? Data()
        await share.message(e)
    }

    func phoneLink(_ url: String) async {
        var m = AMSharedLink()
        m.url = url
        await deliver(.shareLink, m)
    }

    func phoneText(_ text: String) async {
        var m = AMSharedText()
        m.text = text
        await deliver(.shareText, m)
    }

    var sentTypes: [MessageType] { sent.map(\.type) }
    var sentTexts: [String] { sent.compactMap { ($0.message as? AMSharedText)?.text } }
    var sentLinks: [String] { sent.compactMap { ($0.message as? AMSharedLink)?.url } }
}

// MARK: from the phone

@MainActor @Test func incomingLinkOpens() async {
    let r = Rig()
    await r.connect()
    await r.phoneLink(" https://example.com/page ")
    #expect(r.opened.map(\.absoluteString) == ["https://example.com/page"])
    #expect(r.board.writes.isEmpty)
    #expect(r.presenter.delivered.isEmpty)
}

@MainActor @Test func fileSchemeLinkIsTreatedAsText() async {
    let r = Rig()
    await r.connect()
    await r.phoneLink("file:///etc/passwd")
    await r.phoneLink("javascript:alert(1)")
    #expect(r.opened.isEmpty)
    #expect(r.board.writes == ["file:///etc/passwd", "javascript:alert(1)"])
    #expect(r.presenter.delivered.count == 2)
}

@MainActor @Test func textGoesToPasteboardAndNotifies() async throws {
    let r = Rig()
    await r.connect()
    let long = String(repeating: "é", count: 250)
    await r.phoneText(long)
    #expect(r.board.writes == [long])
    let n = try #require(r.presenter.delivered.first)
    #expect(n.id.hasPrefix("s|P1|"))
    #expect(UUID(uuidString: String(n.id.dropFirst("s|P1|".count))) != nil)
    #expect(n.content.title == "Copied from Pixel")
    #expect(n.content.body == String(repeating: "é", count: 200))

    // Each one gets its own notification.
    await r.phoneText("short")
    #expect(r.presenter.delivered.count == 2)
    #expect(r.presenter.delivered[1].content.body == "short")
    #expect(r.presenter.delivered[0].id != r.presenter.delivered[1].id)
    // Nothing goes back to the phone.
    #expect(r.sent.isEmpty)
}

@MainActor @Test func sharedTextFromPhoneIsNotEchoed() async {
    let r = Rig()
    await r.connect()
    await r.phoneText("from the phone")
    #expect(r.board.changeCount == 1)
    await r.clipboard.poll()
    #expect(r.sent.isEmpty)

    // A real copy afterwards still goes across.
    r.board.copy("from the Mac")
    await r.clipboard.poll()
    #expect(r.sentTypes == [.clipboardText])
}

// MARK: to the phone

@MainActor @Test func sendClipboardSendsShareText() async {
    let r = Rig()
    await r.connect()
    // Explicit: a concealed item is sent too.
    r.board.copy("secret", types: ["org.nspasteboard.ConcealedType"])
    #expect(await r.share.sendClipboard() == .sent)
    #expect(r.sentTypes == [.shareText])
    #expect(r.sentTexts == ["secret"])
}

@MainActor @Test func sendClipboardEmptyIsEmpty() async {
    let r = Rig()
    await r.connect()
    #expect(await r.share.sendClipboard() == .empty)
    r.board.copy("")
    #expect(await r.share.sendClipboard() == .empty)
    #expect(await r.share.sendText("") == .empty)
    #expect(r.sent.isEmpty)
}

@MainActor @Test func oversizedTextIsTooLarge() async {
    let r = Rig()
    await r.connect()
    let fits = String(repeating: "a", count: ClipboardModel.maxBytes)
    #expect(await r.share.sendText(fits + "a") == .tooLarge)
    r.board.copy(String(repeating: "é", count: ClipboardModel.maxBytes / 2 + 1))
    #expect(await r.share.sendClipboard() == .tooLarge)
    #expect(r.sent.isEmpty)
    #expect(await r.share.sendText(fits) == .sent)
    #expect(r.sentTexts.map(\.utf8.count) == [ClipboardModel.maxBytes])
}

@MainActor @Test func notSharedSendsNothing() async {
    let r = Rig()
    // Never connected.
    r.board.copy("hello")
    #expect(await r.share.sendClipboard() == .notConnected)
    #expect(await r.share.sendText("hello") == .notConnected)
    await r.share.sendLink(URL(string: "https://example.com")!)

    // Connected, but the phone does not list share.v1.
    await r.connect(["clipboard.v1"])
    #expect(await r.share.sendClipboard() == .notConnected)
    #expect(await r.share.sendText("hello") == .notConnected)
    await r.share.sendLink(URL(string: "https://example.com")!)
    // Nor is anything from it acted on.
    await r.phoneText("ignored")
    await r.phoneLink("https://example.com")
    #expect(r.board.writes.isEmpty)
    #expect(r.opened.isEmpty)
    #expect(r.presenter.delivered.isEmpty)

    // Shared, then gone.
    await r.connect()
    r.disconnect()
    #expect(await r.share.sendText("hello") == .notConnected)
    await r.phoneText("ignored")
    #expect(r.sent.isEmpty)
    #expect(r.board.writes.isEmpty)
}

@MainActor @Test func sendLinkSendsLinksAndTextOtherwise() async {
    let r = Rig()
    await r.connect()
    await r.share.sendLink(URL(string: "https://example.com/a")!)
    await r.share.sendLink(URL(string: "mailto:a@example.com")!)
    #expect(r.sentTypes == [.shareLink, .shareText])
    #expect(r.sentLinks == ["https://example.com/a"])
    #expect(r.sentTexts == ["mailto:a@example.com"])

}

@MainActor @Test func sentShareTextCountsAsPhoneHas() async {
    let r = Rig()
    await r.connect()
    #expect(await r.share.sendText("sent by drop") == .sent)
    // The phone put it on its clipboard; the same text copied on the Mac is not sent again.
    r.board.copy("sent by drop")
    await r.clipboard.poll()
    #expect(r.sentTypes == [.shareText])

    // The clipboard itself, sent on purpose: same.
    r.board.copy("menu send")
    #expect(await r.share.sendClipboard() == .sent)
    r.board.copy("menu send")
    await r.clipboard.poll()
    #expect(r.sentTypes == [.shareText, .shareText])

    // Other text still goes.
    r.board.copy("new")
    await r.clipboard.poll()
    #expect(r.sentTypes == [.shareText, .shareText, .clipboardText])
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now >= deadline { Issue.record("timed out"); return }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor @Test func firstShareAsksForNotificationsAndDeliverFailureStillCopies() async throws {
    let r = Rig()
    await r.connect()
    // A phone without notify.v1: nothing has asked for notification permission yet.
    #expect(r.presenter.authorizeCalls == 0)
    r.presenter.failDeliver = true
    await r.phoneText("one")
    #expect(r.board.writes == ["one"])
    try await until { r.presenter.authorizeCalls == 1 }
    await r.phoneText("two")
    await r.phoneLink("https://example.com")
    #expect(r.board.writes == ["one", "two"])
    #expect(r.opened.count == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(r.presenter.authorizeCalls == 1)

    // Once per session; a link counts as a share too.
    r.disconnect()
    await r.connect()
    await r.phoneLink("https://example.com/again")
    try await until { r.presenter.authorizeCalls == 2 }
}
