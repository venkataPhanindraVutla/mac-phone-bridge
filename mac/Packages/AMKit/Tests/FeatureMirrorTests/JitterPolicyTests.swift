import Foundation
import Testing
@testable import FeatureMirror

@Suite struct JitterPolicyTests {
    /// 20 ms packets every 20 ms with ±10 ms of network jitter, played in real time: playing starts
    /// with the 60 ms target queued, and from then on the queue saws from about the target down by
    /// one packet (20 ms), shifted by up to the jitter (10 ms) of the packets that primed it. So the
    /// mean stays between target − packet − jitter and the target, every sample at most target +
    /// packet + jitter, with no drops and no underruns.
    @Test func steadyStateHoldsAboutTarget() {
        var policy = JitterPolicy()
        var rng = SplitMix(seed: 7)
        // Arrival times (ms) of 500 packets, 10 s of audio.
        let arrivals = (0..<500).map { Double($0) * 20 + Double(rng.next() % 21) - 10 }.map { max(0, $0) }.sorted()
        var queued = 0.0
        var next = 0
        var playing = false
        var samples: [Double] = []
        var drops = 0, underruns = 0
        for ms in 0..<10_000 {
            let now = Double(ms)
            while next < arrivals.count, arrivals[next] <= now {
                queued += 20
                next += 1
            }
            switch policy.next(queuedMs: queued) {
            case .play:
                playing = true
            case let .dropOldest(amount):
                drops += 1
                queued -= amount
            case .wait:
                if playing { underruns += 1 }
                playing = false
            }
            if playing {
                queued = max(0, queued - 1)
                if ms >= 1_000 { samples.append(queued) }
            }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        #expect(drops == 0)
        #expect(underruns == 0)
        #expect((30...60).contains(mean), "mean queue \(mean) ms")
        #expect(samples.min()! > 0 && samples.max()! <= 90, "queue \(samples.min()!)...\(samples.max()!) ms")
    }

    /// The phone's clock 1% fast for a minute: the queue grows until it passes 150 ms, then the
    /// oldest audio is dropped back to the target; it never runs dry.
    @Test func clockDriftIsDroppedBackToTarget() {
        var policy = JitterPolicy()
        var queued = 0.0, nextArrival = 0.0
        var playing = false
        var drops: [Double] = []
        var underruns = 0
        var peak = 0.0
        for ms in 0..<60_000 {
            while nextArrival <= Double(ms) {
                queued += 20
                nextArrival += 19.8
            }
            switch policy.next(queuedMs: queued) {
            case .play:
                playing = true
            case let .dropOldest(amount):
                drops.append(amount)
                queued -= amount
            case .wait:
                if playing { underruns += 1 }
                playing = false
            }
            peak = max(peak, queued)
            if playing { queued = max(0, queued - 1) }
        }
        #expect(drops.count >= 3)
        #expect(drops.allSatisfy { $0 > 90 && $0 <= 110 }, "\(drops)")
        #expect(peak <= 150 + 20)
        #expect(underruns == 0)
    }

    @Test func startsOnceTheTargetIsQueued() {
        var policy = JitterPolicy()
        #expect(policy.next(queuedMs: 0) == .wait)
        #expect(policy.next(queuedMs: 40) == .wait)
        #expect(policy.next(queuedMs: 59.9) == .wait)
        #expect(policy.next(queuedMs: 60) == .play)
        #expect(policy.next(queuedMs: 30) == .play)
    }

    @Test func jitterDropsBeyond150ms() {
        var policy = JitterPolicy()
        #expect(policy.next(queuedMs: 80) == .play)
        #expect(policy.next(queuedMs: 150) == .play)
        // Beyond the maximum: drop the oldest down to the target.
        #expect(policy.next(queuedMs: 200) == .dropOldest(ms: 140))
        #expect(policy.next(queuedMs: 60) == .play)
        // A burst before playing starts is dropped the same way.
        var fresh = JitterPolicy()
        #expect(fresh.next(queuedMs: 400) == .dropOldest(ms: 340))
        #expect(fresh.next(queuedMs: 60) == .play)
    }

    @Test func underrunWaitsFor40ms() {
        var policy = JitterPolicy()
        #expect(policy.next(queuedMs: 60) == .play)
        #expect(policy.next(queuedMs: 0) == .wait)
        #expect(policy.next(queuedMs: 20) == .wait)
        #expect(policy.next(queuedMs: 39.9) == .wait)
        #expect(policy.next(queuedMs: 40) == .play)
        #expect(policy.next(queuedMs: 10) == .play)
        // Another underrun waits again.
        #expect(policy.next(queuedMs: 0) == .wait)
        #expect(policy.next(queuedMs: 45) == .play)
    }

    @Test func customValues() {
        var policy = JitterPolicy(targetMs: 30, maxMs: 90, refillMs: 20)
        #expect(policy.next(queuedMs: 29) == .wait)
        #expect(policy.next(queuedMs: 30) == .play)
        #expect(policy.next(queuedMs: 100) == .dropOldest(ms: 70))
        #expect(policy.next(queuedMs: 0) == .wait)
        #expect(policy.next(queuedMs: 20) == .play)
    }
}

/// A small deterministic generator for the simulation.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
