import Foundation

/// What "Measure Delay…" found: the round trips (Mac tap → phone draws white → capture → encode →
/// relay → Wi-Fi → Mac decode) of the trials that got an answer, how many got none, and the frame
/// rate counted afterwards (0 when not counted).
public struct DelayResult: Equatable, Sendable {
    public let medianMs, p95Ms, minMs: Double
    public let trials, misses: Int
    public let fpsMean: Double

    public init(medianMs: Double, p95Ms: Double, minMs: Double, trials: Int, misses: Int, fpsMean: Double) {
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.minMs = minMs
        self.trials = trials
        self.misses = misses
        self.fpsMean = fpsMean
    }

    /// The same result with the frame rate filled in.
    public func with(fpsMean: Double) -> DelayResult {
        DelayResult(medianMs: medianMs, p95Ms: p95Ms, minMs: minMs, trials: trials, misses: misses, fpsMean: fpsMean)
    }
}

/// The delay trials over a running session showing the phone's DELAY test screen (black, white
/// while a finger is down). Each trial waits for a black centre, puts the finger down at the
/// centre (`tap(true)`), waits for a white centre in a picture decoded after that, lifts the
/// finger (`tap(false)`) and pauses. A trial with no black or no white within `timeout` is a miss.
/// The pictures' centre luma comes from `luma`, stamped when each was decoded; when that stream
/// ends (the session ended) the run stops with the trials it ran.
@MainActor
public final class DelayProbe {
    public static let blackBelow = 50.0
    public static let whiteAbove = 200.0

    private let tap: (Bool) -> Void
    private let luma: () async -> AsyncStream<(Double, ContinuousClock.Instant)>
    private let trials: Int
    private let timeout: Duration
    private let pause: Duration
    /// How long the first black may take (the test screen opening on the phone).
    var firstBlack: Duration = .seconds(5)

    private typealias Sample = (luma: Double, at: ContinuousClock.Instant)
    private var pending: [Sample] = []
    private var latest: Sample?
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    public init(tap: @escaping (Bool) -> Void, luma: @escaping () async -> AsyncStream<(Double, ContinuousClock.Instant)>,
                trials: Int = 50, timeout: Duration = .seconds(3), pause: Duration = .milliseconds(500)) {
        self.tap = tap
        self.luma = luma
        self.trials = trials
        self.timeout = timeout
        self.pause = pause
    }

    public func run() async -> DelayResult {
        let stream = await luma()
        let pump = Task { [weak self] in
            for await sample in stream { self?.deliver(sample) }
            self?.finish()
        }
        defer { pump.cancel() }

        var delays: [Double] = []
        var ran = 0
        // The test screen comes up black; without it no tap can be timed.
        guard await waitForBlack(within: firstBlack) else {
            return Self.summary([], trials: ended ? 0 : trials, misses: ended ? 0 : trials)
        }
        for trial in 0..<trials {
            if trial > 0, pause > .zero { try? await Task.sleep(for: pause) }
            if ended { break }
            ran += 1
            guard await waitForBlack(within: timeout) else { continue }
            pending.removeAll()
            let down = ContinuousClock.now
            tap(true)
            let white = await next(within: timeout) { $0.at >= down && $0.luma > Self.whiteAbove }
            tap(false)
            if let white { delays.append(LatenessMeter.ms(white.at - down)) }
        }
        return Self.summary(delays, trials: ran, misses: ran - delays.count)
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

    // MARK: samples

    private func deliver(_ sample: (Double, ContinuousClock.Instant)) {
        let s: Sample = (sample.0, sample.1)
        pending.append(s)
        latest = s
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

    /// The centre is black now (the last picture), or turns black within `within`.
    private func waitForBlack(within: Duration) async -> Bool {
        if let latest, latest.luma < Self.blackBelow {
            pending.removeAll()
            return true
        }
        return await next(within: within) { $0.luma < Self.blackBelow } != nil
    }

    /// The first picture from now on that matches, or nil after `within` or at the end of the stream.
    private func next(within: Duration, _ match: (Sample) -> Bool) async -> Sample? {
        let deadline = ContinuousClock.now + within
        while true {
            while !pending.isEmpty {
                let s = pending.removeFirst()
                if match(s) { return s }
            }
            if ended || ContinuousClock.now >= deadline { return nil }
            let timer = Task { [weak self] in
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    self?.wake()
                } catch {}
            }
            await withCheckedContinuation { waiter = $0 }
            timer.cancel()
        }
    }
}
