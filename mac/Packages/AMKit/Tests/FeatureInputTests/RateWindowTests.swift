import Foundation
import Testing
import FeatureInput

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func admits240ThenDrops() {
    var w = RateWindow()
    let admitted = (0..<300).filter { w.admit(at: t0.addingTimeInterval(Double($0) * 0.001)) }.count
    #expect(admitted == 240)
}

@Test func windowSlides() {
    var w = RateWindow()
    for _ in 0..<120 { do { let ok = w.admit(at: t0); #expect(ok) } }
    for _ in 0..<120 { do { let ok = w.admit(at: t0.addingTimeInterval(0.5)); #expect(ok) } }
    do { let ok = w.admit(at: t0.addingTimeInterval(0.999)); #expect(!ok) }
    // The first 120 have left the window; the second 120 are still in it.
    for _ in 0..<120 { do { let ok = w.admit(at: t0.addingTimeInterval(1)); #expect(ok) } }
    do { let ok = w.admit(at: t0.addingTimeInterval(1.2)); #expect(!ok) }
    do { let ok = w.admit(at: t0.addingTimeInterval(1.5)); #expect(ok) }
}

@Test func recordedFramesCount() {
    var w = RateWindow(limit: 3, span: 1)
    w.record(at: t0)
    w.record(at: t0)
    do { let ok = w.admit(at: t0); #expect(ok) }
    do { let ok = w.admit(at: t0); #expect(!ok) }
    // Recorded even when the window is full.
    w.record(at: t0.addingTimeInterval(0.5))
    do { let ok = w.admit(at: t0.addingTimeInterval(0.9)); #expect(!ok) }
    // The three at t0 leave; the recorded one at 0.5 and this one stay.
    do { let ok = w.admit(at: t0.addingTimeInterval(1)); #expect(ok) }
    do { let ok = w.admit(at: t0.addingTimeInterval(1)); #expect(ok) }
    do { let ok = w.admit(at: t0.addingTimeInterval(1)); #expect(!ok) }
}
