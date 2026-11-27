import AMProtocol
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureHotspot

private final class FakeJoiner: WiFiJoining, @unchecked Sendable {
    var joined: [HotspotNetwork] = []
    var fails = false
    func join(_ network: HotspotNetwork) async throws {
        if fails { throw CancellationError() }
        joined.append(network)
    }
}

@MainActor
private final class Rig {
    let joiner = FakeJoiner()
    var sent: [AMHotspotRequest] = []
    var saved: [String: HotspotNetwork] = [:]
    /// The phone's answer to each request; nil: no answer.
    var reply: ((AMHotspotRequest) -> AMHotspotState?)?
    var model: HotspotModel!

    init() {
        model = HotspotModel(
            send: { [weak self] _, message in
                guard let self, let r = message as? AMHotspotRequest else { return }
                self.sent.append(r)
                if let state = self.reply?(r) {
                    var e = AMEnvelope()
                    e.type = MessageType.hotspotState.rawValue
                    e.payload = (try? state.serializedData()) ?? Data()
                    await self.model.message(e)
                }
            },
            joiner: joiner,
            load: { [weak self] in self?.saved[$0] },
            store: { [weak self] id, n in self?.saved[id] = n })
        model.answerTimeout = .milliseconds(200)
    }

    func connect(enabled: Bool = true, shared: Set<String> = ["hotspot.v1"]) async {
        await model.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
        var a = AMFeatureAvailability()
        a.enabled = enabled
        if !enabled { a.reason = .needsSetup }
        var e = AMEnvelope()
        e.type = MessageType.hotspotAvailability.rawValue
        e.payload = try! a.serializedData()
        await model.message(e)
    }
}

private func on(_ ssid: String = "Pixel hotspot", pass: String = "secret12") -> AMHotspotState {
    var s = AMHotspotState()
    s.on = true; s.ssid = ssid; s.passphrase = pass; s.security = .wpa2
    return s
}

@MainActor @Test func useHotspotTurnsItOnSavesAndJoins() async {
    let r = Rig()
    r.reply = { _ in on() }
    await r.connect()
    #expect(r.model.canUseHotspot)
    await r.model.useHotspot()
    #expect(r.sent.map(\.on) == [true])
    let network = HotspotNetwork(ssid: "Pixel hotspot", passphrase: "secret12", security: AMHotspotSecurity.wpa2.rawValue)
    #expect(r.saved["P1"] == network)
    #expect(r.joiner.joined == [network])
    #expect(r.model.phase == .joined(ssid: "Pixel hotspot"))
    // The session drops as the Mac moves networks: the phase stays.
    r.model.disconnected()
    #expect(r.model.phase == .joined(ssid: "Pixel hotspot"))
}

@MainActor @Test func refusalsAndSilenceAreFailures() async {
    let r = Rig()
    var refused = AMHotspotState()
    refused.failure = .refused
    r.reply = { _ in refused }
    await r.connect()
    await r.model.useHotspot()
    #expect(r.model.phase == .failed(.refused))
    #expect(r.joiner.joined.isEmpty)
    r.reply = nil
    await r.model.useHotspot()
    #expect(r.model.phase == .failed(.failed))
    #expect(r.saved.isEmpty)
}

@MainActor @Test func nothingIsAskedWithoutFullModeOrTheCapability() async {
    let r = Rig()
    await r.connect(enabled: false)
    #expect(!r.model.canUseHotspot)
    await r.model.useHotspot()
    await r.connect(shared: ["status.v1"])
    await r.model.useHotspot()
    #expect(r.sent.isEmpty)
}

@MainActor @Test func savedNetworkIsJoinedWhenApartAndGoesWithForget() async {
    let r = Rig()
    r.saved["P1"] = HotspotNetwork(ssid: "Pixel hotspot", passphrase: "secret12", security: 2)
    await r.model.joinSaved(phoneID: "P1")
    #expect(r.joiner.joined.map(\.ssid) == ["Pixel hotspot"])
    r.joiner.fails = true
    await r.model.joinSaved(phoneID: "P1")
    #expect(r.model.phase == .failed(.joinFailed))
    await r.model.forget(phoneID: "P1")
    #expect(r.model.savedNetwork(for: "P1") == nil)
}

@MainActor @Test func turnOffAsksThePhoneAndEndsIdleEvenWithoutAnAnswer() async {
    let r = Rig()
    await r.connect()
    await r.model.turnOff()
    #expect(r.sent.map(\.on) == [false])
    #expect(r.model.phase == .idle)
}
