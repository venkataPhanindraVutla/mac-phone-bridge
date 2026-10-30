import AMProtocol
import Foundation
import Testing
@testable import FeatureMedia

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func state(positionMs: Int64, durationMs: Int64 = 200_000, playing: Bool = true, speed: Float = 1) -> AMMediaState {
    var s = AMMediaState()
    s.active = true
    s.positionMs = positionMs
    s.durationMs = durationMs
    s.playing = playing
    s.speed = speed
    return s
}

@Test func positionExtrapolatesWhilePlaying() {
    let s = state(positionMs: 10_000)
    #expect(PositionClock.positionMs(s, receivedAt: t0, now: t0) == 10_000)
    #expect(PositionClock.positionMs(s, receivedAt: t0, now: t0.addingTimeInterval(2.5)) == 12_500)
    // At the phone's speed.
    let fast = state(positionMs: 10_000, speed: 2)
    #expect(PositionClock.positionMs(fast, receivedAt: t0, now: t0.addingTimeInterval(3)) == 16_000)
}

@Test func pausedPositionDoesNotMove() {
    let s = state(positionMs: 10_000, playing: false, speed: 1)
    #expect(PositionClock.positionMs(s, receivedAt: t0, now: t0.addingTimeInterval(60)) == 10_000)
}

@Test func positionClampsToDuration() {
    let s = state(positionMs: 199_000)
    #expect(PositionClock.positionMs(s, receivedAt: t0, now: t0.addingTimeInterval(5)) == 200_000)
    // A clock that went backwards never moves it below what the phone said, nor below 0.
    #expect(PositionClock.positionMs(state(positionMs: 1_000), receivedAt: t0, now: t0.addingTimeInterval(-5)) == 1_000)
    #expect(PositionClock.positionMs(state(positionMs: -50, playing: false), receivedAt: t0, now: t0) == 0)
    // Unknown or live duration: no upper bound.
    let live = state(positionMs: 199_000, durationMs: 0)
    #expect(PositionClock.positionMs(live, receivedAt: t0, now: t0.addingTimeInterval(5)) == 204_000)
}

@Test func zeroSpeedWhilePlayingCountsAsOne() {
    let s = state(positionMs: 10_000, speed: 0)
    #expect(PositionClock.positionMs(s, receivedAt: t0, now: t0.addingTimeInterval(4)) == 14_000)
}
