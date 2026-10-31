import Foundation
import Testing
@testable import FeatureMirror

@Suite struct LatenessMeterTests {
    private let t0 = ContinuousClock.now

    /// Frames every 16.667 ms arriving a fixed 80 ms after they were made: no lateness.
    @Test func constantDelayReadsZero() {
        var meter = LatenessMeter()
        for i in 0..<120 {
            let pts = UInt64(i) * 16_667
            let lateness = meter.record(pts: pts, arrival: t0 + .microseconds(Int64(pts) + 80_000))
            #expect(abs(lateness) < 0.01)
        }
        #expect(abs(meter.median(last: .seconds(5), now: t0 + .seconds(2)) ?? -1) < 0.01)
    }

    /// Each frame arrives 10 ms later than the one before (relative to its PTS): the lateness grows.
    @Test func growingDelayReadsGrowth() {
        var meter = LatenessMeter()
        var last = 0.0
        for i in 0..<30 {
            let pts = UInt64(i) * 16_667
            last = meter.record(pts: pts, arrival: t0 + .microseconds(Int64(pts) + Int64(i) * 10_000))
        }
        #expect(abs(last - 290) < 0.01)
        // The last 5 s hold all 30 frames: 0, 10, ..., 290 ms; the median is between 140 and 150.
        let median = meter.median(last: .seconds(5), now: t0 + .seconds(1))
        #expect(abs((median ?? 0) - 145) < 0.01)
        // Only the frames of the last 100 ms (the last 6 or so) count for a short window.
        let short = meter.median(last: .milliseconds(100), now: t0 + .microseconds(29 * 16_667 + 290_000))
        #expect((short ?? 0) > 240)
    }

    /// A low point older than the window no longer counts: lateness is measured from the newer minimum.
    @Test func oldMinimumLeavesWindow() {
        var meter = LatenessMeter(window: .seconds(10))
        // One early frame with no delay at all, then frames 200 ms behind.
        #expect(meter.record(pts: 0, arrival: t0) == 0)
        var lateness = 0.0
        for s in 1...9 {
            lateness = meter.record(pts: UInt64(s) * 1_000_000, arrival: t0 + .seconds(s) + .milliseconds(200))
        }
        #expect(abs(lateness - 200) < 0.01)
        // 11 s on, the early frame has left the 10 s window: 200 ms behind is the new normal.
        lateness = meter.record(pts: 11_000_000, arrival: t0 + .seconds(11) + .milliseconds(200))
        #expect(abs(lateness) < 0.01)
        // A median over a window with no frames is nil.
        #expect(meter.median(last: .seconds(1), now: t0 + .seconds(30)) == nil)
    }

    /// A PTS that goes back is a stream that started over: the meter starts over with it. PTS that
    /// go on (an encoder restart after RESET_VIDEO) keep the lateness.
    @Test func ptsGoingBackStartsOver() {
        var meter = LatenessMeter()
        #expect(meter.record(pts: 0, arrival: t0) == 0)
        #expect(abs(meter.record(pts: 1_000_000, arrival: t0 + .milliseconds(1_400)) - 400) < 0.01)
        #expect(abs(meter.record(pts: 1_016_667, arrival: t0 + .microseconds(1_416_667)) - 400) < 0.01)
        #expect(meter.record(pts: 5_000, arrival: t0 + .milliseconds(1_500)) == 0)
        #expect(abs(meter.record(pts: 105_000, arrival: t0 + .milliseconds(1_700)) - 100) < 0.01)
    }

    /// A burst (frames arriving faster than they were made, after a stall clears) is not late.
    @Test func burstIsNotLate() {
        var meter = LatenessMeter()
        for i in 0..<30 {
            #expect(meter.record(pts: UInt64(i) * 16_667, arrival: t0) == 0)
        }
    }
}
