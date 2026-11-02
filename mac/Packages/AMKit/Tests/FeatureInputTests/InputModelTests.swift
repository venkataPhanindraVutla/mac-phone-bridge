import AMProtocol
import CoreGraphics
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureInput

/// Everything posted, in order. The cursor follows the moves, as the real one does.
@MainActor
private final class FakePoster: EventPoster {
    enum Call: Equatable {
        /// The held button and the drag's click state; nil and 0 for a plain move.
        case move(CGPoint, AMMouseButton?, Int)
        case button(AMMouseButton, down: Bool, CGPoint, count: Int)
        case scroll(Int32, Int32)
        case key(CGKeyCode)
    }

    var calls: [Call] = []
    var cursor = CGPoint(x: 100, y: 100)
    /// Like a real cursor that keeps only whole points.
    var wholePoints = false
    let rects = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]

    var moves: [CGPoint] { calls.compactMap { if case let .move(p, _, _) = $0 { p } else { nil } } }
    var ups: Int { calls.filter { if case .button(_, down: false, _, _) = $0 { true } else { false } }.count }

    func location() -> CGPoint { cursor }
    func screens() -> [CGRect] { rects }
    func move(to p: CGPoint, holding: AMMouseButton?, clickCount: Int) {
        cursor = wholePoints ? CGPoint(x: p.x.rounded(.down), y: p.y.rounded(.down)) : p
        calls.append(.move(p, holding, clickCount))
    }
    func button(_ b: AMMouseButton, down: Bool, at p: CGPoint, clickCount: Int) {
        calls.append(.button(b, down: down, p, count: clickCount))
    }
    func scroll(pixelsX: Int32, pixelsY: Int32) { calls.append(.scroll(pixelsX, pixelsY)) }
    func key(_ code: CGKeyCode) { calls.append(.key(code)) }
}

@MainActor
private final class FakeLaser: LaserOverlay {
    var shown: [CGPoint] = []
    var hides = 0
    var visible = false
    func show(at p: CGPoint) {
        shown.append(p)
        visible = true
    }
    func hide() {
        hides += 1
        visible = false
    }
}

@MainActor
private final class FakeTrust: AccessibilityTrust {
    var trusted: Bool
    /// The `prompt` of every call, in order.
    var prompts: [Bool] = []
    init(_ trusted: Bool) { self.trusted = trusted }
    func isTrusted(prompt: Bool) -> Bool {
        prompts.append(prompt)
        return trusted
    }
}

/// Not actor-bound: the model's `now` and `naturalScrolling` closures read it.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class Rig {
    let poster = FakePoster()
    let laser = FakeLaser()
    let trust: FakeTrust
    /// Seconds of a monotonic clock, as `ProcessInfo.systemUptime` gives.
    let clock = Box<TimeInterval>(1_000)
    let natural = Box(true)
    var availabilities: [AMFeatureAvailability] = []
    var model: InputModel!

    init(enabled: Bool = true, trusted: Bool = true,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }) {
        trust = FakeTrust(trusted)
        let clock = clock
        let natural = natural
        model = InputModel(
            poster: poster, laser: laser, trust: trust, enabled: enabled,
            naturalScrolling: { natural.value },
            send: { [weak self] type, message in
                if type == .inputAvailability, let a = message as? AMFeatureAvailability { self?.availabilities.append(a) }
            },
            now: { clock.value })
        // By default the loops never fire by themselves: the tests call tick() and recheckTrust().
        model.sleep = sleep
    }

    func connect(shared: Set<String> = ["input.v1"]) async {
        await model.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
    }

    func advance(_ seconds: TimeInterval) { clock.value += seconds }

    func send<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) async {
        var e = AMEnvelope()
        e.channel = .input
        e.type = type.rawValue
        e.payload = (try? message.serializedData()) ?? Data()
        await model.message(e)
    }

    func move(_ dx: Float, _ dy: Float) async {
        var m = AMInputMove()
        m.dx = dx
        m.dy = dy
        await send(.inputMove, m)
    }

    func button(_ b: AMMouseButton, down: Bool) async {
        var m = AMInputButton()
        m.button = b
        m.down = down
        await send(.inputButton, m)
    }

    func click(_ b: AMMouseButton, count: UInt32) async {
        var m = AMInputClick()
        m.button = b
        m.count = count
        await send(.inputClick, m)
    }

    func scroll(_ dx: Float, _ dy: Float) async {
        var m = AMInputScroll()
        m.dx = dx
        m.dy = dy
        await send(.inputScroll, m)
    }

    func key(_ k: AMRemoteKey) async {
        var m = AMInputKey()
        m.key = k
        await send(.inputKey, m)
    }

    func laserFrame(_ on: Bool) async {
        var m = AMInputLaser()
        m.on = on
        await send(.inputLaser, m)
    }

    /// One of each frame.
    func everyFrame() async {
        await move(5, 5)
        await button(.left, down: true)
        await button(.left, down: false)
        await click(.left, count: 1)
        await scroll(0, 10)
        await key(.nextSlide)
        await laserFrame(true)
    }
}

private func reason(_ a: AMFeatureAvailability?) -> AMAvailabilityReason? {
    guard let a else { return nil }
    return a.enabled ? nil : a.reason
}

// MARK: gating

@MainActor @Test func inputIgnoredUnlessEnabledAndTrusted() async {
    let off = Rig(enabled: false, trusted: true)
    await off.connect()
    await off.everyFrame()
    #expect(off.poster.calls.isEmpty)
    #expect(off.laser.shown.isEmpty)

    let untrusted = Rig(enabled: true, trusted: false)
    await untrusted.connect()
    await untrusted.everyFrame()
    #expect(untrusted.poster.calls.isEmpty)
    #expect(untrusted.laser.shown.isEmpty)

    // No session: nothing acts before connect, or for a phone that doesn't share input.v1.
    let idle = Rig()
    await idle.everyFrame()
    await idle.connect(shared: ["media.v1"])
    await idle.everyFrame()
    #expect(idle.poster.calls.isEmpty)

    let on = Rig()
    await on.connect()
    await on.move(5, 5)
    #expect(on.poster.calls == [.move(CGPoint(x: 105, y: 105), nil, 0)])
}

@MainActor @Test func availabilityReflectsSettingAndTrust() async {
    let r = Rig(enabled: false, trusted: false)
    // Nothing goes before a session that shares input.v1.
    await r.model.setEnabled(true)
    await r.model.setEnabled(false)
    await r.connect(shared: ["media.v1"])
    #expect(r.availabilities.isEmpty)

    await r.connect()
    #expect(r.availabilities.map(reason) == [.offByUser])
    await r.model.setEnabled(true)
    #expect(reason(r.availabilities.last) == .needsPermission)
    #expect(!r.model.trusted)

    r.trust.trusted = true
    await r.model.recheckTrust()
    #expect(r.availabilities.last?.enabled == true)
    #expect(r.model.trusted)
    // Unchanged: not sent again.
    let count = r.availabilities.count
    await r.model.recheckTrust()
    #expect(r.availabilities.count == count)

    await r.model.setEnabled(false)
    #expect(reason(r.availabilities.last) == .offByUser)

    // Each session starts with one.
    r.model.disconnected()
    await r.connect()
    #expect(reason(r.availabilities.last) == .offByUser)
    #expect(r.availabilities.count == count + 2)
}

@MainActor @Test func trustPromptOnlyWhenEnabled() async {
    let r = Rig(enabled: false, trusted: false)
    await r.connect()
    await r.model.recheckTrust()
    #expect(!r.trust.prompts.isEmpty)
    #expect(!r.trust.prompts.contains(true))

    await r.model.setEnabled(true)
    #expect(r.trust.prompts.last == true)
    #expect(r.trust.prompts.filter { $0 }.count == 1)

    // Already on: no second prompt. Re-checks and switching off never prompt.
    await r.model.setEnabled(true)
    await r.model.recheckTrust()
    await r.model.setEnabled(false)
    r.model.disconnected()
    await r.connect()
    #expect(r.trust.prompts.filter { $0 }.count == 1)
}

@MainActor @Test func trustIsRecheckedOnlyWhileEnabledAndConnected() async {
    let r = Rig(enabled: false, trusted: true)
    #expect(!r.model.isCheckingTrust)
    await r.connect()
    #expect(!r.model.isCheckingTrust)
    await r.model.setEnabled(true)
    #expect(r.model.isCheckingTrust)
    r.model.disconnected()
    #expect(!r.model.isCheckingTrust)
    await r.connect()
    #expect(r.model.isCheckingTrust)
    await r.model.setEnabled(false)
    #expect(!r.model.isCheckingTrust)
}

// MARK: frames

@MainActor @Test func moveAddsDeltaAndClamps() async {
    let r = Rig()
    await r.connect()
    await r.move(10, -5)
    await r.move(-500, 0)
    await r.move(2000, 2000)
    #expect(r.poster.moves == [
        CGPoint(x: 110, y: 95),
        CGPoint(x: 0, y: 95),
        // (2000, 2095) is below the larger screen.
        CGPoint(x: 2000, y: 1079),
    ])
    // Not a number moves nothing.
    await r.move(.nan, 1)
    await r.move(1, .infinity)
    #expect(r.poster.moves.count == 3)
}

@MainActor @Test func dragPostsDraggedWhileHeld() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.move(5, 5)
    await r.button(.left, down: false)
    await r.move(1, 0)
    await r.button(.right, down: true)
    await r.move(0, 1)
    await r.button(.right, down: false)
    #expect(r.poster.calls == [
        .button(.left, down: true, CGPoint(x: 100, y: 100), count: 1),
        .move(CGPoint(x: 105, y: 105), .left, 1),
        .button(.left, down: false, CGPoint(x: 105, y: 105), count: 1),
        .move(CGPoint(x: 106, y: 105), nil, 0),
        .button(.right, down: true, CGPoint(x: 106, y: 105), count: 1),
        .move(CGPoint(x: 106, y: 106), .right, 1),
        .button(.right, down: false, CGPoint(x: 106, y: 106), count: 1),
    ])
}

@MainActor @Test func clickPostsDownUpWithCount() async {
    let r = Rig()
    await r.connect()
    await r.click(.left, count: 2)
    await r.click(.right, count: 1)
    let p = CGPoint(x: 100, y: 100)
    #expect(r.poster.calls == [
        .button(.left, down: true, p, count: 2), .button(.left, down: false, p, count: 2),
        .button(.right, down: true, p, count: 1), .button(.right, down: false, p, count: 1),
    ])
}

@MainActor @Test func scrollFollowsNaturalSetting() async {
    let r = Rig()
    await r.connect()
    await r.scroll(1.4, -7.6)
    r.natural.value = false
    await r.scroll(1.4, -7.6)
    #expect(r.poster.calls == [.scroll(1, -8), .scroll(-1, 8)])
}

@MainActor @Test func slideKeysPostArrows() async {
    let r = Rig()
    await r.connect()
    await r.key(.prevSlide)
    await r.key(.nextSlide)
    await r.key(.unspecified)
    #expect(r.poster.calls == [.key(123), .key(124)])
}

@MainActor @Test func laserFollowsPointerAndHides() async {
    let r = Rig()
    await r.connect()
    await r.laserFrame(true)
    await r.move(10, 0)
    await r.laserFrame(false)
    // Already off: not hidden again.
    await r.laserFrame(false)
    await r.move(10, 0)
    #expect(r.laser.shown == [CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 100)])
    #expect(r.laser.hides == 1)
    #expect(!r.laser.visible)
}

// MARK: releases

@MainActor @Test func heldButtonReleasesAfter5sOfSilence() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.laserFrame(true)
    #expect(r.model.isTicking)
    r.advance(4.9)
    r.model.tick()
    #expect(r.poster.ups == 0)
    #expect(r.laser.visible)

    r.advance(0.1)
    r.model.tick()
    #expect(r.poster.calls.last == .button(.left, down: false, CGPoint(x: 100, y: 100), count: 1))
    #expect(!r.laser.visible)
    #expect(!r.model.isTicking)

    // Released once: neither a later tick nor the phone's own late up posts another.
    r.advance(10)
    r.model.tick()
    await r.button(.left, down: false)
    #expect(r.poster.ups == 1)
}

// R35: the phone repeats `down` for a held button (and `laser{on}`) at least every 2 s while
// the finger is still.
@MainActor @Test func repeatedDownDoesNotPressTwice() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    // A still finger for 12 s, kept alive every 2 s: one press, no release, and the drag's
    // click state is unchanged.
    for _ in 1...6 {
        r.advance(2)
        r.model.tick()
        await r.button(.left, down: true)
    }
    r.advance(2)
    r.model.tick()
    #expect(r.poster.calls == [.button(.left, down: true, CGPoint(x: 100, y: 100), count: 1)])
    await r.move(4, 0)
    #expect(r.poster.calls.last == .move(CGPoint(x: 104, y: 100), .left, 1))
    await r.button(.left, down: false)
    #expect(r.poster.ups == 1)

    // After a 5 s silence release (a stalled link), the next keepalive presses again — the
    // finger is still down — and the phone's up on lift lets go; nothing is ever left held.
    await r.button(.left, down: true)
    r.advance(5)
    r.model.tick()
    #expect(r.poster.ups == 2)
    await r.button(.left, down: true)
    #expect(r.poster.calls.last == .button(.left, down: true, CGPoint(x: 104, y: 100), count: 1))
    await r.button(.left, down: false)
    #expect(r.poster.ups == 3)
    // And with no up at all, silence releases it again.
    await r.button(.left, down: true)
    r.advance(5)
    r.model.tick()
    #expect(r.poster.ups == 4)
    #expect(!r.model.isTicking)
}

@MainActor @Test func repeatedLaserOnReshowsDot() async {
    let r = Rig()
    await r.connect()
    await r.laserFrame(true)
    // Kept alive every 2 s: never hidden.
    for _ in 1...4 {
        r.advance(2)
        r.model.tick()
        await r.laserFrame(true)
    }
    #expect(r.laser.hides == 0)
    #expect(r.laser.visible)

    // Hidden after a 5 s silence; the next keepalive shows it again where the pointer is.
    r.advance(5)
    r.model.tick()
    #expect(!r.laser.visible)
    #expect(!r.model.isTicking)
    await r.laserFrame(true)
    #expect(r.laser.visible)
    #expect(r.laser.shown.last == CGPoint(x: 100, y: 100))
    #expect(r.model.isTicking)
}

@MainActor @Test func longDragWithMovesIsNotReleased() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    for _ in 1...12 {
        r.advance(1)
        await r.move(1, 0)
        r.model.tick()
    }
    #expect(r.poster.ups == 0)
    #expect(r.poster.calls.last == .move(CGPoint(x: 112, y: 100), .left, 1))

    r.advance(5)
    r.model.tick()
    #expect(r.poster.ups == 1)
}

@MainActor @Test func disconnectReleasesHeldButtonAndHidesLaser() async {
    let r = Rig()
    await r.connect()
    await r.button(.right, down: true)
    await r.move(3, 4)
    await r.laserFrame(true)
    r.model.disconnected()
    #expect(r.poster.calls.last == .button(.right, down: false, CGPoint(x: 103, y: 104), count: 1))
    #expect(!r.laser.visible)
    #expect(!r.model.isTicking)

    // The session is over: frames do nothing until the next connect.
    let count = r.poster.calls.count
    await r.everyFrame()
    #expect(r.poster.calls.count == count)

    // Forgetting the connected phone does the same.
    await r.connect()
    await r.button(.left, down: true)
    await r.model.forget(phoneID: "P1")
    #expect(r.poster.calls.last == .button(.left, down: false, CGPoint(x: 103, y: 104), count: 1))
}

@MainActor @Test func upForButtonNotHeldIsIgnored() async {
    let r = Rig()
    await r.connect()
    // Never pressed.
    await r.button(.left, down: false)
    #expect(r.poster.calls.isEmpty)

    // Held still past 5 s, released by the Mac; the phone's up on lift posts nothing more.
    await r.button(.left, down: true)
    r.advance(5)
    r.model.tick()
    #expect(r.poster.ups == 1)
    await r.button(.left, down: false)
    #expect(r.poster.ups == 1)

    // An up for the other button while one is held leaves the held one alone.
    await r.button(.left, down: true)
    await r.button(.right, down: false)
    #expect(r.poster.ups == 1)
    await r.move(1, 0)
    #expect(r.poster.calls.last == .move(CGPoint(x: 101, y: 100), .left, 1))
}

@MainActor @Test func disablingReleasesHeldButtonAndHidesLaser() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.laserFrame(true)
    await r.model.setEnabled(false)
    #expect(r.poster.calls.last == .button(.left, down: false, CGPoint(x: 100, y: 100), count: 1))
    #expect(!r.laser.visible)
    #expect(!r.model.isTicking)
    #expect(reason(r.availabilities.last) == .offByUser)
    // The phone's up arrives after availability went off: nothing acts, nothing extra posts.
    await r.button(.left, down: false)
    #expect(r.poster.ups == 1)

    // Accessibility revoked does the same (accessibilityRevokedStopsInjectionAndReports).
    await r.model.setEnabled(true)
    await r.button(.right, down: true)
    await r.laserFrame(true)
    r.trust.trusted = false
    await r.model.recheckTrust()
    #expect(r.poster.calls.last == .button(.right, down: false, CGPoint(x: 100, y: 100), count: 1))
    #expect(!r.laser.visible)
}

@MainActor @Test func fractionalMovesAccumulate() async {
    let r = Rig()
    r.poster.wholePoints = true
    await r.connect()
    for _ in 0..<10 { await r.move(0.25, -0.3) }
    let last = r.poster.moves.last ?? .zero
    #expect(abs(last.x - 102.5) < 0.001)
    #expect(abs(last.y - 97) < 0.001)

}

@MainActor @Test func physicalMouseMoveIsRespected() async {
    let r = Rig()
    await r.connect()
    await r.move(10, 0)
    await r.move(10, 0)
    // The real cursor lagging one post behind still counts as ours.
    r.poster.cursor = CGPoint(x: 110, y: 100)
    await r.move(0.5, 0)
    #expect(r.poster.moves.last == CGPoint(x: 120.5, y: 100))

    // The user's own mouse moved, mid-stream and with no pause: it wins.
    r.poster.cursor = CGPoint(x: 500, y: 500)
    await r.move(0.5, 0)
    #expect(r.poster.moves.last == CGPoint(x: 500.5, y: 500))
}

@MainActor @Test func doubleTapAndHoldDragsWithClickState2() async {
    let r = Rig()
    await r.connect()
    let p = CGPoint(x: 100, y: 100)
    await r.click(.left, count: 1)
    r.advance(0.2)
    await r.button(.left, down: true)
    await r.move(10, 0)
    await r.button(.left, down: false)
    #expect(Array(r.poster.calls.suffix(3)) == [
        .button(.left, down: true, p, count: 2),
        .move(CGPoint(x: 110, y: 100), .left, 2),
        .button(.left, down: false, CGPoint(x: 110, y: 100), count: 2),
    ])

    // The second click of a double click carries 2; a third press soon after carries 3.
    let q = CGPoint(x: 110, y: 100)
    r.advance(0.2)
    await r.button(.left, down: true)
    await r.button(.left, down: false)
    #expect(r.poster.calls.suffix(2) == [.button(.left, down: true, q, count: 3), .button(.left, down: false, q, count: 3)])

    // Too late, too far, or the other button: a fresh single press.
    r.advance(1)
    await r.button(.left, down: true)
    await r.button(.left, down: false)
    #expect(r.poster.calls.last == .button(.left, down: false, q, count: 1))
    r.advance(0.1)
    await r.button(.right, down: true)
    await r.button(.right, down: false)
    #expect(r.poster.calls.last == .button(.right, down: false, q, count: 1))
    r.advance(0.1)
    await r.click(.left, count: 1)
    await r.move(50, 0)
    r.advance(0.1)
    await r.button(.left, down: true)
    #expect(r.poster.calls.last == .button(.left, down: true, CGPoint(x: 160, y: 100), count: 1))
}

@MainActor @Test func switchingOffReleasesAtOnce() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.laserFrame(true)
    // Synchronous: released before anything is awaited.
    r.model.disable()
    #expect(r.poster.ups == 1)
    #expect(!r.laser.visible)
    #expect(!r.model.enabled)
    #expect(r.availabilities.last?.enabled == true)
    // The setting's own call then only reports it, once.
    await r.model.setEnabled(false)
    #expect(reason(r.availabilities.last) == .offByUser)
    let count = r.availabilities.count
    await r.model.setEnabled(false)
    #expect(r.availabilities.count == count)
    #expect(r.poster.ups == 1)
}

@MainActor @Test func shutdownReleasesHeldButtonAndHidesLaser() async {
    let r = Rig()
    await r.connect()
    await r.button(.right, down: true)
    await r.laserFrame(true)
    r.model.shutdown()
    #expect(r.poster.calls.last == .button(.right, down: false, CGPoint(x: 100, y: 100), count: 1))
    #expect(!r.laser.visible)
}

@MainActor @Test func clickWhileHeldReleasesFirst() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.move(5, 0)
    await r.click(.right, count: 1)
    let p = CGPoint(x: 105, y: 100)
    #expect(Array(r.poster.calls.suffix(3)) == [
        .button(.left, down: false, p, count: 1),
        .button(.right, down: true, p, count: 1),
        .button(.right, down: false, p, count: 1),
    ])
    // Nothing is held now: moves are plain, and the phone's late up posts nothing.
    await r.button(.left, down: false)
    await r.move(1, 0)
    #expect(r.poster.ups == 2)
    #expect(r.poster.calls.last == .move(CGPoint(x: 106, y: 100), nil, 0))
}

@MainActor @Test func slowScrollAccumulates() async {
    let r = Rig()
    await r.connect()
    for _ in 0..<10 { await r.scroll(0.3, -0.3) }
    let xs = r.poster.calls.compactMap { if case let .scroll(x, _) = $0 { x } else { nil } }
    let ys = r.poster.calls.compactMap { if case let .scroll(_, y) = $0 { y } else { nil } }
    #expect(xs.reduce(0, +) == 3)
    #expect(ys.reduce(0, +) == -3)
    #expect(xs.count < 10)
}

/// Waits up to 30 s for `condition` (generous: it only bounds a test that is failing, and a busy
/// runner can be seconds behind).
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor @Test func releaseLoopFiresOnItsOwn() async {
    let r = Rig(sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
    await r.connect()
    await r.button(.left, down: true)
    r.advance(5)
    #expect(await eventually { r.poster.ups == 1 })
    #expect(await eventually { !r.model.isTicking })
}

@MainActor @Test func trustLoopFiresOnItsOwn() async {
    let r = Rig(sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
    await r.connect()
    #expect(r.availabilities.last?.enabled == true)
    r.trust.trusted = false
    #expect(await eventually { reason(r.availabilities.last) == .needsPermission })
    #expect(!r.model.trusted)
}

@MainActor @Test func accessibilityRevokedStopsInjectionAndReports() async {
    let r = Rig()
    await r.connect()
    #expect(r.availabilities.last?.enabled == true)
    await r.button(.left, down: true)
    await r.laserFrame(true)

    r.trust.trusted = false
    await r.model.recheckTrust()
    #expect(r.poster.calls.last == .button(.left, down: false, CGPoint(x: 100, y: 100), count: 1))
    #expect(!r.laser.visible)
    #expect(reason(r.availabilities.last) == .needsPermission)

    let count = r.poster.calls.count
    await r.everyFrame()
    #expect(r.poster.calls.count == count)
}

// MARK: rate

@MainActor @Test func framesBeyond240PerSecondAreDropped() async {
    let r = Rig()
    await r.connect()
    for _ in 0..<300 { await r.move(1, 0) }
    #expect(r.poster.moves.count == 240)
    await r.click(.left, count: 1)
    await r.key(.nextSlide)
    await r.scroll(0, 5)
    #expect(r.poster.calls.count == 240)

    r.advance(0.5)
    await r.move(1, 0)
    #expect(r.poster.moves.count == 240)
    r.advance(0.5)
    await r.move(1, 0)
    #expect(r.poster.moves.count == 241)
}

@MainActor @Test func buttonUpIsNeverRateLimited() async {
    let r = Rig()
    await r.connect()
    await r.button(.left, down: true)
    await r.laserFrame(true)
    for _ in 0..<300 { await r.move(1, 0) }
    #expect(r.poster.moves.count == 238)
    await r.button(.left, down: false)
    await r.laserFrame(false)
    #expect(r.poster.calls.last == .button(.left, down: false, CGPoint(x: 338, y: 100), count: 1))
    #expect(!r.laser.visible)

    // They count toward the window: 240 laser-offs fill it, and the next move is dropped.
    let fresh = Rig()
    await fresh.connect()
    for _ in 0..<240 { await fresh.laserFrame(false) }
    await fresh.move(1, 0)
    #expect(fresh.poster.moves.isEmpty)
    // Already off, so the dot is never touched.
    #expect(fresh.laser.hides == 0)
}

// MARK: system settings

@Test func naturalScrollingReadsOffTheMainActor() async {
    let values = await Task.detached { () -> [Bool] in
        let name = "am-input-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return [] }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: InputModel.naturalScrollingKey)
        let off = InputModel.naturalScrolling(defaults)
        defaults.set(true, forKey: InputModel.naturalScrollingKey)
        return [off, InputModel.naturalScrolling(defaults)]
    }.value
    #expect(values == [false, true])
}
