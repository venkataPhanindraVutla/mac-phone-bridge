import AMProtocol
import ConnectionCore
import Foundation
import Observation
import SwiftProtobuf

/// Focus on this Mac and Do Not Disturb on the phone, kept in step while the phone shares `dnd.v1`
/// and the "Sync Focus" setting is on (SPEC section 21).
///
/// - **Mac to phone:** the Mac's Focus is read every `pollInterval` while connected, enabled and
///   authorized. A transition goes through `EchoGuard` and is sent only while the phone's last
///   `applies` is enabled (ruling R22: nil is off). One `snapshot` goes on connect.
/// - **Phone to Mac:** a `USER` transition that is not a snapshot runs the "Mac Phone Bridge
///   Focus On" or "Off" shortcut, when both are installed and the Mac's Focus differs (or will,
///   once the runs already asked for are done). The shortcut runs detached: `message` returns at
///   once, so the ordered queue never waits on it. One run at a time: a request that arrives
///   meanwhile waits, and a later one replaces it, so the phone's latest state is the last run.
///
/// Authorization is asked for only in `setEnabled(true)`. Nothing about the Focus or the
/// shortcuts' output is logged.
@MainActor
@Observable
public final class FocusModel: SessionFeature {
    nonisolated public static let onShortcut = "Mac Phone Bridge Focus On"
    nonisolated public static let offShortcut = "Mac Phone Bridge Focus Off"

    public let messagePrefixes = ["dnd."]

    /// The "Sync Focus" setting.
    public private(set) var enabled: Bool
    /// Whether both shortcuts are installed; nil until checked. Kept across sessions.
    public private(set) var shortcutsInstalled: Bool?
    /// The Mac's Focus as last read; nil when unknown or not being read.
    public private(set) var macFocused: Bool?
    /// The phone's last `dnd.state` this session.
    public private(set) var phoneOn: Bool?
    /// The phone's last `dnd.availability` this session.
    public private(set) var phoneAvailability: AMDndAvailability?
    /// The last shortcut run failed or timed out.
    public private(set) var lastRunFailed = false
    /// Focus status access, as last read.
    public private(set) var authorization: FocusAuthorization

    /// This Mac's `dnd.availability`.
    public var availability: AMDndAvailability {
        var a = AMDndAvailability()
        a.sends = Self.feature(
            !enabled ? .offByUser
                : authorization == .unavailable ? .unavailable
                : authorization == .authorized ? nil : .needsPermission)
        a.applies = Self.feature(!enabled ? .offByUser : shortcutsInstalled == true ? nil : .needsSetup)
        return a
    }

    @ObservationIgnored private let reader: any FocusReader
    @ObservationIgnored private let shortcuts: any ShortcutRunner
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: () -> Date
    /// The phone in session, while it shares `dnd.v1`.
    @ObservationIgnored private var phoneID: String?
    /// Bumped on every connect, disconnect and switch-off, so a late shortcut result is dropped.
    @ObservationIgnored private var session = 0
    /// Bumped on every `setEnabled`, so a call still waiting stops once a later one has run.
    @ObservationIgnored private var enableCall = 0
    @ObservationIgnored private(set) var echo = EchoGuard()
    /// The run in flight: the state its shortcut turns Focus to, and whether a poll has seen
    /// Focus reach it. The first sight is our own doing, not the user's.
    @ObservationIgnored private var applying: (on: Bool, seen: Bool)?
    /// The state to run next, once the run in flight returns; the latest request replaces it.
    @ObservationIgnored private var pending: Bool?
    @ObservationIgnored private var lastSentAvailability: AMDndAvailability?
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?
    /// How the poll loop waits between reads (internal, so tests can tick it by hand).
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The last shortcut run and the last shortcut check (internal, for tests).
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var shortcutCheck: Task<Void, Never>?

    public init(reader: any FocusReader, shortcuts: any ShortcutRunner, enabled: Bool,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                pollInterval: Duration = .seconds(2), now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.shortcuts = shortcuts
        self.enabled = enabled
        self.send = send
        self.pollInterval = pollInterval
        self.now = now
        authorization = reader.authorization
    }

    /// Whether the Focus is being read (internal, for tests).
    var isPolling: Bool { pollTask != nil }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        reset()
        guard shared.contains("dnd.v1") else { return }
        self.phoneID = phoneID
        authorization = reader.authorization
        if enabled, authorization == .authorized { macFocused = reader.isFocused() }
        await sendAvailability()
        if availability.sends.enabled, let on = macFocused {
            await send(.dndState, Self.state(on, origin: .user, snapshot: true))
        }
        updatePolling()
        // Off the queue: `shortcuts list` is a subprocess.
        if enabled { shortcutCheck = Task { [weak self] in await self?.checkShortcuts() } }
    }

    public func disconnected() {
        phoneID = nil
        reset()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phoneID != nil else { return }
        switch MessageType(rawValue: envelope.type) {
        case .dndState:
            guard let s = try? AMDndState(serializedBytes: envelope.payload) else { return }
            phoneOn = s.on
            guard enabled, !s.snapshot, s.origin == .user, shortcutsInstalled == true else { return }
            // Compared with where the runs already asked for leave Focus, not with the last read.
            guard (pending ?? applying?.on ?? macFocused) != s.on else { return }
            if applying == nil { apply(s.on) } else { pending = s.on }
        case .dndAvailability:
            guard let a = try? AMDndAvailability(serializedBytes: envelope.payload) else { return }
            phoneAvailability = a
        default:
            break
        }
    }

    public func forget(phoneID: String) async {
        guard self.phoneID == nil || self.phoneID == phoneID else { return }
        self.phoneID = nil
        reset()
    }

    // MARK: Focus

    /// The setting. Turning it on asks for Focus status access (the only place that does) and
    /// checks the shortcuts.
    ///
    /// The last call wins: one still waiting (on the access prompt, say) stops once a later call
    /// has changed the setting.
    public func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        enabled = on
        enableCall += 1
        let call = enableCall
        if !on {
            // A shortcut still running belongs to the old setting: its result is dropped.
            session += 1
            macFocused = nil
            echo = EchoGuard()
            applying = nil
            pending = nil
            updatePolling()
            await sendAvailability()
            return
        }
        await sendAvailability()
        guard call == enableCall else { return }
        if authorization != .authorized, authorization != .unavailable {
            let granted = await reader.requestAuthorization()
            guard call == enableCall else { return }
            authorization = granted
            await sendAvailability()
            guard call == enableCall else { return }
        }
        if phoneID != nil, authorization == .authorized { macFocused = reader.isFocused() }
        updatePolling()
        await checkShortcuts()
    }

    /// Looks for the two shortcuts ("Check Again", enable and connect). `shortcuts list` runs
    /// off the main actor.
    public func checkShortcuts() async {
        let shortcuts = shortcuts
        let names = await Task.detached { await shortcuts.list() }.value
        shortcutsInstalled = names.map { $0.contains(Self.onShortcut) && $0.contains(Self.offShortcut) } ?? false
        lastRunFailed = false
        await sendAvailability()
    }

    /// Reads the authorization again, e.g. when Settings opens after a change in System Settings.
    public func refreshAuthorization() async {
        let current = reader.authorization
        guard current != authorization else { return }
        authorization = current
        if phoneID != nil, enabled, current == .authorized { macFocused = reader.isFocused() }
        updatePolling()
        await sendAvailability()
    }

    /// One read of the Mac's Focus; the poll loop calls it every `pollInterval`.
    public func poll() async {
        guard phoneID != nil, enabled else { return }
        let current = reader.authorization
        if current != authorization {
            authorization = current
            updatePolling()
            await sendAvailability()
        }
        guard authorization == .authorized, let on = reader.isFocused(), on != macFocused else { return }
        let previous = macFocused
        macFocused = on
        // The first value read is where we start, not a transition.
        guard previous != nil else { return }
        if let run = applying, run.on == on, !run.seen {
            // The running shortcut did this. Only its first sight: later ones are the user's.
            applying?.seen = true
            return
        }
        let kind = echo.classify(on, at: now())
        guard kind != .suppress, phoneAvailability?.applies.enabled == true else { return }
        await send(.dndState, Self.state(on, origin: kind == .sync ? .sync : .user, snapshot: false))
    }

    // MARK: private

    private func apply(_ on: Bool) {
        let shortcuts = shortcuts
        let name = on ? Self.onShortcut : Self.offShortcut
        let session = session
        applying = (on, false)
        runTask = Task.detached { [weak self] in
            let result = await shortcuts.run(name)
            await self?.ran(on, result, session: session)
        }
    }

    /// A run returned. Its state is remembered for the echo guard unless a poll already saw
    /// Focus reach it (that sight was the echo). Then the waiting request runs, if it differs.
    private func ran(_ on: Bool, _ result: ShortcutRunResult, session: Int) {
        guard session == self.session else { return }
        let seen = applying?.seen ?? false
        applying = nil
        if result == .ok {
            if !seen { echo.applied(on, at: now()) }
            lastRunFailed = false
        } else {
            lastRunFailed = true
        }
        if let next = pending {
            pending = nil
            if next != on { apply(next) }
        }
    }

    private func updatePolling() {
        let should = phoneID != nil && enabled && authorization == .authorized
        if should, pollTask == nil {
            let interval = pollInterval
            let sleep = sleep
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await sleep(interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.poll()
                }
            }
        } else if !should, let task = pollTask {
            task.cancel()
            pollTask = nil
        }
    }

    /// Sends this Mac's availability when it differs from the last one sent this session.
    private func sendAvailability() async {
        guard phoneID != nil else { return }
        let a = availability
        guard a != lastSentAvailability else { return }
        lastSentAvailability = a
        await send(.dndAvailability, a)
    }

    private func reset() {
        session += 1
        pollTask?.cancel()
        pollTask = nil
        phoneAvailability = nil
        phoneOn = nil
        macFocused = nil
        echo = EchoGuard()
        applying = nil
        pending = nil
        lastSentAvailability = nil
    }

    private static func feature(_ off: AMAvailabilityReason?) -> AMFeatureAvailability {
        var f = AMFeatureAvailability()
        f.enabled = off == nil
        f.reason = off ?? .unspecified
        return f
    }

    private static func state(_ on: Bool, origin: AMDndOrigin, snapshot: Bool) -> AMDndState {
        var s = AMDndState()
        s.on = on
        s.origin = origin
        s.snapshot = snapshot
        return s
    }
}
