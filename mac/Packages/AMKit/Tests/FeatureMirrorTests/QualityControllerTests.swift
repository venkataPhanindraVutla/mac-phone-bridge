import Foundation
import Testing
@testable import FeatureMirror

/// Drives a controller one evaluation per second from a fixed start.
private struct Driver {
    var controller: QualityController
    let t0 = ContinuousClock.now
    private(set) var seconds = 0

    init(start: QualityPreset = .high) { controller = QualityController(start: start) }

    /// `count` evaluations with the same inputs; every decision but the last must be `keep`.
    mutating func tick(_ count: Int, medianMs: Double?, backlog: Int = 0) -> QualityController.Decision {
        var decision = QualityController.Decision.keep
        for i in 0..<count {
            seconds += 1
            decision = controller.tick(medianMs: medianMs, backlog: backlog, now: t0 + .seconds(seconds))
            if i < count - 1, decision != .keep { return .switchTo(.init(name: "early at \(i + 1)", maxSize: 0, bitRate: 0, maxFps: 0)) }
        }
        return decision
    }

    mutating func late(_ count: Int) -> QualityController.Decision { tick(count, medianMs: 200) }
    /// Time passes with no evaluation (a delay measurement, a restart, availability off).
    mutating func skip(_ count: Int) { seconds += count }
    mutating func healthy(_ count: Int) -> QualityController.Decision { tick(count, medianMs: 20) }
}

@Suite struct QualityControllerTests {
    @Test func startsAtHighWithAutoOn() {
        let controller = QualityController()
        #expect(controller.preset == .high)
        #expect(controller.auto)
    }

    @Test func sustainedLatenessStepsDown() {
        var d = Driver()
        #expect(d.late(5) == .switchTo(.balanced))
        #expect(d.controller.preset == .balanced)
        // Five more late seconds at Balanced: Low.
        #expect(d.late(5) == .switchTo(.low))
    }

    @Test func shortSpikeDoesNotStepDown() {
        var d = Driver()
        #expect(d.late(4) == .keep)
        #expect(d.healthy(1) == .keep)
        #expect(d.late(4) == .keep)
        #expect(d.controller.preset == .high)
        // A missing median (no frames) breaks the run too.
        #expect(d.tick(1, medianMs: nil) == .keep)
        #expect(d.late(4) == .keep)
    }

    @Test func backlogStepsDown() {
        var d = Driver()
        #expect(d.tick(4, medianMs: 20, backlog: 7) == .keep)
        #expect(d.tick(1, medianMs: 20, backlog: 6) == .keep)
        #expect(d.tick(5, medianMs: 20, backlog: 7) == .switchTo(.balanced))
    }

    @Test func stepUpAfter60sHealthy() {
        var d = Driver(start: .low)
        #expect(d.healthy(59) == .keep)
        #expect(d.healthy(1) == .switchTo(.balanced))
        #expect(d.healthy(60) == .switchTo(.high))
        // High never steps higher.
        #expect(d.healthy(120) == .keep)
        #expect(d.controller.preset == .high)
    }

    @Test func noStepUpWhileMedianAbove75() {
        var d = Driver(start: .balanced)
        #expect(d.healthy(59) == .keep)
        // 76 ms is not late (≤ 150) but not healthy: the 60 s start again.
        #expect(d.tick(1, medianMs: 76) == .keep)
        #expect(d.healthy(59) == .keep)
        #expect(d.tick(1, medianMs: 20, backlog: 7) == .keep)
        #expect(d.healthy(59) == .keep)
        #expect(d.healthy(1) == .switchTo(.high))
    }

    /// A step up followed by a step down within 30 s doubles the next wait at that preset:
    /// 60 → 120 → 240 → 480 → 600 s, and no more.
    @Test func failedStepUpBacksOff() {
        var d = Driver(start: .balanced)
        for wait in [60, 120, 240, 480, 600, 600] {
            #expect(d.healthy(wait - 1) == .keep, "wait \(wait)")
            #expect(d.healthy(1) == .switchTo(.high), "wait \(wait)")
            #expect(d.late(5) == .switchTo(.balanced), "wait \(wait)")
        }
    }

    /// A step down more than 30 s after the step up is not a failed step up.
    @Test func lateStepDownKeepsTheWait() {
        var d = Driver(start: .balanced)
        #expect(d.healthy(60) == .switchTo(.high))
        #expect(d.healthy(30) == .keep)
        #expect(d.late(5) == .switchTo(.balanced))
        #expect(d.healthy(60) == .switchTo(.high))
    }

    @Test func backoffResetsAfter10Minutes() {
        var d = Driver(start: .balanced)
        #expect(d.healthy(60) == .switchTo(.high))
        #expect(d.late(5) == .switchTo(.balanced)) // failed: 120 s next
        #expect(d.healthy(120) == .switchTo(.high))
        #expect(d.late(5) == .switchTo(.balanced)) // failed again: 240 s next
        #expect(d.healthy(240) == .switchTo(.high))
        // Ten minutes at High: Balanced's wait is back to 60 s.
        #expect(d.healthy(600) == .keep)
        #expect(d.late(5) == .switchTo(.balanced))
        #expect(d.healthy(60) == .switchTo(.high))
    }

    /// M1: a run is of evaluations a second apart; a gap (no evaluation for a while) starts it again.
    @Test func gapInEvaluationsStartsTheRunsAgain() {
        var d = Driver(start: .balanced)
        #expect(d.healthy(59) == .keep)
        d.skip(100)
        #expect(d.healthy(1) == .keep)
        #expect(d.healthy(58) == .keep)
        #expect(d.healthy(1) == .switchTo(.high))
        #expect(d.late(3) == .keep)
        d.skip(30)
        #expect(d.late(2) == .keep)
        #expect(d.late(2) == .keep)
        #expect(d.late(1) == .switchTo(.balanced))
    }

    /// M2: each step up keeps its own back-off: after Low → Balanced → High and 10 minutes at High,
    /// both Low's and Balanced's waits are back to 60 s.
    @Test func backoffResetsForEveryStepUpBelow() {
        var d = Driver(start: .low)
        #expect(d.healthy(60) == .switchTo(.balanced))
        #expect(d.late(5) == .switchTo(.low)) // failed: Low waits 120 s
        #expect(d.healthy(120) == .switchTo(.balanced))
        #expect(d.healthy(60) == .switchTo(.high))
        #expect(d.healthy(600) == .keep)
        #expect(d.late(5) == .switchTo(.balanced))
        #expect(d.late(5) == .switchTo(.low))
        #expect(d.healthy(60) == .switchTo(.balanced))
    }

    @Test func manualOverridesAuto() {
        var d = Driver()
        d.controller.choose(.low)
        #expect(!d.controller.auto)
        #expect(d.controller.preset == .low)
        #expect(d.healthy(120) == .keep)
        #expect(d.late(10) == .keep)
        #expect(d.controller.preset == .low)
        // Auto again: it goes on from the chosen preset.
        d.controller.auto = true
        #expect(d.healthy(60) == .switchTo(.balanced))
    }

    @Test func lowestPresetStaysLow() {
        var d = Driver(start: .low)
        #expect(d.late(5) == .keep)
        #expect(d.late(30) == .keep)
        #expect(d.tick(10, medianMs: 20, backlog: 20) == .keep)
        #expect(d.controller.preset == .low)
    }

    /// The phone ended the session with LINK_SLOW: under Auto the next start is one preset lower.
    @Test func linkSlowStepsDownUnderAuto() {
        var d = Driver()
        d.controller.linkTooSlow(now: d.t0)
        #expect(d.controller.preset == .balanced)
        d.controller.linkTooSlow(now: d.t0)
        d.controller.linkTooSlow(now: d.t0)
        #expect(d.controller.preset == .low)
        var manual = QualityController()
        manual.choose(.high)
        manual.linkTooSlow(now: d.t0)
        #expect(manual.preset == .high)
    }
}
