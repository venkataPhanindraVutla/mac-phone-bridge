import Testing
@testable import FeatureInput

@Test func scrollPhasesBeginChangeAndBeginAgainAfterAPause() {
    var phases = ScrollPhases()
    #expect(phases.next(at: 10) == .began)
    #expect(phases.next(at: 10.01) == .changed)
    #expect(phases.next(at: 10.1) == .changed)
    // Ended (by the poster's timer) after a pause: the next scroll is a new gesture.
    #expect(phases.endDue(at: 10.1 + ScrollPhases.gap))
    #expect(!phases.endDue(at: 10.1 + ScrollPhases.gap / 2))
    phases.end()
    #expect(!phases.endDue(at: 20))
    #expect(phases.next(at: 10.3) == .began)
    #expect(phases.next(at: 11) == .began)
}
