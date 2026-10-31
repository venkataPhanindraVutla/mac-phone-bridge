import AVFoundation
import Foundation
import os

/// Plays decoded phone audio with low latency: an `AVAudioEngine` with one `AVAudioPlayerNode`,
/// behind a `JitterPolicy`. Nonisolated: every closure handed to AVFoundation (the player's
/// completion handlers, the engine's configuration-change observer) is made here and touches only
/// this object's lock-guarded state, never the main actor.
///
/// Buffers wait in `pending` and go to the player node only while it holds less than the target,
/// so audio queued beyond the target stays in `pending`, where the policy's drops take the oldest
/// of it. The queue the policy sees is both together, counted until the player has consumed it.
///
/// The engine starts at the first buffer that is played (never while muted), and only its output
/// is used: no microphone. Muted, buffers are dropped as they arrive and the player is silenced;
/// the link and the decoder keep running.
public final class AudioOutput: @unchecked Sendable {
    /// Frames per millisecond at 48 kHz.
    private static let framesPerMs = AudioDecoder.sampleRate / 1_000
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "mirror")

    private let lock = NSLock()
    // Guarded by `lock`.
    private var policy = JitterPolicy()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0
    /// Frames scheduled on the player and not yet consumed.
    private var scheduledFrames = 0
    /// Bumped when the player is stopped, so completions of buffers scheduled before are ignored.
    private var generation = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var isMuted = false
    private var stopped = false
    /// The engine would not start (no output device): everything is dropped.
    private var broken = false
    private var drops = 0
    private var droppedMs = 0.0
    private var underruns = 0

    public init() {}

    /// Queues a decoded buffer (`AudioDecoder.outputFormat`). From any thread.
    public func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped, !isMuted, !broken, buffer.frameLength > 0 else { return }
            pending.append(buffer)
            pendingFrames += Int(buffer.frameLength)
            pumpLocked()
        }
    }

    /// Muted, arriving audio is dropped and the player is silent at once.
    public var muted: Bool {
        get { lock.withLock { isMuted } }
        set {
            let player: AVAudioPlayerNode? = lock.withLock {
                isMuted = newValue
                if newValue {
                    pending = []
                    pendingFrames = 0
                }
                return self.player
            }
            player?.volume = newValue ? 0 : 1
        }
    }

    /// Stops playback for good and releases the engine. Later buffers are ignored.
    public func stop() {
        let (engine, player, observer): (AVAudioEngine?, AVAudioPlayerNode?, NSObjectProtocol?) = lock.withLock {
            guard !stopped else { return (nil, nil, nil) }
            stopped = true
            generation += 1
            pending = []
            pendingFrames = 0
            scheduledFrames = 0
            defer {
                self.engine = nil
                self.player = nil
                self.observer = nil
            }
            return (self.engine, self.player, self.observer)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // Outside the lock: stopping the player calls the completion handlers.
        player?.stop()
        engine?.stop()
    }

    /// The engine has been started (internal, for tests).
    var started: Bool { lock.withLock { engine != nil } }

    /// How often the jitter policy dropped audio, how much, and how many underruns there were.
    var stats: (drops: Int, droppedMs: Double, underruns: Int) {
        lock.withLock { (drops, droppedMs, underruns) }
    }

    // MARK: private (called with the lock held)

    private func pumpLocked() {
        let queuedMs = Double(pendingFrames + scheduledFrames) / Self.framesPerMs
        switch policy.next(queuedMs: queuedMs) {
        case .wait:
            if queuedMs <= 0, engine != nil, !isMuted { underruns += 1 }
            return
        case let .dropOldest(ms):
            dropOldestLocked(ms)
        case .play:
            break
        }
        guard startLocked(), let player else { return }
        while let next = pending.first, Double(scheduledFrames) / Self.framesPerMs < policy.targetMs {
            pending.removeFirst()
            let frames = Int(next.frameLength)
            pendingFrames -= frames
            scheduledFrames += frames
            player.scheduleBuffer(next, completionCallbackType: .dataConsumed,
                                  completionHandler: Self.completion(for: self, frames: frames, generation: generation))
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
        drops += 1
        droppedMs += dropped
    }

    /// Starts the engine the first time; whether it is running.
    private func startLocked() -> Bool {
        if engine != nil { return true }
        guard !broken else { return false }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AudioDecoder.outputFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            broken = true
            pending = []
            pendingFrames = 0
            Self.log.error("audio output did not start")
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        observer = Self.observeConfiguration(of: engine, output: self)
        return true
    }

    /// The output device changed: the engine stopped itself. Starts it again and waits for the
    /// refill like after an underrun; what was scheduled is gone.
    fileprivate func configurationChanged() {
        let (engine, player): (AVAudioEngine?, AVAudioPlayerNode?) = lock.withLock {
            guard !stopped else { return (nil, nil) }
            generation += 1
            scheduledFrames = 0
            policy = JitterPolicy()
            return (self.engine, self.player)
        }
        guard let engine, let player else { return }
        player.stop()
        do {
            try engine.start()
            player.play()
        } catch {
            lock.withLock { broken = true }
            Self.log.error("audio output did not restart")
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

    private static func completion(for output: AudioOutput, frames: Int, generation: Int)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak output] _ in output?.consumed(frames, generation: generation) }
    }

    private static func observeConfiguration(of engine: AVAudioEngine, output: AudioOutput) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
            [weak output] _ in output?.configurationChanged()
        }
    }
}
