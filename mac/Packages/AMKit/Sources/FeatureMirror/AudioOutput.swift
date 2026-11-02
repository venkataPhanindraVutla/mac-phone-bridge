import AVFoundation
import Foundation
import os

/// What `AudioOutput` plays through: one engine with one player. Every call is made on
/// `AudioOutput`'s private serial queue, never under its lock and never from a notification handler.
protocol AudioPlayback: AnyObject, Sendable {
    /// Starts the engine and the player.
    func start() throws
    /// Schedules `buffer`; `completion` runs, on any thread, once the player has consumed it (or
    /// the player is stopped).
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void)
    /// Stops the player: what was scheduled is dropped and its completions run.
    func stopPlayer()
    /// After a device change (the engine stopped itself): starts the engine and the player again.
    func restart() throws
    /// Stops for good and stops watching for device changes.
    func shutdown()
}

/// Makes a playback; `onConfigurationChange` is called, on any thread, when the output device changes.
typealias MakeAudioPlayback = @Sendable (_ onConfigurationChange: @escaping @Sendable () -> Void) throws -> any AudioPlayback

/// Plays decoded phone audio with low latency: an `AVAudioEngine` with one `AVAudioPlayerNode`,
/// behind a `JitterPolicy`. Nonisolated: every closure handed to AVFoundation (the player's
/// completion handlers, the engine's configuration-change observer) is made here and touches only
/// this object's lock-guarded state, never the main actor.
///
/// Buffers wait in `pending` and go to the player only while it holds less than the target, so
/// audio queued beyond the target stays in `pending`, where the policy's drops take the oldest of
/// it. The queue the policy sees is both together, counted until the player has consumed it.
///
/// Threads: the decisions are made under `lock` by whoever calls (the session's read loop, the
/// player's completions, the main actor for `muted` and `stop()`). Everything that touches the
/// engine or the player (start, schedule, a device-change restart, shutdown) runs in order on
/// `queue`, so no caller ever waits for the engine, and nothing is scheduled while a restart
/// flushes the player. `stop()` and muting release the engine on `queue` too.
///
/// The engine starts at the first buffer that is played (never while muted), and only its output
/// is used: no microphone. Muting drops arriving and queued audio and releases the engine; the
/// link and the decoder keep running, and the next buffer after unmuting starts it again.
public final class AudioOutput: @unchecked Sendable {
    /// Frames per millisecond at 48 kHz.
    private static let framesPerMs = AudioDecoder.sampleRate / 1_000
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "mirror")

    /// What the output has done so far (internal: tests and the session's log line).
    struct Stats: Equatable {
        var drops = 0
        var droppedMs = 0.0
        var underruns = 0
        /// Buffers taken into the queue (none while muted or stopped).
        var accepted = 0
        /// Buffers handed to the player.
        var scheduled = 0
    }

    private let makePlayback: MakeAudioPlayback
    private let queue = DispatchQueue(label: "io.github.anmirror.mac.mirror-audio")
    private let lock = NSLock()
    // Guarded by `lock`.
    private var policy = JitterPolicy()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    /// Frames handed to the player and not yet consumed.
    private var scheduledFrames = 0
    /// Bumped whenever what the player holds is thrown away (a restart, mute, stop), so
    /// completions and queued schedules from before are ignored.
    private var generation = 0
    private var playback: (any AudioPlayback)?
    /// A start is running on `queue`.
    private var starting = false
    /// Device-change restarts queued or running; nothing is scheduled meanwhile.
    private var restarts = 0
    private var isMuted = false
    private var stopped = false
    /// The engine would not start (no output device): everything is dropped.
    private var broken = false
    private var counts = Stats()

    public convenience init() {
        self.init(makePlayback: { EnginePlayback(onConfigurationChange: $0) })
    }

    init(makePlayback: @escaping MakeAudioPlayback) {
        self.makePlayback = makePlayback
    }

    deinit {
        // `stop()` normally ran already; otherwise release the engine off this thread.
        if let playback { queue.async { playback.shutdown() } }
    }

    /// Queues a decoded buffer (`AudioDecoder.outputFormat`). From any thread; never waits for the engine.
    public func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped, !isMuted, !broken, buffer.frameLength > 0 else { return }
            counts.accepted += 1
            pending.append(buffer)
            pendingFrames += Int(buffer.frameLength)
            pumpLocked()
        }
    }

    /// Muted, arriving and queued audio is dropped and the engine is released.
    public var muted: Bool {
        get { lock.withLock { isMuted } }
        set {
            let released: (any AudioPlayback)? = lock.withLock {
                guard newValue != isMuted else { return nil }
                isMuted = newValue
                guard newValue else { return nil }
                return discardLocked()
            }
            if let released { queue.async { released.shutdown() } }
        }
    }

    /// Stops playback for good and releases the engine (on the private queue; this returns at once).
    /// Later buffers are ignored.
    public func stop() {
        let released: (any AudioPlayback)? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return discardLocked()
        }
        if let released { queue.async { released.shutdown() } }
    }

    /// The engine is running or starting (internal, for tests).
    var started: Bool { lock.withLock { playback != nil || starting } }

    var stats: Stats { lock.withLock { counts } }

    /// Waits until everything queued for the engine has run (internal, for tests).
    func waitForEngineQueue() { queue.sync {} }

    // MARK: decisions (called with the lock held)

    private func pumpLocked() {
        let queuedMs = Double(pendingFrames + scheduledFrames) / Self.framesPerMs
        switch policy.next(queuedMs: queuedMs) {
        case .wait:
            if queuedMs <= 0, playback != nil { counts.underruns += 1 }
            return
        case let .dropOldest(ms):
            dropOldestLocked(ms)
        case .play:
            break
        }
        guard !broken, !starting, restarts == 0 else { return }
        guard let playback else {
            starting = true
            queue.async { [weak self] in self?.startOnQueue() }
            return
        }
        let generation = generation
        while let next = pending.first, Double(scheduledFrames) / Self.framesPerMs < policy.targetMs {
            pending.removeFirst()
            let frames = Int(next.frameLength)
            pendingFrames -= frames
            scheduledFrames += frames
            counts.scheduled += 1
            let item = Scheduled(buffer: next, frames: frames, generation: generation)
            queue.async { [weak self] in self?.scheduleOnQueue(item, on: playback) }
        }
    }

    /// Drops whole buffers from the oldest pending ones, at most `ms` of them.
    private func dropOldestLocked(_ ms: Double) {
        var dropped = 0.0
        while let first = pending.first {
            let length = Double(first.frameLength) / Self.framesPerMs
            guard dropped + length <= ms else { break }
            pending.removeFirst()
            pendingFrames -= Int(first.frameLength)
            dropped += length
        }
        guard dropped > 0 else { return }
        counts.drops += 1
        counts.droppedMs += dropped
    }

    /// Forgets everything queued and the engine; returns it for the caller to shut down on `queue`.
    private func discardLocked() -> (any AudioPlayback)? {
        generation += 1
        pending = []
        pendingFrames = 0
        scheduledFrames = 0
        policy = JitterPolicy()
        restarts = 0
        defer { playback = nil }
        return playback
    }

    // MARK: engine work (on `queue`)

    private func startOnQueue() {
        guard lock.withLock({ !stopped && !isMuted }) else {
            lock.withLock { starting = false }
            return
        }
        var made: (any AudioPlayback)?
        if let playback = try? makePlayback(Self.configurationHandler(for: self)) {
            do {
                try playback.start()
                made = playback
            } catch {
                playback.shutdown()
            }
        }
        guard let made else {
            lock.withLock {
                starting = false
                broken = true
                pending = []
                pendingFrames = 0
            }
            Self.log.error("audio output did not start")
            return
        }
        let kept: Bool = lock.withLock {
            starting = false
            // Stopped or muted while starting: never published.
            guard !stopped, !isMuted else { return false }
            playback = made
            pumpLocked()
            return true
        }
        if !kept { made.shutdown() }
    }

    private func scheduleOnQueue(_ item: Scheduled, on playback: any AudioPlayback) {
        // Skipped when the player was flushed or replaced since: its frames were forgotten then.
        guard lock.withLock({ !stopped && restarts == 0 && item.generation == generation && self.playback === playback })
        else { return }
        playback.schedule(item.buffer, completion: Self.completion(for: self, frames: item.frames, generation: item.generation))
    }

    /// The output device changed and the engine stopped itself. Only marks it here (on any thread,
    /// the notification's own); the restart runs on `queue`.
    fileprivate func configurationChanged() {
        let playback: (any AudioPlayback)? = lock.withLock {
            guard !stopped, let current = self.playback else { return nil }
            restarts += 1
            generation += 1
            scheduledFrames = 0
            // What was scheduled is gone; like at the start, play again once the target is queued.
            policy = JitterPolicy()
            return current
        }
        guard let playback else { return }
        queue.async { [weak self] in self?.restartOnQueue(playback) }
    }

    private func restartOnQueue(_ playback: any AudioPlayback) {
        let current = { [self] in lock.withLock { !stopped && self.playback === playback } }
        guard current() else { return } // stopped or muted: its shutdown is queued after this
        playback.stopPlayer()
        guard current() else { return }
        do {
            try playback.restart()
        } catch {
            let released: (any AudioPlayback)? = lock.withLock {
                guard self.playback === playback else { return nil }
                broken = true
                return discardLocked()
            }
            released?.shutdown()
            Self.log.error("audio output did not restart")
            return
        }
        lock.withLock {
            // Stopped while restarting: the shutdown queued by stop() runs next.
            guard !stopped, self.playback === playback else { return }
            restarts = max(0, restarts - 1)
            if restarts == 0 { pumpLocked() }
        }
    }

    fileprivate func consumed(_ frames: Int, generation: Int) {
        lock.withLock {
            guard !stopped, generation == self.generation else { return }
            scheduledFrames = max(0, scheduledFrames - frames)
            pumpLocked()
        }
    }

    // MARK: closures for AVFoundation, built nonisolated

    private static func completion(for output: AudioOutput, frames: Int, generation: Int) -> @Sendable () -> Void {
        { [weak output] in output?.consumed(frames, generation: generation) }
    }

    private static func configurationHandler(for output: AudioOutput) -> @Sendable () -> Void {
        { [weak output] in output?.configurationChanged() }
    }
}

/// A buffer on its way to the player. `AVAudioPCMBuffer` isn't Sendable; this one is handed over
/// once and never touched again by the sender.
private struct Scheduled: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let frames: Int
    let generation: Int
}

/// The real engine: `AVAudioEngine` with one `AVAudioPlayerNode` into the main mixer at 48 kHz
/// stereo. Its input node is never touched (no microphone).
private final class EnginePlayback: AudioPlayback, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var observer: NSObjectProtocol?

    init(onConfigurationChange: @escaping @Sendable () -> Void) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AudioDecoder.outputFormat)
        engine.prepare()
        observer = Self.observe(engine, onConfigurationChange)
    }

    func start() throws {
        try engine.start()
        player.play()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { _ in completion() }
    }

    func stopPlayer() {
        player.stop()
    }

    func restart() throws {
        try engine.start()
        player.play()
    }

    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player.stop()
        engine.stop()
    }

    /// The handler only forwards: `AudioOutput` marks the change and restarts on its own queue.
    private static func observe(_ engine: AVAudioEngine, _ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            handler()
        }
    }
}
