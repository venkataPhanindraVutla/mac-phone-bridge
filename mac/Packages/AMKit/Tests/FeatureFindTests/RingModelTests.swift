import AMProtocol
import Testing
@testable import FeatureFind

private func state(ringing: Bool, silent: Bool = false) -> AMRingState {
    var s = AMRingState()
    s.ringing = ringing
    s.mayBeSilent = silent
    return s
}

@MainActor
@Test func menuTitleToggles() {
    let model = RingModel()
    #expect(model.menuTitle == "Ring phone")
    model.apply(state(ringing: true))
    #expect(model.menuTitle == "Stop ringing")
    model.apply(state(ringing: false))
    #expect(model.menuTitle == "Ring phone")
}

@MainActor
@Test func mayBeSilentShowsNote() {
    let model = RingModel()
    #expect(model.note == nil)
    model.apply(state(ringing: true, silent: true))
    #expect(model.note == "The phone may be silent. Allow Do Not Disturb access in the phone app.")
    model.apply(state(ringing: true, silent: false))
    #expect(model.note == nil)
}

@MainActor
@Test func disconnectWhileRingingShowsStopOnPhoneHint() {
    let model = RingModel()
    model.apply(state(ringing: true))
    model.reset()
    #expect(model.ringing == false)
    #expect(model.possiblyStillRinging)
    #expect(model.note == "Phone may still be ringing. Stop it on the phone.")
    #expect(model.menuTitle == "Ring phone")
    // the next RingState clears it
    model.apply(state(ringing: false))
    #expect(model.possiblyStillRinging == false)
    #expect(model.note == nil)
}

@MainActor
@Test func resetWhileIdleShowsNoHint() {
    let model = RingModel()
    model.reset()
    #expect(model.possiblyStillRinging == false)
    #expect(model.note == nil)
}

@MainActor
@Test func reconnectClearsHint() {
    let model = RingModel()
    model.apply(state(ringing: true))
    model.reset()
    model.clearHint() // called on connect
    #expect(model.possiblyStillRinging == false)
}
