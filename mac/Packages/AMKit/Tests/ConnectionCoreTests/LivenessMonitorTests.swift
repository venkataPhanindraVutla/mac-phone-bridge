import Testing
@testable import ConnectionCore

/// SPEC 7, with `liveness.v1`: a tick is one Mac ping interval; the hello counts as received, and
/// the phone is dropped at the third consecutive tick with nothing received.
@Suite struct LivenessMonitorTests {
    @Test func firstTickAfterHelloSendsPing() {
        var m = LivenessMonitor()
        #expect(m.tick() == .sendPing)
    }

    @Test func dropsOnFourthTickWithNothingReceived() {
        var m = LivenessMonitor()
        #expect([m.tick(), m.tick(), m.tick(), m.tick()] == [.sendPing, .sendPing, .sendPing, .drop])
    }

    @Test func anyMessageResetsTheCount() {
        var m = LivenessMonitor()
        #expect([m.tick(), m.tick(), m.tick()] == [.sendPing, .sendPing, .sendPing])
        m.received()
        #expect([m.tick(), m.tick(), m.tick(), m.tick()] == [.sendPing, .sendPing, .sendPing, .drop])
    }

    @Test func customLimit() {
        var m = LivenessMonitor(missedLimit: 1)
        #expect([m.tick(), m.tick()] == [.sendPing, .drop])
    }

    @Test func capabilityString() {
        #expect(Liveness.capability == "liveness.v1")
    }
}
