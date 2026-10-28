import AMProtocol
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureNotify

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .notify
    e.id = 1
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

@MainActor
@Test func notifyTypesRouteToModel() async {
    let h = Harness(); await h.connect()

    var posted = AMPhoneNotification()
    posted.key = "k1"; posted.package = "com.chat"; posted.appName = "Chat"; posted.title = "Ann"; posted.text = "hi"
    #expect(await NotifyRouter.route(envelope(.notifyPosted, posted), to: h.model))
    #expect(h.presenter.shown == ["n|P1|k1"])

    var snapshot = AMActiveNotifications()
    snapshot.keys = ["other"]
    #expect(await NotifyRouter.route(envelope(.notifySnapshot, snapshot), to: h.model))
    #expect(h.presenter.shown.isEmpty)

    await h.model.posted(posted)
    var removed = AMNotificationRemoved()
    removed.key = "k1"
    #expect(await NotifyRouter.route(envelope(.notifyRemoved, removed), to: h.model))
    #expect(h.presenter.shown.isEmpty)

    var availability = AMFeatureAvailability()
    availability.enabled = false
    availability.reason = .needsPermission
    #expect(await NotifyRouter.route(envelope(.notifyAvailability, availability), to: h.model))
    #expect(h.model.phoneAvailability?.reason == .needsPermission)

    var icon = AMAppIcon()
    icon.package = "com.chat"
    icon.png = Data([1, 2, 3])
    #expect(await NotifyRouter.route(envelope(.notifyIcon, icon), to: h.model))
    #expect(h.icons.url(for: "com.chat") != nil)

    var result = AMActionResult()
    result.key = "k1"
    result.outcome = .gone
    #expect(await NotifyRouter.route(envelope(.notifyResult, result), to: h.model))
    #expect(h.presenter.delivered.last?.id.hasPrefix("i|") == true)

    // Not a notify message: left for the app to handle.
    #expect(await NotifyRouter.route(envelope(.statusUpdate, AMStatusUpdate()), to: h.model) == false)
}
