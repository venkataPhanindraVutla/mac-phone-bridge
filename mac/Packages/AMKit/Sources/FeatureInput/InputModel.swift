import AMProtocol
import ConnectionCore
import CoreGraphics
import Foundation
import Observation
import os
import SwiftProtobuf

/// The phone as trackpad and remote (SPEC section 23, PRD F-16): `input.*` frames become pointer,
/// scroll and key events on this Mac.
///
/// Frames act only while the "Allow <phone> to control the pointer" setting is on, this app is
/// trusted for Accessibility, and the phone in session shares `input.v1`. Each must also fit the
/// 240-per-second window; button-up and laser-off always act, and still count toward it.
///
/// Safety net, whatever the phone does:
/// - a held button is released, and the laser hidden, 5 s after the last frame (`tick()`), and at
///   once on disconnect, on switch-off, on quit and when Accessibility is revoked;
/// - an up for a button this Mac isn't holding posts nothing.
///
/// Keepalive (ruling R35): while a button is held or the laser is on, the phone repeats that frame
/// at least every 2 s. A `down` for the button already held only stamps the frame time (no second
/// press, click state kept); `laser{on}` shows the dot again if it was hidden. A `down` while
/// nothing is held is always a new press, even when it is a keepalive after a 5 s silence release:
/// frames arrive in order, so the phone still holds that button (it would have sent the up first
/// otherwise). The pressed-again button can't stick: the phone's up on lift, its close, or the next
/// 5 s silence lets go of it.
///
/// Accessibility is asked for (with the system prompt) only in `setEnabled(true)`; it is checked
/// again every 2 s while on and connected, and on `recheckTrust()`. Handlers stay trivial: they
/// post through `poster` and never wait on anything, so the ordered queue keeps flowing. Nothing
/// per frame is logged.
@MainActor
@Observable
public final class InputModel: SessionFeature {
    /// The global-domain key for "Natural scrolling".
    nonisolated public static let naturalScrollingKey = "com.apple.swipescrolldirection"
    /// How close (in points) a press must be to the last release to continue its click sequence.
    nonisolated static let multiClickDistance: CGFloat = 5
    /// How far (in points) the real cursor may be from one of the last two points posted and
    /// still count as ours: it may keep only whole points, or lag one post behind.
    nonisolated static let ownCursorSlack: CGFloat = 1

    public let messagePrefixes = ["input."]

    /// The "Allow <phone> to control the pointer" setting.
    public private(set) var enabled: Bool
    /// Whether this app is trusted for Accessibility, as last checked.
    public private(set) var trusted: Bool

    /// This Mac's `input.availability`.
    public var availability: AMFeatureAvailability {
        var a = AMFeatureAvailability()
        a.enabled = enabled && trusted
        a.reason = !enabled ? .offByUser : !trusted ? .needsPermission : .unspecified
        return a
    }

    @ObservationIgnored private let poster: any EventPoster
    @ObservationIgnored private let laser: any LaserOverlay
    @ObservationIgnored private let trust: any AccessibilityTrust
    @ObservationIgnored private let naturalScrolling: () -> Bool
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    /// Monotonic seconds, so a wall-clock step can't hold a button or freeze the rate window.
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let releaseAfter: TimeInterval
    @ObservationIgnored private let doubleClickInterval: TimeInterval
    /// The phone in session, while it shares `input.v1`.
    @ObservationIgnored private var phoneID: String?
    /// The button this Mac holds down, and the click state of its press.
    @ObservationIgnored private var held: (button: AMMouseButton, count: Int)?
    @ObservationIgnored private var laserOn = false
    @ObservationIgnored private var lastFrameAt: TimeInterval?
    @ObservationIgnored private var rate = RateWindow()
    /// The last point posted, fractions kept, and the one before it.
    @ObservationIgnored private var posted: (last: CGPoint, previous: CGPoint?)?
    /// What scrolls have left over after rounding to whole pixels, so slow scrolls add up.
    @ObservationIgnored private var scrollResidual: (x: Float, y: Float) = (0, 0)
    /// The last release (up or click), to count a following press as its double or triple.
    @ObservationIgnored private var lastRelease: (button: AMMouseButton, at: TimeInterval, point: CGPoint, count: Int)?
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var lastSentAvailability: AMFeatureAvailability?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var trustTask: Task<Void, Never>?
    /// How the loops wait (internal, so tests can stop them firing on their own).
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "input")

    public init(poster: any EventPoster, laser: any LaserOverlay, trust: any AccessibilityTrust, enabled: Bool,
                naturalScrolling: @escaping () -> Bool,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                releaseAfter: TimeInterval = 5,
                doubleClickInterval: TimeInterval = 0.5) {
        self.poster = poster
        self.laser = laser
        self.trust = trust
        self.enabled = enabled
        self.naturalScrolling = naturalScrolling
        self.send = send
        self.now = now
        self.releaseAfter = releaseAfter
        self.doubleClickInterval = doubleClickInterval
        trusted = trust.isTrusted(prompt: false)
    }

    /// The Mac's "Natural scrolling" setting (default on). Safe from any thread.
    nonisolated public static func naturalScrolling(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: naturalScrollingKey) as? Bool ?? true
    }

    /// Whether the 1 s release timer runs (internal, for tests).
    var isTicking: Bool { tickTask != nil }
    /// Whether the 2 s Accessibility check runs (internal, for tests).
    var isCheckingTrust: Bool { trustTask != nil }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        endSession()
        guard shared.contains("input.v1") else { return }
        self.phoneID = phoneID
        trusted = trust.isTrusted(prompt: false)
        updateLoops()
        await sendAvailability()
    }

    public func disconnected() {
        if held != nil { Self.log.notice("released held button on disconnect") }
        endSession()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phoneID != nil, enabled, trusted else { return }
        switch MessageType(rawValue: envelope.type) {
        case .inputMove:
            guard let m = try? AMInputMove(serializedBytes: envelope.payload), admit() else { return }
            move(dx: m.dx, dy: m.dy)
        case .inputButton:
            guard let m = try? AMInputButton(serializedBytes: envelope.payload), admit(always: !m.down) else { return }
            button(m.button, down: m.down)
        case .inputClick:
            guard let m = try? AMInputClick(serializedBytes: envelope.payload), admit() else { return }
            click(m.button, count: Int(m.count))
        case .inputScroll:
            guard let m = try? AMInputScroll(serializedBytes: envelope.payload), admit() else { return }
            scroll(dx: m.dx, dy: m.dy)
        case .inputKey:
            guard let m = try? AMInputKey(serializedBytes: envelope.payload), admit() else { return }
            switch m.key {
            case .prevSlide: poster.key(123) // Left arrow
            case .nextSlide: poster.key(124) // Right arrow
            default: break
            }
        case .inputLaser:
            guard let m = try? AMInputLaser(serializedBytes: envelope.payload), admit(always: !m.on) else { return }
            if m.on {
                laserOn = true
                laser.show(at: current())
            } else if laserOn {
                laserOn = false
                laser.hide()
            }
            updateLoops()
        default:
            break
        }
    }

    public func forget(phoneID: String) async {
        guard self.phoneID == phoneID else { return }
        endSession()
    }

    // MARK: setting and trust

    /// The setting. Turning it on is the only place that asks for Accessibility with the system
    /// prompt; turning it off lets go of anything held.
    ///
    /// Sends the availability even when the setting already matches, so a `disable()` made
    /// first is reported.
    public func setEnabled(_ on: Bool) async {
        if !on {
            disable()
        } else if !enabled {
            enabled = true
            Self.log.notice("pointer control on")
            trusted = trust.isTrusted(prompt: true)
            updateLoops()
        }
        await sendAvailability()
    }

    /// Switches off at once, without waiting: nothing held stays held, the laser goes, and no
    /// frame acts from here on. `setEnabled(false)` reports it to the phone.
    public func disable() {
        guard enabled else { return }
        enabled = false
        Self.log.notice("pointer control off")
        releaseAll()
    }

    /// App quit: lets go of anything held and hides the laser.
    public func shutdown() {
        releaseAll()
    }

    /// Checks Accessibility again without a prompt (app activation, Settings, the 2 s loop).
    /// Losing it lets go of anything held; the post may fail by then, which is harmless.
    public func recheckTrust() async {
        let now = trust.isTrusted(prompt: false)
        guard now != trusted else { return }
        Self.log.notice("accessibility trusted \(now, privacy: .public)")
        if !now { releaseAll() }
        trusted = now
        await sendAvailability()
    }

    /// Releases a held button and hides the laser once no frame has come for `releaseAfter`.
    /// A 1 s timer calls it while either is on.
    public func tick() {
        guard held != nil || laserOn, let last = lastFrameAt, now() - last >= releaseAfter else { return }
        if held != nil { Self.log.notice("released held button after silence") }
        releaseAll()
    }

    // MARK: frames

    /// Stamps the frame and fits it into the rate window; `always` frames act regardless.
    private func admit(always: Bool = false) -> Bool {
        let t = now()
        lastFrameAt = t
        if always {
            rate.record(at: t)
            return true
        }
        guard rate.admit(at: t) else {
            dropped += 1
            return false
        }
        return true
    }

    /// Where the pointer is: the last point posted, fractions kept, while the real cursor is
    /// still at it or at the one before (so fractions of a point add up across moves); else the
    /// real cursor, so the user's own mouse wins.
    private func current() -> CGPoint {
        let real = poster.location()
        guard let posted else { return real }
        func near(_ p: CGPoint) -> Bool {
            abs(real.x - p.x) <= Self.ownCursorSlack && abs(real.y - p.y) <= Self.ownCursorSlack
        }
        if near(posted.last) { return posted.last }
        if let previous = posted.previous, near(previous) { return posted.last }
        return real
    }

    private func move(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite else { return }
        let from = current()
        let to = PointerMath.clamp(CGPoint(x: from.x + CGFloat(dx), y: from.y + CGFloat(dy)), to: poster.screens())
        poster.move(to: to, holding: held?.button, clickCount: held?.count ?? 0)
        posted = (to, posted?.last)
        if laserOn { laser.show(at: to) }
    }

    private func button(_ b: AMMouseButton, down: Bool) {
        guard b == .left || b == .right else { return }
        let p = current()
        if down {
            // One button at a time: a different one held is let go first.
            if let h = held, h.button != b { release(at: p, byPhone: false) }
            // The same one again is the phone's keepalive (R35): admit() stamped it; nothing else.
            guard held == nil else { return }
            let count = pressCount(b, at: p)
            poster.button(b, down: true, at: p, clickCount: count)
            held = (b, count)
        } else {
            // An up for a button not held (released here already, or never pressed) posts nothing.
            guard held?.button == b else { return }
            release(at: p, byPhone: true)
        }
        updateLoops()
    }

    private func click(_ b: AMMouseButton, count: Int) {
        guard b == .left || b == .right else { return }
        let p = current()
        // A click while a button is held: let go of the held one first.
        if held != nil {
            release(at: p, byPhone: false)
            updateLoops()
        }
        let n = min(max(count, 1), 3)
        poster.button(b, down: true, at: p, clickCount: n)
        poster.button(b, down: false, at: p, clickCount: n)
        lastRelease = (b, now(), p, n)
    }

    private func scroll(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite else { return }
        let sign: Float = naturalScrolling() ? 1 : -1
        let wantX = scrollResidual.x + dx * sign
        let wantY = scrollResidual.y + dy * sign
        let x = Self.pixels(wantX)
        let y = Self.pixels(wantY)
        // Whatever rounding leaves goes with the next scroll; a huge one is not carried.
        scrollResidual = (abs(wantX) < 10_000 ? wantX - Float(x) : 0, abs(wantY) < 10_000 ? wantY - Float(y) : 0)
        guard x != 0 || y != 0 else { return }
        poster.scroll(pixelsX: x, pixelsY: y)
    }

    /// The click state of a press: one more than the last release when it is the same button,
    /// soon enough and close enough (a double-tap-and-hold drags with 2); else 1.
    private func pressCount(_ b: AMMouseButton, at p: CGPoint) -> Int {
        guard let last = lastRelease, last.button == b,
              now() - last.at <= doubleClickInterval,
              abs(last.point.x - p.x) <= Self.multiClickDistance, abs(last.point.y - p.y) <= Self.multiClickDistance
        else { return 1 }
        return min(last.count + 1, 3)
    }

    /// Only the phone's own up can start a double click: a release this Mac forces cannot.
    private func release(at p: CGPoint, byPhone: Bool) {
        guard let h = held else { return }
        poster.button(h.button, down: false, at: p, clickCount: h.count)
        held = nil
        lastRelease = byPhone ? (h.button, now(), p, h.count) : nil
    }

    /// Lets go of the held button and hides the laser.
    private func releaseAll() {
        if held != nil { release(at: current(), byPhone: false) }
        if laserOn {
            laserOn = false
            laser.hide()
        }
        updateLoops()
    }

    private static func pixels(_ v: Float) -> Int32 {
        Int32(max(-10_000, min(10_000, v.rounded())))
    }

    // MARK: session

    private func endSession() {
        releaseAll()
        if dropped > 0 { Self.log.notice("dropped \(self.dropped, privacy: .public) frames over the rate limit") }
        phoneID = nil
        lastFrameAt = nil
        rate = RateWindow()
        posted = nil
        scrollResidual = (0, 0)
        lastRelease = nil
        dropped = 0
        lastSentAvailability = nil
        updateLoops()
    }

    /// The 1 s release timer runs while a button is held or the laser is on; the 2 s
    /// Accessibility check while the setting is on and a phone is in session.
    private func updateLoops() {
        let sleep = sleep
        if held != nil || laserOn, phoneID != nil {
            if tickTask == nil {
                tickTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await sleep(.seconds(1))
                        guard !Task.isCancelled, let self else { return }
                        self.tick()
                    }
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
        if enabled, phoneID != nil {
            if trustTask == nil {
                trustTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await sleep(.seconds(2))
                        guard !Task.isCancelled, let self else { return }
                        await self.recheckTrust()
                    }
                }
            }
        } else {
            trustTask?.cancel()
            trustTask = nil
        }
    }

    /// Sends this Mac's availability when it differs from the last one sent this session.
    private func sendAvailability() async {
        guard phoneID != nil else { return }
        let a = availability
        guard a != lastSentAvailability else { return }
        lastSentAvailability = a
        await send(.inputAvailability, a)
    }
}
