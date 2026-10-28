import AMProtocol
import Foundation
import SwiftProtobuf
import Testing
import UserNotifications
@testable import FeatureNotify

@MainActor
final class FakePresenter: NotificationPresenter {
    var allow = true
    var delivered: [(id: String, content: UNNotificationContent)] = []
    var removedIDs: [String] = []
    var shown: [String] = []
    var categories: Set<UNNotificationCategory> = []
    var categoryCalls = 0

    func authorize() async -> Bool { allow }
    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories; categoryCalls += 1 }
    func deliver(id: String, content: UNNotificationContent) async throws {
        delivered.append((id, content))
        if !shown.contains(id) { shown.append(id) }
    }
    func remove(ids: [String]) { removedIDs += ids; shown.removeAll { ids.contains($0) } }
    func deliveredIDs() async -> [String] { shown }
}

@MainActor
final class Harness {
    let presenter = FakePresenter()
    var sent: [(MessageType, any SwiftProtobuf.Message)] = []
    var copied: [String] = []
    var stored: [String: NotifySettings] = [:]
    var contacts: [String: String] = [:]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-notify-test-" + UUID().uuidString)
    let icons: IconCache
    var model: NotificationsModel!

    init() {
        icons = IconCache(directory: dir.appendingPathComponent("icons"))
        model = NotificationsModel(
            presenter: presenter, icons: icons,
            load: { [unowned self] in self.stored[$0] ?? NotifySettings() },
            save: { [unowned self] in self.stored[$0] = $1 },
            copy: { [unowned self] in self.copied.append($0) },
            nameFor: { [unowned self] in self.contacts[$0] },
            attachmentDirectory: dir.appendingPathComponent("att"),
            send: { [unowned self] type, message in self.sent.append((type, message)) })
    }

    func connect(_ phone: String = "P1") async { await model.connected(phoneID: phone) }
    func sent<T>(_ type: MessageType, as _: T.Type) -> [T] { sent.filter { $0.0 == type }.compactMap { $0.1 as? T } }
}

private func note(
    key: String = "k1", package: String = "com.chat", app: String = "Chat", title: String = "Ann",
    text: String = "hello", alert: Bool = true, actions: [AMNotificationAction] = [], image: Data = Data()
) -> AMPhoneNotification {
    var n = AMPhoneNotification()
    n.key = key; n.package = package; n.appName = app; n.title = title; n.text = text
    n.alert = alert; n.actions = actions; n.imageJpeg = image
    return n
}

private func action(_ index: UInt32, _ title: String, reply: Bool = false, hint: String = "") -> AMNotificationAction {
    var a = AMNotificationAction()
    a.index = index; a.title = title; a.isReply = reply; a.replyHint = hint
    return a
}

private func info(_ phone: String = "P1", key: String = "k1", code: String? = nil) -> [AnyHashable: Any] {
    var d: [AnyHashable: Any] = ["phoneID": phone, "key": key]
    if let code { d["code"] = code }
    return d
}

@MainActor
@Test func postedDeliversWithTitleSubtitleBody() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note())
    let d = h.presenter.delivered.last
    #expect(d?.id == "n|P1|k1")
    #expect(d?.content.title == "Ann")
    #expect(d?.content.subtitle == "Chat")
    #expect(d?.content.body == "hello")
    #expect(d?.content.userInfo["phoneID"] as? String == "P1")
    #expect(d?.content.userInfo["key"] as? String == "k1")
    #expect(h.stored["P1"]?.seenApps["com.chat"] == "Chat")
}

@MainActor
@Test func emptyTitleUsesAppName() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(title: ""))
    #expect(h.presenter.delivered.last?.content.title == "Chat")
    #expect(h.presenter.delivered.last?.content.subtitle == "")
}

@MainActor
@Test func samePhoneKeyReplacesMacNotification() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(text: "one"))
    await h.model.posted(note(text: "two"))
    #expect(h.presenter.delivered.map(\.id) == ["n|P1|k1", "n|P1|k1"])
    #expect(h.presenter.shown == ["n|P1|k1"])
}

@MainActor
@Test func alertingPostHasSound() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(alert: true))
    #expect(h.presenter.delivered.last?.content.sound != nil)
}

@MainActor
@Test func silentUpdateIsPassive() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(alert: false))
    let c = h.presenter.delivered.last?.content
    #expect(c?.sound == nil)
    #expect(c?.interruptionLevel == .passive)
}

@MainActor
@Test func codeAddsCopyActionFirst() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(title: "Bank", text: "Your verification code is 482913", actions: [action(0, "Mark read")]))
    let c = h.presenter.delivered.last!.content
    #expect(c.userInfo["code"] as? String == "482913")
    let cat = h.presenter.categories.first { $0.identifier == c.categoryIdentifier }
    #expect(cat?.actions.map(\.identifier) == ["copy", "a|0"])
    #expect(cat?.actions.first?.title == "Copy code")
    #expect(cat?.options.contains(.customDismissAction) == true)
}

@MainActor
@Test func numberTitleIsEnrichedFromContacts() async {
    let h = Harness(); await h.connect()
    h.contacts["+1 (555) 010-2030"] = "Ann Lee"
    await h.model.posted(note(title: "+1 (555) 010-2030"))
    #expect(h.presenter.delivered.last?.content.title == "Ann Lee")
    // A short digit string is not a phone number, and unknown numbers stay as they are.
    h.contacts["12345"] = "Nope"
    await h.model.posted(note(key: "k2", title: "12345"))
    #expect(h.presenter.delivered.last?.content.title == "12345")
    await h.model.posted(note(key: "k3", title: "+44 7700 900123"))
    #expect(h.presenter.delivered.last?.content.title == "+44 7700 900123")
}

@MainActor
@Test func replyActionIsTextInput() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(actions: [action(2, "Reply", reply: true, hint: "Message Ann")]))
    let c = h.presenter.delivered.last!.content
    let cat = h.presenter.categories.first { $0.identifier == c.categoryIdentifier }
    let reply = cat?.actions.first as? UNTextInputNotificationAction
    #expect(reply?.identifier == "a|2")
    #expect(reply?.textInputButtonTitle == "Send")
    #expect(reply?.textInputPlaceholder == "Message Ann")
}

@MainActor
@Test func responseActionSendsInvokeWithIndex() async {
    let h = Harness(); await h.connect()
    await h.model.handleResponse(actionID: "a|2", userInfo: info(), replyText: nil)
    let invokes = h.sent(.notifyInvoke, as: AMInvokeAction.self)
    #expect(invokes.count == 1)
    #expect(invokes.first?.key == "k1")
    #expect(invokes.first?.actionIndex == 2)
    #expect(invokes.first?.replyText == "")
}

@MainActor
@Test func replyTextIsSent() async {
    let h = Harness(); await h.connect()
    await h.model.handleResponse(actionID: "a|0", userInfo: info(), replyText: "on my way")
    #expect(h.sent(.notifyInvoke, as: AMInvokeAction.self).first?.replyText == "on my way")
}

@MainActor
@Test func copyActionCopiesAndTellsNobody() async {
    let h = Harness(); await h.connect()
    let before = h.sent.count
    await h.model.handleResponse(actionID: "copy", userInfo: info(code: "482913"), replyText: nil)
    #expect(h.copied == ["482913"])
    #expect(h.sent.count == before)
}

@MainActor
@Test func dismissSendsNotifyDismiss() async {
    let h = Harness(); await h.connect()
    await h.model.handleResponse(actionID: UNNotificationDismissActionIdentifier, userInfo: info(), replyText: nil)
    #expect(h.sent(.notifyDismiss, as: AMDismissNotification.self).first?.key == "k1")
}

@MainActor
@Test func bodyClickSendsNothing() async {
    let h = Harness(); await h.connect()
    let before = h.sent.count
    await h.model.handleResponse(actionID: UNNotificationDefaultActionIdentifier, userInfo: info(), replyText: nil)
    #expect(h.sent.count == before)
    #expect(h.copied.isEmpty)
}

@MainActor
@Test func removedRemovesMacNotification() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note())
    var r = AMNotificationRemoved(); r.key = "k1"
    h.model.removed(r)
    #expect(h.presenter.removedIDs == ["n|P1|k1"])
}

@MainActor
@Test func snapshotRemovesStale() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(key: "a"))
    await h.model.posted(note(key: "b"))
    h.presenter.shown.append("n|P2|other")   // another phone's notification is left alone
    h.presenter.shown.append("i|info")
    var s = AMActiveNotifications(); s.keys = ["a"]
    await h.model.snapshot(s)
    #expect(h.presenter.removedIDs == ["n|P1|b"])
}

@MainActor
@Test func goneResultRemovesAndExplains() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note())
    var r = AMActionResult(); r.key = "k1"; r.outcome = .gone
    await h.model.result(r)
    #expect(h.presenter.removedIDs == ["n|P1|k1"])
    #expect(h.presenter.delivered.last?.content.title == "This notification is no longer on the phone.")
}

@MainActor
@Test func okAndFailedResultsDoNothingVisible() async {
    let h = Harness(); await h.connect()
    var r = AMActionResult(); r.key = "k1"; r.outcome = .ok
    await h.model.result(r)
    r.outcome = .failed
    await h.model.result(r)
    #expect(h.presenter.removedIDs.isEmpty)
    #expect(h.presenter.delivered.isEmpty)
}

@MainActor
@Test func responseForOtherPhoneIsIgnored() async {
    let h = Harness(); await h.connect()
    let before = h.sent.count
    await h.model.handleResponse(actionID: "a|0", userInfo: info("P2"), replyText: nil)
    await h.model.handleResponse(actionID: UNNotificationDismissActionIdentifier, userInfo: info("P2"), replyText: nil)
    #expect(h.sent.count == before)
    h.model.disconnected()
    await h.model.handleResponse(actionID: "a|0", userInfo: info("P1"), replyText: nil)
    #expect(h.sent.count == before)
}

@MainActor
@Test func connectSendsFilterWithMuted() async {
    let h = Harness()
    h.stored["P1"] = NotifySettings(enabled: true, mutedPackages: ["com.b", "com.a"])
    await h.connect()
    #expect(h.model.authorized == true)
    let f = h.sent(.notifyFilter, as: AMNotificationFilter.self)
    #expect(f.count == 1)
    #expect(f.first?.enabled == true)
    #expect(f.first?.mutedPackages == ["com.a", "com.b"])
}

@MainActor
@Test func updateSettingsResendsFilter() async {
    let h = Harness(); await h.connect()
    await h.model.update(NotifySettings(enabled: false, mutedPackages: ["com.x"]), phoneID: "P1")
    #expect(h.stored["P1"]?.enabled == false)
    let f = h.sent(.notifyFilter, as: AMNotificationFilter.self)
    #expect(f.count == 2)
    #expect(f.last?.enabled == false)
    #expect(f.last?.mutedPackages == ["com.x"])
}

@MainActor
@Test func unknownIconIsRequestedOncePerSession() async {
    let h = Harness(); await h.connect()
    await h.model.posted(note(key: "a"))
    await h.model.posted(note(key: "b"))
    #expect(h.sent(.notifyIconRequest, as: AMIconRequest.self).map(\.package) == ["com.chat"])
    // A cached icon is not requested, and is attached.
    h.model.icon({ var i = AMAppIcon(); i.package = "com.cached"; i.png = Data([0x89]); return i }())
    #expect(h.icons.url(for: "com.cached") != nil)
    await h.model.posted(note(key: "c", package: "com.cached"))
    #expect(h.sent(.notifyIconRequest, as: AMIconRequest.self).count == 1)
    // A new session asks again.
    h.model.disconnected()
    await h.connect()
    await h.model.posted(note(key: "d"))
    #expect(h.sent(.notifyIconRequest, as: AMIconRequest.self).count == 2)
}

@MainActor
@Test func availabilityIsRecordedAndClearedOnDisconnect() async {
    let h = Harness(); await h.connect()
    var a = AMFeatureAvailability(); a.enabled = false; a.reason = .needsPermission
    h.model.availability(a)
    #expect(h.model.phoneAvailability?.reason == .needsPermission)
    h.model.disconnected()
    #expect(h.model.phoneAvailability == nil)
}

@MainActor
@Test func pictureIsAttached() async {
    let h = Harness(); await h.connect()
    // Minimal valid JPEG (SOI + EOI is enough for the file-type check).
    await h.model.posted(note(image: Data([0xFF, 0xD8, 0xFF, 0xD9])))
    #expect(h.presenter.delivered.last?.content.attachments.count == 1)
}
