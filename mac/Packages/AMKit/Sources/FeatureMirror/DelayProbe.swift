import Foundation

/// What "Measure Delay…" found: the round trips (Mac tap → phone draws white → capture → encode →
/// relay → Wi-Fi → Mac decode) of the taps that got an answer, how many taps were sent (`trials`)
/// and how many got none (`misses`), and the frame rate counted afterwards (0 when not counted).
/// `testScreenOpened` is false when the phone's test screen never showed: then no tap was sent.
public struct DelayResult: Equatable, Sendable {
    public let medianMs, p95Ms, minMs: Double
    public let trials, misses: Int
    public let fpsMean: Double
    public let testScreenOpened: Bool

    public init(medianMs: Double, p95Ms: Double, minMs: Double, trials: Int, misses: Int, fpsMean: Double,
                testScreenOpened: Bool = true) {
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.minMs = minMs
        self.trials = trials
        self.misses = misses
        self.fpsMean = fpsMean
        self.testScreenOpened = testScreenOpened
    }

    /// The same result with the frame rate filled in.
    public func with(fpsMean: Double) -> DelayResult {
        DelayResult(medianMs: medianMs, p95Ms: p95Ms, minMs: minMs, trials: trials, misses: misses, fpsMean: fpsMean,
                    testScreenOpened: testScreenOpened)
    }
}

/// One decoded picture as the delay trials see it: its centre luma, whether it shows the test
/// screen's corner marker (`LumaProbe.testScreenMarker`), and when it was decoded.
public struct DelayFrame: Equatable, Sendable {
    public let centerLuma: Double
    public let marker: Bool
    public let at: ContinuousClock.Instant

    public init(centerLuma: Double, marker: Bool, at: ContinuousClock.Instant) {
        self.centerLuma = centerLuma
        self.marker = marker
        self.at = at
    }
}

/// The time `DelayProbe` reads and waits on: the continuous clock the frames are stamped with (a
/// test hook; a test's frames are stamped on its own clock).
struct DelayClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let system = DelayClock(now: { ContinuousClock.now },
                                   sleep: { try await Task.sleep(until: $0, clock: .continuous) })
}

/// The delay trials over a running session that was just asked for the phone's DELAY test screen
/// (black with a white square in each corner; the centre white while a finger is down).
///
/// Nothing is tapped until the test screen is up (R56): the marker on `markerFrames` pictures in a
/// row, decoded after `run()` began, and at least `settle` since then. A user's own screen, however
/// dark its centre, never shows the marker, so it is never tapped. Without the marker within
/// `markerTimeout` the run ends with no tap (`testScreenOpened` false).
///
/// Then each trial waits for the idle test screen (marker and black centre), puts the finger down
/// at the centre (`tap(true)`), waits for a white centre in a picture decoded after that, lifts the
/// finger (`tap(false)`) and pauses. A tap with no white within `timeout` is a miss; a trial whose
/// idle screen doesn't come back within `timeout` sends no tap and is not counted. When the frames
/// end (the session ended) the run stops with the taps it sent.
@MainActor
public final class DelayProbe {
    public static let blackBelow = 50.0
    public static let whiteAbove = 200.0

    private let tap: (Bool) -> Void
    private let frames: () async -> AsyncStream<DelayFrame>
    private let trials: Int
    private let timeout: Duration
    private let pause: Duration
    /// How long the test screen may take to show (R56: 5 s).
    var markerTimeout: Duration = .seconds(5)
    /// The least time from DELAY to the first tap (R56: 500 ms). `run()` starts right after DELAY
    /// is sent, so this is measured from there.
    var settle: Duration = .milliseconds(500)
    /// Pictures in a row with the marker before the test screen counts as up (R56: 3).
    var markerFrames = 3
    /// What deadlines, the settle time and pauses are measured on (a test hook).
    var clock = DelayClock.system

    private var pending: [DelayFrame] = []
    private var latest: DelayFrame?
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    public init(tap: @escaping (Bool) -> Void, frames: @escaping () async -> AsyncStream<DelayFrame>,
                trials: Int = 50, timeout: Duration = .seconds(3), pause: Duration = .milliseconds(500)) {
        self.tap = tap
        self.frames = frames
        self.trials = trials
        self.timeout = timeout
        self.pause = pause
    }

    public func run() async -> DelayResult {
        let began = clock.now()
        let stream = await frames()
        let pump = Task { [weak self] in
            for await frame in stream { self?.deliver(frame) }
            self?.finish()
        }
        defer { pump.cancel() }

        guard await testScreenUp(since: began) else {
            return DelayResult(medianMs: 0, p95Ms: 0, minMs: 0, trials: 0, misses: 0, fpsMean: 0, testScreenOpened: false)
        }
        var delays: [Double] = []
        var taps = 0
        // Only pictures decoded after the finger was last lifted show whether it is idle again.
        var lifted = began
        for trial in 0..<trials {
            if trial > 0, pause > .zero { try? await clock.sleep(clock.now() + pause) }
            if ended { break }
            guard await idleTestScreen(since: lifted, within: timeout) else { continue }
            pending.removeAll()
            let down = clock.now()
            tap(true)
            taps += 1
            let white = await next(until: down + timeout) { $0.at >= down && $0.centerLuma > Self.whiteAbove }
            tap(false)
            lifted = clock.now()
            if let white { delays.append(LatenessMeter.ms(white.at - down)) }
        }
        return Self.summary(delays, trials: taps, misses: taps - delays.count)
    }

    /// Median (the mean of the middle two for an even count), 95th percentile (nearest rank) and
    /// minimum of `delays` in ms; all 0 when there are none.
    static func summary(_ delays: [Double], trials: Int, misses: Int) -> DelayResult {
        let sorted = delays.sorted()
        guard !sorted.isEmpty else { return DelayResult(medianMs: 0, p95Ms: 0, minMs: 0, trials: trials, misses: misses, fpsMean: 0) }
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return DelayResult(medianMs: median, p95Ms: sorted[max(rank, 1) - 1], minMs: sorted[0],
                           trials: trials, misses: misses, fpsMean: 0)
    }

    // MARK: frames

    private func deliver(_ frame: DelayFrame) {
        pending.append(frame)
        latest = frame
        wake()
    }

    private func finish() {
        ended = true
        wake()
    }

    private func wake() {
        let w = waiter
        waiter = nil
        w?.resume()
    }

    private static func idle(_ f: DelayFrame) -> Bool { f.marker && f.centerLuma < blackBelow }

    /// The marker on `markerFrames` pictures in a row decoded since `since`, and `settle` passed,
    /// within `markerTimeout`.
    private func testScreenUp(since: ContinuousClock.Instant) async -> Bool {
        let deadline = since + markerTimeout
        let settled = since + settle
        var run = 0
        while true {
            if run >= markerFrames, clock.now() >= settled { return true }
            if ended || clock.now() >= deadline { return false }
            // Enough in a row but too soon: wait for the settle time, or a picture that breaks the run.
            let until = run >= markerFrames ? min(settled, deadline) : deadline
            guard let frame = await next(until: until, { _ in true }) else { continue }
            run = frame.marker && frame.at >= since ? run + 1 : 0
        }
    }

    /// The idle test screen is up now (the last picture, if decoded since `since`), or comes back
    /// within `within`.
    private func idleTestScreen(since: ContinuousClock.Instant, within: Duration) async -> Bool {
        if let latest, latest.at >= since, Self.idle(latest) {
            pending.removeAll()
            return true
        }
        return await next(until: clock.now() + within) { $0.at >= since && Self.idle($0) } != nil
    }

    /// The first picture from now on that matches, or nil at `deadline` or the end of the frames.
    private func next(until deadline: ContinuousClock.Instant, _ match: (DelayFrame) -> Bool) async -> DelayFrame? {
        while true {
            while !pending.isEmpty {
                let f = pending.removeFirst()
                if match(f) { return f }
            }
            if ended || clock.now() >= deadline { return nil }
            let sleep = clock.sleep
            let timer = Task { [weak self] in
                do {
                    try await sleep(deadline)
                    self?.wake()
                } catch {}
            }
            await withCheckedContinuation { waiter = $0 }
            timer.cancel()
        }
    }
}
