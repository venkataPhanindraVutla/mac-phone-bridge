import Foundation
import Testing
@testable import FeatureMirror

/// The phone's delay test screen, as the probe sees it through the decoder: black, white while a
/// finger is down. Each answer is stamped `delay` after the tap (or never, for a dropped trial).
@MainActor
private final class FakeScreen {
    let frames = AsyncStream.makeStream(of: (Double, ContinuousClock.Instant).self)
    /// Per trial: how long the white takes, or nil for no answer.
    var delays: [Duration?]
    /// How long the black takes after the finger lifts (0: at once).
    var blackAfter: Duration = .zero
    private(set) var downs = 0
    private(set) var ups = 0
    /// For each DOWN: whether the screen was still white then.
    private(set) var downWhileWhite: [Bool] = []
    private var white = false

    init(delays: [Duration?]) {
        self.delays = delays
        frames.continuation.yield((16, .now)) // the test screen starts black
    }

    func tap(_ down: Bool) {
        if down {
            downWhileWhite.append(white)
            let trial = downs
            downs += 1
            guard trial < delays.count, let delay = delays[trial] else { return }
            white = true
            frames.continuation.yield((235, ContinuousClock.now + delay))
        } else {
            ups += 1
            guard white else { return }
            if blackAfter == .zero {
                white = false
                frames.continuation.yield((16, .now))
                return
            }
            Task { [blackAfter] in
                try? await Task.sleep(for: blackAfter)
                self.white = false
                self.frames.continuation.yield((16, .now))
            }
        }
    }

    func probe(trials: Int, timeout: Duration = .seconds(3), pause: Duration = .zero) -> DelayProbe {
        let stream = frames.stream
        return DelayProbe(tap: { [unowned self] in tap($0) }, luma: { stream }, trials: trials, timeout: timeout, pause: pause)
    }
}

@MainActor
@Suite struct DelayProbeTests {
    @Test func medianAndP95FromTrials() async {
        let delays: [Duration?] = (1...20).map { .milliseconds($0 * 10) }
        let screen = FakeScreen(delays: delays.reversed())
        let result = await screen.probe(trials: 20).run()
        #expect(result.trials == 20)
        #expect(result.misses == 0)
        // 10 ... 200 ms: the median is between 100 and 110, the 95th percentile (nearest rank) 190.
        #expect(abs(result.medianMs - 105) < 2)
        #expect(abs(result.p95Ms - 190) < 2)
        #expect(abs(result.minMs - 10) < 2)
        #expect(screen.downs == 20 && screen.ups == 20)
    }

    @Test func timeoutCountsMiss() async {
        let screen = FakeScreen(delays: [.milliseconds(40), nil, .milliseconds(60), nil])
        let started = ContinuousClock.now
        let result = await screen.probe(trials: 4, timeout: .milliseconds(80)).run()
        #expect(result.trials == 4)
        #expect(result.misses == 2)
        #expect(abs(result.medianMs - 50) < 2)
        #expect(abs(result.minMs - 40) < 2)
        // Each miss waited the timeout, no longer.
        #expect(ContinuousClock.now - started >= .milliseconds(160))
        #expect(ContinuousClock.now - started < .seconds(2))
        // The finger is lifted after a miss too.
        #expect(screen.ups == 4)
    }

    @Test func waitsForBlackBeforeEachTrial() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(20), count: 5))
        screen.blackAfter = .milliseconds(30)
        let result = await screen.probe(trials: 5).run()
        #expect(result.misses == 0)
        #expect(screen.downWhileWhite == [false, false, false, false, false])
    }

    @Test func pauseBetweenTrials() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(5), count: 3))
        let started = ContinuousClock.now
        _ = await screen.probe(trials: 3, pause: .milliseconds(100)).run()
        // Two pauses between three trials.
        #expect(ContinuousClock.now - started >= .milliseconds(200))
    }

    /// The frames stop (the session ended): the probe returns with the trials it ran.
    @Test func endOfFramesEndsTheRun() async {
        let screen = FakeScreen(delays: [.milliseconds(10)])
        screen.frames.continuation.finish()
        let started = ContinuousClock.now
        let result = await screen.probe(trials: 50).run()
        #expect(result.trials <= 1)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func percentilesOfFewValues() {
        #expect(DelayProbe.summary([30], trials: 1, misses: 0) == DelayResult(medianMs: 30, p95Ms: 30, minMs: 30, trials: 1, misses: 0, fpsMean: 0))
        let r = DelayProbe.summary([40, 10, 30, 20], trials: 5, misses: 1)
        #expect(r == DelayResult(medianMs: 25, p95Ms: 40, minMs: 10, trials: 5, misses: 1, fpsMean: 0))
        #expect(DelayProbe.summary([], trials: 3, misses: 3) == DelayResult(medianMs: 0, p95Ms: 0, minMs: 0, trials: 3, misses: 3, fpsMean: 0))
    }
}
