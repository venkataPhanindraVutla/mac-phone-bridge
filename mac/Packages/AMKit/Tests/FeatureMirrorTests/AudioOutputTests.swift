import AVFoundation
import Foundation
import Testing
@testable import FeatureMirror

/// A playback that records what `AudioOutput` asks of it; completions fire when the test says.
/// `stopPlayer()` and `restart()` can be held at a gate to catch the output mid-reconfigure.
final class FakePlayback: AudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable () -> Void] = []
    private var counters = (starts: 0, schedules: 0, playerStops: 0, restarts: 0, shutdowns: 0)
    /// Set by the factory: what a device-change notification would call.
    var onConfigurationChange: (@Sendable () -> Void)?
    var stopPlayerGate: DispatchSemaphore?
    var restartGate: DispatchSemaphore?
    /// Signalled when a gated call has been entered.
    let entered = DispatchSemaphore(value: 0)
    var failStart = false

    var starts: Int { lock.withLock { counters.starts } }
    var schedules: Int { lock.withLock { counters.schedules } }
    var playerStops: Int { lock.withLock { counters.playerStops } }
    var restarts: Int { lock.withLock { counters.restarts } }
    var shutdowns: Int { lock.withLock { counters.shutdowns } }
    var waiting: Int { lock.withLock { completions.count } }

    func start() throws {
        lock.withLock { counters.starts += 1 }
        if failStart { throw CancellationError() }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        lock.withLock {
            counters.schedules += 1
            completions.append(completion)
        }
    }

    /// Like the real player: what was scheduled is dropped and its completions run.
    func stopPlayer() {
        if let gate = stopPlayerGate {
            entered.signal()
            gate.wait()
        }
        let flushed: [@Sendable () -> Void] = lock.withLock {
            counters.playerStops += 1
            defer { completions = [] }
            return completions
        }
        for c in flushed { c() }
    }

    func restart() throws {
        if let gate = restartGate {
            entered.signal()
            gate.wait()
        }
        lock.withLock { counters.restarts += 1 }
    }

    func shutdown() {
        let flushed: [@Sendable () -> Void] = lock.withLock {
            counters.shutdowns += 1
            defer { completions = [] }
            return completions
        }
        for c in flushed { c() }
    }

    /// The player consumed the oldest `n` scheduled buffers.
    func consume(_ n: Int) {
        let done: [@Sendable () -> Void] = lock.withLock {
            let n = min(n, completions.count)
            defer { completions.removeFirst(n) }
            return Array(completions.prefix(n))
        }
        for c in done { c() }
    }
}

/// An output over fakes; `made` counts the playbacks it asked for.
final class FakeOutputRig: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakePlayback] = []
    var prepare: (FakePlayback) -> Void = { _ in }
    private(set) lazy var output = AudioOutput(makePlayback: { [self] change in
        let fake = FakePlayback()
        fake.onConfigurationChange = change
        prepare(fake)
        lock.withLock { all.append(fake) }
        return fake
    })

    var made: Int { lock.withLock { all.count } }
    var last: FakePlayback? { lock.withLock { all.last } }

    /// Lets the engine queue run what is queued, including the schedules queued from there.
    func settle() {
        output.waitForEngineQueue()
        output.waitForEngineQueue()
    }

    /// Enqueues `count` buffers of 20 ms.
    func feed(_ count: Int) {
        for _ in 0..<count { output.enqueue(silence(ms: 20)) }
    }
}

/// `ms` of silence in the output format.
func silence(ms: Int) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(ms * 48)
    let buffer = AVAudioPCMBuffer(pcmFormat: AudioDecoder.outputFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
}

@Suite struct AudioOutputTests {
    @Test func startsAtTheTargetAndSchedulesOnlyUpToIt() throws {
        let rig = FakeOutputRig()
        rig.feed(2) // 40 ms: still priming
        rig.settle()
        #expect(rig.made == 0)
        rig.feed(1) // 60 ms
        rig.settle()
        let fake = try #require(rig.last)
        #expect(fake.starts == 1)
        #expect(fake.schedules == 3)
        // Beyond the target, audio waits in the output, not the player.
        rig.feed(2)
        rig.settle()
        #expect(fake.schedules == 3)
        // As the player consumes, the next goes in.
        fake.consume(1)
        rig.settle()
        #expect(fake.schedules == 4)
        #expect(rig.output.stats.accepted == 5)
        rig.output.stop()
    }

    /// Past 150 ms the oldest *pending* audio is dropped back to the target; what the player
    /// already holds plays.
    @Test func dropsComeFromThePendingAudio() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let fake = try #require(rig.last)
        rig.feed(5) // 160 ms queued at the fifth: drop 100 ms
        rig.settle()
        let stats = rig.output.stats
        #expect(stats.drops == 1)
        #expect(stats.droppedMs == 100)
        #expect(fake.schedules == 3)
        rig.output.stop()
    }

    @Test func underrunsAreCountedWhilePlayingOnly() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let fake = try #require(rig.last)
        fake.consume(3)
        #expect(rig.output.stats.underruns == 1)
        // Refills at 40 ms after the underrun.
        rig.feed(2)
        rig.settle()
        #expect(fake.schedules == 5)
        rig.output.muted = true
        fake.consume(2) // stale: ignored
        #expect(rig.output.stats.underruns == 1)
        rig.output.stop()
    }

    /// Muted or stopped, nothing is taken and no engine is made: nothing can reach the speakers.
    @Test func mutedOrStoppedOutputTakesNothing() {
        let rig = FakeOutputRig()
        rig.output.muted = true
        rig.feed(10)
        rig.settle()
        #expect(rig.made == 0)
        #expect(rig.output.stats.accepted == 0)
        rig.output.stop()
        rig.output.muted = false
        rig.feed(10)
        rig.settle()
        #expect(rig.made == 0)
        #expect(rig.output.stats.accepted == 0)
        #expect(!rig.output.started)
    }

    @Test func muteReleasesTheEngineAndUnmuteStartsAgain() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let first = try #require(rig.last)
        rig.output.muted = true
        rig.settle()
        #expect(first.shutdowns == 1)
        #expect(!rig.output.started)
        rig.output.muted = false
        rig.feed(3)
        rig.settle()
        #expect(rig.made == 2)
        #expect(rig.last?.schedules == 3)
        rig.output.stop()
        rig.settle()
        #expect(rig.last?.shutdowns == 1)
    }

    /// A device change only marks the output; the restart runs on the engine queue, where a close
    /// that came meanwhile wins: no restart, the engine shut down there.
    @Test func closeDuringReconfigureDoesNotRestart() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let fake = try #require(rig.last)
        let gate = DispatchSemaphore(value: 0)
        fake.stopPlayerGate = gate
        fake.onConfigurationChange?() // returns at once: no engine work on the notifying thread
        fake.entered.wait()           // the restart is flushing the player
        rig.output.stop()
        gate.signal()
        rig.settle()
        #expect(fake.restarts == 0)
        #expect(fake.shutdowns == 1)
        #expect(!rig.output.started)
    }

    /// Closed while the engine restarts: the restarted engine is not used again and is shut down.
    @Test func closeWhileRestartingShutsTheEngineDown() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let fake = try #require(rig.last)
        let gate = DispatchSemaphore(value: 0)
        fake.restartGate = gate
        fake.onConfigurationChange?()
        fake.entered.wait()
        rig.output.stop()
        gate.signal()
        rig.settle()
        #expect(fake.restarts == 1)
        #expect(fake.shutdowns == 1)
        #expect(fake.schedules == 3)
        #expect(!rig.output.started)
    }

    /// Audio arriving while a restart flushes the player is not scheduled until the restart is done.
    @Test func schedulingWaitsForTheReconfigure() throws {
        let rig = FakeOutputRig()
        rig.feed(3)
        rig.settle()
        let fake = try #require(rig.last)
        let gate = DispatchSemaphore(value: 0)
        fake.stopPlayerGate = gate
        fake.onConfigurationChange?()
        fake.entered.wait()
        rig.feed(4)
        #expect(fake.schedules == 3)
        gate.signal()
        rig.settle()
        #expect(fake.restarts == 1)
        #expect(fake.schedules == 6) // up to the target again, after the restart
        // The flushed buffers' completions were ignored: the queue is the 80 ms fed since.
        fake.consume(3)
        rig.settle()
        #expect(fake.schedules == 7)
        rig.output.stop()
    }

    @Test func engineThatWontStartDropsEverything() {
        let rig = FakeOutputRig()
        rig.prepare = { $0.failStart = true }
        rig.feed(3)
        rig.settle()
        #expect(rig.made == 1)
        #expect(rig.last?.shutdowns == 1)
        #expect(!rig.output.started)
        rig.feed(10)
        rig.settle()
        #expect(rig.made == 1)
        rig.output.stop()
    }
}
