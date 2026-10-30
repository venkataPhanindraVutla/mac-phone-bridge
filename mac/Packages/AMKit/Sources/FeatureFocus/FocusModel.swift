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
/// - **Phone to Mac:** a `USER` transition that is not a snapshot runs the "Android Mirroring
///   Focus On" or "Off" shortcut, when both are installed and the Mac's Focus differs. The
///   shortcut runs detached: `message` returns at once, so the ordered queue never waits on it.
///
/// Authorization is asked for only in `setEnabled(true)`. Nothing about the Focus or the
/// shortcuts' output is logged.
@MainActor
@Observable
public final class FocusModel: SessionFeature {
    nonisolated public static let onShortcut = "Android Mirroring Focus On"
    nonisolated public static let offShortcut = "Android Mirroring Focus Off"

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
    /// Bumped on every connect and disconnect, so a late shortcut result is dropped.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var echo = EchoGuard()
    /// The state a running shortcut is turning Focus to: seeing it is our own doing, not the user's.
    @ObservationIgnored private var applying: Bool?
    @ObservationIgnored private var lastSentAvailability: AMDndAvailability?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
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
            guard enabled, !s.snapshot, s.origin == .user, shortcutsInstalled == true, macFocused != s.on else { return }
            apply(s.on)
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
    public func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        enabled = on
        if !on {
            macFocused = nil
            echo = EchoGuard()
            applying = nil
            updatePolling()
            await sendAvailability()
            return
        }
        await sendAvailability()
        if authorization != .authorized, authorization != .unavailable {
            let granted = await reader.requestAuthorization()
            guard enabled else { return }
            authorization = granted
            await sendAvailability()
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
        if applying == on {
            // A running shortcut did this; its result is recorded when it returns.
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
        applying = on
        runTask = Task.detached { [weak self] in
            let result = await shortcuts.run(name)
            await self?.ran(on, result, session: session)
        }
    }

    private func ran(_ on: Bool, _ result: ShortcutRunResult, session: Int) {
        guard session == self.session else { return }
        if applying == on { applying = nil }
        if result == .ok {
            echo.applied(on, at: now())
            lastRunFailed = false
        } else {
            lastRunFailed = true
        }
    }

    private func updatePolling() {
        let should = phoneID != nil && enabled && authorization == .authorized
        if should, pollTask == nil {
            let interval = pollInterval
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
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
