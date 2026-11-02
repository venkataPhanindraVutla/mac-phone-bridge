import Foundation
import Testing
@testable import FeatureMirror

/// Virtual time for a probe and its fake screen: it stands still until `advance()` moves it to the
/// earliest deadline someone sleeps until. The probe's timeouts, settle time and pauses, and the
/// screen's frames, all run on it, so a busy main actor (every suite in one process on a slow CI
/// runner) can delay a test but never make a deadline pass early.
private final class VirtualClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var sleepers: [Int: Sleeper] = [:]
    private var lastID = 0

    var now: ContinuousClock.Instant { lock.withLock { current } }

    var delayClock: DelayClock {
        DelayClock(now: { [self] in now }, sleep: { [self] deadline in try await sleep(until: deadline) })
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id: Int = lock.withLock {
            lastID += 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    c.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    lock.unlock()
                }
            }
        } onCancel: {
            let s = lock.withLock { sleepers.removeValue(forKey: id) }
            s?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves to the earliest deadline anyone sleeps until and wakes everyone due by then.
    func advance() {
        let due: [Sleeper] = lock.withLock {
            guard let next = sleepers.values.map(\.deadline).min() else { return [] }
            current = max(current, next)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return Array(ready.values)
        }
        for s in due { s.continuation.resume() }
    }
}

/// The phone's screen as the probe sees it through the decoder, repeated every 10 ms like a static
/// screen: the delay test screen (black, the corner marker, white while a finger is down) or, with
/// `marker` off, a dark user screen. A white answer is stamped `delay` after the tap (or never,
/// for a dropped trial).
@MainActor
private final class FakeScreen {
    let frames = AsyncStream.makeStream(of: DelayFrame.self)
    /// The time the screen and the probe run on.
    let clock = VirtualClock()
    /// Per trial: how long the white takes, or nil for no answer.
    var delays: [Duration?]
    /// How long the black takes after the finger lifts (0: at once).
    var blackAfter: Duration = .zero
    /// The test screen's corner marker is shown (false: the user's own dark screen).
    var marker = true
    /// The marker shows on every other frame only (never three in a row).
    var flicker = false
    private(set) var downs = 0
    private(set) var ups = 0
    private(set) var downTimes: [ContinuousClock.Instant] = []
    /// For each DOWN: whether the screen was still white then.
    private(set) var downWhileWhite: [Bool] = []
    private var down = false
    private var whiteFrom: ContinuousClock.Instant?
    private var blackFrom: ContinuousClock.Instant?
    private var ticks = 0
    private var repeater: Task<Void, Never>?

    init(delays: [Duration?]) {
        self.delays = delays
    }

    private func white(at now: ContinuousClock.Instant) -> Bool {
        if down { return whiteFrom.map { now >= $0 } ?? false }
        return blackFrom.map { now < $0 } ?? false
    }

    private func frame(at now: ContinuousClock.Instant) -> DelayFrame {
        ticks += 1
        let white = white(at: now)
        let marked = marker && !white && (!flicker || ticks % 2 == 0)
        return DelayFrame(centerLuma: white ? 235 : 16, marker: marked, at: now)
    }

    func start() {
        repeater = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                frames.continuation.yield(frame(at: clock.now))
                try? await clock.sleep(until: clock.now + .milliseconds(10))
            }
        }
    }

    func stop() {
        repeater?.cancel()
        frames.continuation.finish()
    }

    func tap(_ isDown: Bool) {
        let now = clock.now
        if isDown {
            downWhileWhite.append(white(at: now))
            downTimes.append(now)
            let trial = downs
            downs += 1
            down = true
            whiteFrom = nil
            guard trial < delays.count, let delay = delays[trial] else { return }
            whiteFrom = now + delay
            frames.continuation.yield(DelayFrame(centerLuma: 235, marker: false, at: now + delay))
        } else {
            ups += 1
            let wasWhite = white(at: now)
            down = false
            blackFrom = wasWhite ? now + blackAfter : nil
        }
    }

    func run(trials: Int, timeout: Duration = .seconds(3), pause: Duration = .zero,
             settle: Duration = .milliseconds(30), markerTimeout: Duration = .seconds(2)) async -> DelayResult {
        let stream = frames.stream
        let probe = DelayProbe(tap: { [weak self] in self?.tap($0) }, frames: { stream }, trials: trials, timeout: timeout, pause: pause)
        probe.settle = settle
        probe.markerTimeout = markerTimeout
        probe.clock = clock.delayClock
        start()
        // Time moves only once every main-actor job queued so far (the probe's, the screen's, the
        // frame pump's) has had its turn, and then to the next deadline.
        let time = clock
        let driver = Task {
            while !Task.isCancelled {
                for _ in 0..<20 { await Task.yield() }
                time.advance()
            }
        }
        defer {
            driver.cancel()
            stop()
        }
        return await probe.run()
    }
}

@MainActor
@Suite struct DelayProbeTests {
    @Test func medianAndP95FromTrials() async {
        let delays: [Duration?] = (1...20).map { .milliseconds($0 * 10) }
        let screen = FakeScreen(delays: delays.reversed())
        let result = await screen.run(trials: 20)
        #expect(result.testScreenOpened)
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
        let started = screen.clock.now
        let result = await screen.run(trials: 4, timeout: .milliseconds(80))
        #expect(result.trials == 4)
        #expect(result.misses == 2)
        #expect(abs(result.medianMs - 50) < 2)
        #expect(abs(result.minMs - 40) < 2)
        // Each miss waited the timeout, no longer.
        #expect(screen.clock.now - started >= .milliseconds(160))
        #expect(screen.clock.now - started < .seconds(2))
        // The finger is lifted after a miss too.
        #expect(screen.ups == 4)
    }

    @Test func waitsForBlackBeforeEachTrial() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(20), count: 5))
        screen.blackAfter = .milliseconds(30)
        let result = await screen.run(trials: 5)
        #expect(result.misses == 0)
        #expect(screen.downWhileWhite == [false, false, false, false, false])
    }

    @Test func pauseBetweenTrials() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(5), count: 3))
        let started = screen.clock.now
        _ = await screen.run(trials: 3, pause: .milliseconds(100))
        // Two pauses between three trials.
        #expect(screen.clock.now - started >= .milliseconds(200))
    }

    /// R56: the user's own dark screen (a black centre, no corner marker) never gets a tap.
    @Test func darkUserScreenWithoutTheMarkerGetsNoTap() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(20), count: 5))
        screen.marker = false
        let result = await screen.run(trials: 5, markerTimeout: .milliseconds(300))
        #expect(screen.downs == 0 && screen.ups == 0)
        #expect(!result.testScreenOpened)
        #expect(result.trials == 0 && result.misses == 0)
    }

    /// R56: the marker on three frames in a row and the settle time since DELAY: then the taps.
    @Test func markerAndSettleTimeGetTaps() async {
        let screen = FakeScreen(delays: Array(repeating: .milliseconds(20), count: 2))
        let started = screen.clock.now
        let result = await screen.run(trials: 2, settle: .milliseconds(300))
        #expect(result.testScreenOpened)
        #expect(result.trials == 2 && result.misses == 0)
        #expect(screen.downs == 2)
        #expect(screen.downTimes.allSatisfy { $0 - started >= .milliseconds(300) })
    }

    /// A marker that never holds for three frames in a row is not the test screen.
    @Test func flickeringMarkerGetsNoTap() async {
        let screen = FakeScreen(delays: [.milliseconds(20)])
        screen.flicker = true
        let result = await screen.run(trials: 1, markerTimeout: .milliseconds(300))
        #expect(screen.downs == 0)
        #expect(!result.testScreenOpened)
    }

    /// The frames stop (the session ended): the probe returns at once, having tapped nothing.
    @Test func endOfFramesEndsTheRun() async {
        let screen = FakeScreen(delays: [.milliseconds(10)])
        screen.frames.continuation.finish()
        let started = screen.clock.now
        let result = await screen.run(trials: 50)
        #expect(result.trials == 0)
        #expect(screen.downs == 0)
        // Not the 2 s marker timeout.
        #expect(screen.clock.now - started < .seconds(1))
    }

    @Test func percentilesOfFewValues() {
        #expect(DelayProbe.summary([30], trials: 1, misses: 0) == DelayResult(medianMs: 30, p95Ms: 30, minMs: 30, trials: 1, misses: 0, fpsMean: 0))
        let r = DelayProbe.summary([40, 10, 30, 20], trials: 5, misses: 1)
        #expect(r == DelayResult(medianMs: 25, p95Ms: 40, minMs: 10, trials: 5, misses: 1, fpsMean: 0))
        #expect(DelayProbe.summary([], trials: 3, misses: 3) == DelayResult(medianMs: 0, p95Ms: 0, minMs: 0, trials: 3, misses: 3, fpsMean: 0))
    }
}
