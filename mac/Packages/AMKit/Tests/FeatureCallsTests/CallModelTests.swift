import AMProtocol
import Foundation
import FeatureNotify
import SwiftProtobuf
import Testing
import UserNotifications
@testable import FeatureCalls

@MainActor
private final class FakePresenter: NotificationPresenter {
    var delivered: [(id: String, content: UNNotificationContent)] = []
    var categoryCalls = 0
    func authorize() async -> Bool { true }
    func setCategories(_ categories: Set<UNNotificationCategory>) { categoryCalls += 1 }
    func deliver(id: String, content: UNNotificationContent) async throws { delivered.append((id, content)) }
    func remove(ids: [String]) {}
    func deliveredIDs() async -> [String] { [] }
}

private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class Harness {
    let presenter = FakePresenter()
    var sent: [(MessageType, any SwiftProtobuf.Message)] = []
    var contacts: [String: String] = [:]
    var model: CallModel!
    var clock = Date(timeIntervalSince1970: 1_000)
    let ticks = AsyncStream.makeStream(of: Void.self)

    init() {
        let stream = SendableBox(ticks.stream.makeAsyncIterator())
        model = CallModel(
            nameFor: { [unowned self] in self.contacts[$0] }, presenter: presenter,
            send: { [unowned self] type, message in self.sent.append((type, message)) },
            now: { [unowned self] in self.clock },
            ticker: { var it = stream.value; _ = await it.next(); stream.value = it })
        model.connected(phoneID: "P1")
    }

    var commands: [AMCallCommand] { sent.filter { $0.0 == .callsCommand }.compactMap { $0.1 as? AMCallCommand } }
}

private func call(
    _ id: String = "c1", _ phase: AMCallPhase = .ringing, number: String = "+15551234567", name: String = "",
    canAnswer: Bool = true, muteSupported: Bool = true, muted: Bool = false, since: Int64 = 0
) -> AMCallState {
    var s = AMCallState()
    s.callID = id; s.phase = phase; s.number = number; s.displayName = name
    s.canAnswer = canAnswer; s.muteSupported = muteSupported; s.muted = muted; s.sinceMs = since
    s.incoming = true
    return s
}

@MainActor
struct CallModelTests {
    @Test func ringingAddsPanelEntry() {
        let h = Harness()
        h.model.apply(call("c1"))
        #expect(h.model.ringing.map(\.callID) == ["c1"])
        h.model.apply(call("c1", name: "Ann"))        // an update replaces, not duplicates
        h.model.apply(call("c2"))
        #expect(h.model.ringing.map(\.callID) == ["c1", "c2"])
        #expect(h.model.ringing[0].displayName == "Ann")
    }

    @Test func activeClosesPanelAndSetsActive() {
        let h = Harness()
        h.model.apply(call("c1"))
        h.model.apply(call("c1", .active))
        #expect(h.model.ringing.isEmpty)
        #expect(h.model.active?.callID == "c1")
    }

    @Test func endedClosesPanel() {
        let h = Harness()
        h.model.apply(call("c1"))
        h.model.apply(call("c1", .ended))
        #expect(h.model.ringing.isEmpty)
        h.model.apply(call("c2", .active))
        h.model.apply(call("c2", .ended))
        #expect(h.model.active == nil)
    }

    @Test func endedCallClosesPanel() async {
        let h = Harness()
        h.model.apply(call("c1"))
        await h.model.answer("c1")
        var r = AMCallCommandResult()
        r.callID = "c1"; r.outcome = .noSuchCall
        h.model.result(r)
        #expect(h.model.ringing.isEmpty)
        #expect(h.model.lastError == .noSuchCall)
    }

    @Test func answerSendsCommand() async {
        let h = Harness()
        h.model.apply(call("c1"))
        await h.model.answer("c1")
        await h.model.decline("c1")
        #expect(h.commands.map(\.action) == [.answer, .decline])
        #expect(h.commands.allSatisfy { $0.callID == "c1" })
    }

    @Test func answerHiddenWhenCannotAnswer() async {
        let h = Harness()
        h.model.apply(call("c1", canAnswer: true))
        #expect(h.model.actions(for: h.model.ringing[0]) == [.answer, .decline])
        h.model.apply(call("c1", canAnswer: false))
        await h.model.answer("c1")
        #expect(h.commands.isEmpty)
    }

    @Test func waitingCallPanelHasNoActions() async {
        let h = Harness()
        h.model.apply(call("c1", .active))
        h.model.apply(call("c2", canAnswer: false))
        #expect(h.model.ringing.map(\.callID) == ["c2"])
        #expect(h.model.actions(for: h.model.ringing[0]) == [.close])
        await h.model.decline("c2")
        #expect(h.commands.isEmpty)
        h.model.close("c2")
        #expect(h.model.ringing.isEmpty)
        h.model.apply(call("c2", canAnswer: false))   // a later update must not bring a closed panel back
        #expect(h.model.ringing.isEmpty)
    }

    @Test func contactNameWinsOverDisplayName() {
        let h = Harness()
        h.contacts["+15551234567"] = "Ann Lee"
        #expect(h.model.displayName(call(name: "Phone Name")) == "Ann Lee")
        #expect(h.model.displayName(call(number: "+19998887777", name: "Phone Name")) == "Phone Name")
        #expect(h.model.displayName(call(number: "+19998887777")) == "+19998887777")
    }

    @Test func unknownNumberShowsUnknown() {
        let h = Harness()
        #expect(h.model.displayName(call(number: "")) == "Unknown")
    }

    @Test func missedDeliversNotification() async {
        let h = Harness()
        h.contacts["+15551234567"] = "Ann Lee"
        var m = AMMissedCall()
        m.number = "+15551234567"; m.atMs = 4242
        await h.model.missed(m)
        #expect(h.presenter.delivered.count == 1)
        let d = h.presenter.delivered[0]
        #expect(d.id == "m|P1|4242")
        #expect(d.content.title == "Missed call")
        #expect(d.content.subtitle == "Ann Lee")
        #expect(d.content.body == "+15551234567")
        #expect(d.content.categoryIdentifier.isEmpty)
        #expect(h.presenter.categoryCalls == 0)
    }

    @Test func switchedOffIgnoresCallsAndMissed() async {
        let h = Harness()
        h.model.enabled = false
        h.model.apply(call("c1"))
        var m = AMMissedCall(); m.number = "1"; m.atMs = 1
        await h.model.missed(m)
        #expect(h.model.ringing.isEmpty)
        #expect(h.presenter.delivered.isEmpty)
    }

    @Test func toggleMuteSendsMuteThenUnmute() async {
        let h = Harness()
        h.model.apply(call("c1", .active, muted: false))
        await h.model.toggleMute()
        h.model.apply(call("c1", .active, muted: true))
        await h.model.toggleMute()
        #expect(h.commands.map(\.action) == [.mute, .unmute])
        await h.model.hangUp()
        #expect(h.commands.last?.action == .hangUp)
    }

    @Test func disconnectClearsCalls() {
        let h = Harness()
        h.model.apply(call("c1"))
        h.model.apply(call("c2", .active))
        h.model.reset()
        #expect(h.model.ringing.isEmpty)
        #expect(h.model.active == nil)
    }

    @Test func elapsedFormatsMinutesSeconds() {
        let h = Harness()
        #expect(h.model.elapsed(now: h.clock) == nil)
        h.model.apply(call("c1", .active, since: 5))        // the phone's clock is ignored
        #expect(h.model.elapsed(now: h.clock.addingTimeInterval(133)) == "02:13")
        #expect(h.model.elapsed(now: h.clock.addingTimeInterval(-50)) == "00:00")
        #expect(h.model.elapsed(now: h.clock.addingTimeInterval(3_725)) == "1:02:05")
        h.clock = h.clock.addingTimeInterval(60)
        h.model.apply(call("c1", .active, muted: true, since: 9))   // same id: start time is kept
        #expect(h.model.elapsed(now: h.clock) == "01:00")
    }

    private func settle(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func elapsedTicksWhileActive() async {
        let h = Harness()
        h.model.apply(call("c1", .active))
        #expect(h.model.elapsedText == "00:00")
        h.clock = h.clock.addingTimeInterval(7)
        h.ticks.continuation.yield()
        await settle { h.model.elapsedText == "00:07" }
        #expect(h.model.elapsedText == "00:07")
    }

    @Test func tickStopsOnEndAndReset() async {
        let h = Harness()
        h.model.apply(call("c1", .active))
        h.model.apply(call("c1", .ended))
        #expect(h.model.elapsedText == nil)
        h.clock = h.clock.addingTimeInterval(5)
        h.ticks.continuation.yield()
        await settle { false }
        #expect(h.model.elapsedText == nil)
        h.model.apply(call("c2", .active))
        h.model.reset()
        #expect(h.model.elapsedText == nil)
        h.ticks.continuation.yield()
        await settle { false }
        #expect(h.model.elapsedText == nil)
    }
}
