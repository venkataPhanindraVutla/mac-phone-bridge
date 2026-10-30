import Foundation
import Testing
@testable import FeatureProximity

/// Monotonic seconds: `at(s)` is `s` seconds after an arbitrary start.
private func at(_ seconds: TimeInterval) -> TimeInterval { 5_000 + seconds }

/// At the default −80 dBm, −78 is NEAR but within 5 dB of the threshold, so losing it afterwards is
/// plain absence (the delay), not a vanish from close range.
private let near = -78

/// A monitor that has seen the phone at `rssi` at t = 0.
private func armedMonitor(config: ProximityConfig = ProximityConfig(), rssi: Int = near) -> ProximityMonitor {
    var m = ProximityMonitor(config: config)
    m.sample(rssi: rssi, at: at(0))
    _ = m.evaluate(now: at(0), idle: 0, blockers: [], testMode: false)
    return m
}

/// Ticks once a second from `from` through `to`, the Mac idle for `idle(t)`, and returns every decision.
private func run(_ m: inout ProximityMonitor, from: Int, to: Int, idle: (Int) -> TimeInterval = { _ in 1_000 },
                 blockers: Set<Blocker> = [], testMode: Bool = false) -> [Decision] {
    (from...to).map { s in m.evaluate(now: at(TimeInterval(s)), idle: idle(s), blockers: blockers, testMode: testMode) }
}

/// The first second in `from...to` that locks, ticking with `rssi(t)` heard (nil: nothing).
private func firstLock(_ m: inout ProximityMonitor, from: Int, to: Int, rssi: (Int) -> Int?,
                       idle: TimeInterval = 1_000, testMode: Bool = false) -> Int? {
    for s in from...to {
        if let r = rssi(s) { m.sample(rssi: r, at: at(TimeInterval(s))) }
        if m.evaluate(now: at(TimeInterval(s)), idle: idle, blockers: [], testMode: testMode) == .lock { return s }
    }
    return nil
}

// MARK: smoothing

@Test func medianOfLast10s() {
    var m = ProximityMonitor(config: ProximityConfig())
    // Older than 10 s before the newest sample: dropped.
    m.sample(rssi: -40, at: at(0))
    m.sample(rssi: -40, at: at(1))
    m.sample(rssi: -70, at: at(12))
    m.sample(rssi: -90, at: at(13))
    m.sample(rssi: -75, at: at(14))
    #expect(m.smoothedRSSI(at: at(14)) == -75)
}

@Test func evenCountUsesUpperMiddle() {
    var m = ProximityMonitor(config: ProximityConfig())
    for (i, rssi) in [-90, -70, -80, -60].enumerated() { m.sample(rssi: rssi, at: at(TimeInterval(i))) }
    // Sorted: -90, -80, -70, -60; the two middle values are -80 and -70; the higher is -70.
    #expect(m.smoothedRSSI(at: at(3)) == -70)
}

@Test func absentAfter20sIsFar() {
    var m = ProximityMonitor(config: ProximityConfig())
    m.sample(rssi: -50, at: at(0))
    #expect(m.smoothedRSSI(at: at(20)) == -50)
    #expect(m.zone(at: at(20)) == .near)
    #expect(m.smoothedRSSI(at: at(20.5)) == nil)
    #expect(m.zone(at: at(20.5)) == .far)
}

@Test func belowThresholdIsFarAndAtThresholdIsNear() {
    var m = ProximityMonitor(config: ProximityConfig(thresholdDBm: -80))
    m.sample(rssi: -80, at: at(0))
    #expect(m.zone(at: at(0)) == .near)
    m.reset()
    m.sample(rssi: -81, at: at(0))
    #expect(m.zone(at: at(0)) == .far)
}

@Test func olderSampleBecomesNewest() {
    var m = ProximityMonitor(config: ProximityConfig())
    m.sample(rssi: -50, at: at(3_600))
    // Out of order (it can't happen on a monotonic clock, but it must not freeze the median).
    m.sample(rssi: -90, at: at(0))
    #expect(m.smoothedRSSI(at: at(0)) == -90)
    #expect(m.smoothedRSSI(at: at(21)) == nil)
}

@Test func unavailableRssiIsIgnored() {
    // CoreBluetooth reports 127 when it has no RSSI.
    var m = ProximityMonitor(config: ProximityConfig())
    m.sample(rssi: 127, at: at(0))
    #expect(m.smoothedRSSI(at: at(0)) == nil)
}

// MARK: deciding

@Test func farHeldForDelayLocks() {
    var m = armedMonitor()
    // Absent from t = 21 (the last sample is at 0), so FAR from then on; plain absence locks 30 s later.
    let decisions = run(&m, from: 1, to: 51)
    #expect(decisions[0] == .none) // t = 1, still NEAR
    #expect(decisions[20] == .countdown(30)) // t = 21: the first FAR
    #expect(decisions[49] == .countdown(1)) // t = 50
    #expect(decisions[50] == .lock) // t = 51
    #expect(!m.armed)
}

@Test func neverLocksWhileMacIsInUse() {
    var m = armedMonitor()
    // FAR for 120 s, but someone touched the Mac 5 s ago at every tick.
    let decisions = run(&m, from: 21, to: 141, idle: { _ in 5 })
    #expect(!decisions.contains(.lock))
    #expect(m.armed)
    // The first quiet stretch of 60 s (the floor; the delay is 30) locks.
    #expect(m.evaluate(now: at(142), idle: 60, blockers: [], testMode: false) == .lock)
}

@Test func idleBelowSixtySecondsNeverLocks() {
    var m = armedMonitor()
    // The delay is 30 s, but the Mac must be idle for at least 60.
    let decisions = run(&m, from: 21, to: 400, idle: { _ in 59.9 })
    #expect(!decisions.contains(.lock))
    #expect(decisions.last == .countdown(0))
    // A longer delay raises the idle floor with it.
    var long = armedMonitor(config: ProximityConfig(delay: 90))
    #expect(!run(&long, from: 21, to: 600, idle: { _ in 89 }).contains(.lock))
    #expect(long.evaluate(now: at(601), idle: 90, blockers: [], testMode: false) == .lock)
}

@Test func singleWeakSampleDoesNotLock() {
    var m = ProximityMonitor(config: ProximityConfig())
    // A steady -60 every second, and one -99 at t = 30.
    var decisions: [Decision] = []
    for s in 0...300 {
        m.sample(rssi: s == 30 ? -99 : -60, at: at(TimeInterval(s)))
        decisions.append(m.evaluate(now: at(TimeInterval(s)), idle: 1_000, blockers: [], testMode: false))
    }
    #expect(decisions.allSatisfy { $0 == .none })
    #expect(m.zone(at: at(30)) == .near)
}

@Test func weakButPresentNeedsLongerHold() {
    // Near, then still heard but weak (-90): FAR, held for max(2 × 30, 60) = 60 s, not the delay.
    var m = armedMonitor()
    let lock = firstLock(&m, from: 1, to: 300, rssi: { _ in -90 })
    let start = try! #require(m.lastFarStart)
    #expect(lock.map { at(TimeInterval($0)) - start } == 60)
    // A 60 s delay doubles it: 120 s.
    var slow = armedMonitor(config: ProximityConfig(delay: 60))
    let slowLock = firstLock(&slow, from: 1, to: 400, rssi: { _ in -90 })
    let slowStart = try! #require(slow.lastFarStart)
    #expect(slowLock.map { at(TimeInterval($0)) - slowStart } == 120)
}

@Test func weakThenGoneKeepsTheLongerHold() {
    // Weak for a while, then not heard at all: the weak hold still applies to the whole stretch.
    var m = armedMonitor()
    let lock = firstLock(&m, from: 1, to: 400, rssi: { $0 <= 12 ? -90 : nil })
    let start = try! #require(m.lastFarStart)
    #expect(lock.map { at(TimeInterval($0)) - start } == 60)
}

@Test func vanishAtMinus55DoesNotLockWithinTwoMinutes() {
    // A strong -55 that suddenly stops: a phone that left would fade first, so the absence counts
    // as FAR only after max(4 × 30, 120) = 120 s, and then the delay runs.
    var m = armedMonitor(rssi: -55)
    #expect(!run(&m, from: 1, to: 120).contains(.lock))
    // Absent from 21: FAR counts from 141, and the 30 s delay ends at 171.
    #expect(firstLock(&m, from: 121, to: 600, rssi: { _ in nil }) == 171)
    // Test mode counts down the same hold.
    var t = armedMonitor(rssi: -55)
    #expect(t.evaluate(now: at(21), idle: 0, blockers: [], testMode: true) == .countdown(150))
    #expect(firstLock(&t, from: 22, to: 600, rssi: { _ in nil }, idle: 0, testMode: true) == 171)
}

@Test func vanishFromCloseLocksAfterTheLongHoldWhenIdleAndAway() {
    // At a 60 s delay: max(240, 120) + 60 = 300 s after the absence began (t = 21).
    var m = armedMonitor(config: ProximityConfig(delay: 60), rssi: -60)
    #expect(firstLock(&m, from: 1, to: 1_000, rssi: { _ in nil }) == 321)
    // Never while someone is at the Mac.
    var used = armedMonitor(rssi: -55)
    #expect(firstLock(&used, from: 1, to: 1_000, rssi: { _ in nil }, idle: 10) == nil)
}

@Test func vanishMarginIsFiveDecibelsAboveThreshold() {
    // -75 is exactly threshold + 5: a vanish. -76 is plain absence.
    var close = armedMonitor(rssi: -75)
    #expect(firstLock(&close, from: 1, to: 600, rssi: { _ in nil }) == 171)
    var plain = armedMonitor(rssi: -76)
    #expect(firstLock(&plain, from: 1, to: 600, rssi: { _ in nil }) == 51)
}

@Test func noLockBeforeFirstNear() {
    var m = ProximityMonitor(config: ProximityConfig())
    // Weak from launch: never NEAR, so never armed.
    var decisions: [Decision] = []
    for s in 0...300 {
        m.sample(rssi: -92, at: at(TimeInterval(s)))
        decisions.append(m.evaluate(now: at(TimeInterval(s)), idle: 1_000, blockers: [], testMode: false))
    }
    #expect(decisions.allSatisfy { $0 == .none })
    #expect(!m.armed)
    // Nothing at all from launch: also never armed.
    var silent = ProximityMonitor(config: ProximityConfig())
    #expect(run(&silent, from: 0, to: 300).allSatisfy { $0 == .none })
}

@Test func lockDisarmsUntilNearAgain() {
    var m = armedMonitor()
    let first = run(&m, from: 1, to: 51)
    #expect(first.filter { $0 == .lock }.count == 1)
    // Still away for ten more minutes: nothing more.
    #expect(run(&m, from: 52, to: 652).allSatisfy { $0 == .none })
    // Back near, then away again: locks once more.
    m.sample(rssi: near, at: at(653))
    #expect(m.evaluate(now: at(653), idle: 1_000, blockers: [], testMode: false) == .none)
    #expect(m.armed)
    let second = run(&m, from: 654, to: 720)
    #expect(second.filter { $0 == .lock }.count == 1)
}

@Test func blockersNeverLock() {
    let all: [Blocker] = [.featureOff, .noPhone, .bluetoothOff, .bluetoothUnauthorized, .lockUnavailable,
                          .screenLocked, .asleep, .phoneNotAdvertising, .noRecentSession, .scannerStalled, .macInUse]
    for blocker in all {
        var m = armedMonitor()
        let decisions = run(&m, from: 1, to: 600, blockers: [blocker])
        #expect(decisions.allSatisfy { $0 == .none }, "blocker \(blocker)")
        // Not even in test mode.
        var t = armedMonitor()
        #expect(run(&t, from: 1, to: 600, blockers: [blocker], testMode: true).allSatisfy { $0 == .none })
    }
}

@Test func blockerDisarmsAndRestartsTheFarClock() {
    var m = armedMonitor()
    // FAR from 21; at 40 Bluetooth goes off for a while, then comes back with the phone still away.
    _ = run(&m, from: 21, to: 40)
    _ = run(&m, from: 41, to: 60, blockers: [.bluetoothOff])
    #expect(!m.armed)
    #expect(m.farSince == nil)
    #expect(run(&m, from: 61, to: 400).allSatisfy { $0 == .none })
}

@Test func wakeClearsSamples() {
    var m = armedMonitor()
    m.sample(rssi: near, at: at(5))
    m.reset() // the Mac woke
    #expect(m.smoothedRSSI(at: at(6)) == nil)
    #expect(!m.armed)
    #expect(m.farSince == nil)
    // Away after the wake: no lock, since the phone wasn't seen near since.
    #expect(run(&m, from: 6, to: 300).allSatisfy { $0 == .none })
}

@Test func testModeNeverDisarmsAndIgnoresIdle() {
    var m = armedMonitor()
    // In use (idle 0) all along: test mode still says it would lock, and keeps saying it.
    let decisions = run(&m, from: 21, to: 120, idle: { _ in 0 }, testMode: true)
    #expect(decisions[0] == .countdown(30))
    #expect(decisions[30] == .lock) // t = 51
    #expect(decisions[31...].allSatisfy { $0 == .lock })
    #expect(m.armed)
}

@Test func countdownNeverGoesNegative() {
    var m = armedMonitor()
    let decisions = run(&m, from: 21, to: 100, idle: { _ in 0 })
    for case let .countdown(remaining) in decisions { #expect(remaining >= 0) }
}

@Test func configIsClamped() {
    #expect(ProximityConfig().thresholdDBm == -80)
    #expect(ProximityConfig().delay == 30)
    #expect(ProximityConfig(thresholdDBm: -120).thresholdDBm == -95)
    #expect(ProximityConfig(thresholdDBm: 0).thresholdDBm == -55)
    #expect(ProximityConfig(delay: 1).delay == 10)
    #expect(ProximityConfig(delay: 600).delay == 120)
    #expect(ProximityConfig(delay: .nan).delay == 30)
    var c = ProximityConfig()
    c.thresholdDBm = -10
    c.delay = 5
    #expect(c.thresholdDBm == -55)
    #expect(c.delay == 10)
    #expect(ProximityConfig.window == 10)
    #expect(ProximityConfig.absentAfter == 20)
}

@Test func holdsFollowTheDelay() {
    let short = ProximityConfig(delay: 10)
    #expect(short.idleRequired == 60)
    #expect(short.weakHold == 60)
    #expect(short.vanishHold == 120 + 10)
    let long = ProximityConfig(delay: 120)
    #expect(long.idleRequired == 120)
    #expect(long.weakHold == 240)
    #expect(long.vanishHold == 480 + 120)
}
