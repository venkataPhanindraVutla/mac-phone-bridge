import Foundation

/// Auto quality (Global Constraints): starts at High, is evaluated every 1 s, steps down one
/// preset after 5 s of a median lateness over 150 ms (or a decode backlog over 6 frames), and up
/// one after 60 s in which every evaluation had a median of at most 75 ms and a backlog of at most 6.
///
/// "For 5 s" and "60 s in which every evaluation" are runs of evaluations: each evaluation stands
/// for the second before it, so five late ones in a row step down, and one that isn't late (or has
/// no median: no frames) starts the run again. A missing median is not healthy either. Runs are of
/// evaluations about a second apart: one that comes more than 1.5 s after the last (evaluation was
/// paused: a delay measurement, a restart, the phone's availability off) starts them again.
///
/// The plan's test pair (5 late seconds step down, 4 don't) asks for a run of evaluations, and each
/// is a 5 s median, so the step down comes some 2.5 s after the median turns late plus the 5 s of
/// the run: about 7.5 s after a link turns late, not 5 s.
///
/// Back-off: a step up followed by a step down within 30 s doubles the wait before the next step
/// up from that preset (60 → 120 → 240 → 480 → 600 s). Ten minutes above the preset stepped up
/// from resets its wait; each step up keeps its own ten minutes.
/// Low never steps lower, High never higher. Choosing a preset by hand turns Auto off.
public struct QualityController: Sendable {
    public enum Decision: Equatable, Sendable { case keep, switchTo(QualityPreset) }

    /// How often `tick` is called.
    public static let interval: Duration = .seconds(1)
    static let lateMs = 150.0
    static let healthyMs = 75.0
    static let maxBacklog = 6
    static let stepDownAfter: Duration = .seconds(5)
    static let firstWait: Duration = .seconds(60)
    static let maxWait: Duration = .seconds(600)
    static let failedStepUpWithin: Duration = .seconds(30)
    static let backoffResetAfter: Duration = .seconds(600)
    /// An evaluation later than this after the last starts the runs again.
    static let maxGap: Duration = .milliseconds(1_500)

    public private(set) var preset: QualityPreset
    public var auto = true {
        didSet { if auto != oldValue { resetRuns() } }
    }

    private var lateSince: ContinuousClock.Instant?
    private var backlogSince: ContinuousClock.Instant?
    private var healthySince: ContinuousClock.Instant?
    /// The wait before stepping up from a preset, when it is not the first wait.
    private var waits: [QualityPreset: Duration] = [:]
    /// When each preset was last stepped up from, while it is still below the current preset and
    /// the step may still turn out to have failed or reset that preset's back-off.
    private var stepUps: [QualityPreset: ContinuousClock.Instant] = [:]
    private var lastTick: ContinuousClock.Instant?

    public init(start: QualityPreset = .high) {
        preset = start
    }

    /// Called every 1 s with the 5 s median lateness and the decode backlog.
    public mutating func tick(medianMs: Double?, backlog: Int, now: ContinuousClock.Instant) -> Decision {
        guard auto else { return .keep }
        if let lastTick, now - lastTick > Self.maxGap { resetRuns() }
        lastTick = now
        for (from, at) in stepUps where now - at >= Self.backoffResetAfter {
            waits[from] = nil
            stepUps[from] = nil
        }
        let late = medianMs.map { $0 > Self.lateMs } ?? false
        let backedUp = backlog > Self.maxBacklog
        let healthy = (medianMs.map { $0 <= Self.healthyMs } ?? false) && !backedUp
        lateSince = late ? (lateSince ?? now - Self.interval) : nil
        backlogSince = backedUp ? (backlogSince ?? now - Self.interval) : nil
        healthySince = healthy ? (healthySince ?? now - Self.interval) : nil

        if [lateSince, backlogSince].contains(where: { $0.map { now - $0 >= Self.stepDownAfter } ?? false }) {
            return stepDown(now: now)
        }
        if let since = healthySince, now - since >= wait(preset), let up = higher(preset) {
            stepUps[preset] = now
            preset = up
            resetRuns()
            return .switchTo(up)
        }
        return .keep
    }

    /// A preset picked by hand: Auto turns off.
    public mutating func choose(_ preset: QualityPreset) {
        self.preset = preset
        auto = false
        stepUps = [:]
        resetRuns()
    }

    /// The phone ended the session with LINK_SLOW: under Auto, the next start is one preset lower.
    public mutating func linkTooSlow(now: ContinuousClock.Instant) {
        guard auto else { return }
        _ = stepDown(now: now)
    }

    private mutating func stepDown(now: ContinuousClock.Instant) -> Decision {
        resetRuns()
        guard let down = lower(preset) else { return .keep }
        if let at = stepUps[down], now - at <= Self.failedStepUpWithin {
            waits[down] = min(wait(down) * 2, Self.maxWait)
        }
        // No longer above `down`: its step up is over, failed or not.
        stepUps[down] = nil
        preset = down
        return .switchTo(down)
    }

    private func wait(_ preset: QualityPreset) -> Duration { waits[preset] ?? Self.firstWait }

    private mutating func resetRuns() {
        lastTick = nil
        lateSince = nil
        backlogSince = nil
        healthySince = nil
    }

    private func higher(_ p: QualityPreset) -> QualityPreset? {
        guard let i = QualityPreset.all.firstIndex(of: p), i > 0 else { return nil }
        return QualityPreset.all[i - 1]
    }

    private func lower(_ p: QualityPreset) -> QualityPreset? {
        guard let i = QualityPreset.all.firstIndex(of: p), i + 1 < QualityPreset.all.count else { return nil }
        return QualityPreset.all[i + 1]
    }
}
