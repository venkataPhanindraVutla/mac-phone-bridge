import CoreGraphics
import Foundation
import Testing
import FeatureInput

/// A 1440 × 900 screen with a taller 1920 × 1080 one to its right, tops aligned: below the
/// smaller one is a gap that belongs to neither.
private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]

@Test func pointerClampsToNearestScreen() {
    // In the gap below the smaller screen: onto its bottom edge, not into the gap.
    #expect(PointerMath.clamp(CGPoint(x: 700, y: 1000), to: screens) == CGPoint(x: 700, y: 899))
    // Nearer the larger screen's left edge than the smaller one's bottom.
    #expect(PointerMath.clamp(CGPoint(x: 1430, y: 1000), to: screens) == CGPoint(x: 1440, y: 1000))
    #expect(PointerMath.clamp(CGPoint(x: -50, y: 500), to: screens) == CGPoint(x: 0, y: 500))
    #expect(PointerMath.clamp(CGPoint(x: 2000, y: -30), to: screens) == CGPoint(x: 2000, y: 0))
    #expect(PointerMath.clamp(CGPoint(x: 4000, y: 2000), to: screens) == CGPoint(x: 3359, y: 1079))
}

@Test func insidePointIsUnchanged() {
    for p in [CGPoint(x: 700, y: 450), CGPoint(x: 1440, y: 1000), CGPoint(x: 3000, y: 50), CGPoint(x: 10.5, y: 20.25), .zero] {
        #expect(PointerMath.clamp(p, to: screens) == p)
    }
    // No screens known: left alone.
    #expect(PointerMath.clamp(CGPoint(x: -5, y: -5), to: []) == CGPoint(x: -5, y: -5))
}

@Test func clampRunsOffTheMainActor() async {
    let p = await Task.detached { PointerMath.clamp(CGPoint(x: 700, y: 1000), to: screens) }.value
    #expect(p == CGPoint(x: 700, y: 899))
}
