import AMProtocol
import FeatureNotify
import Foundation
import Observation
import os
import SwiftProtobuf
import UserNotifications

public enum CallError: Error, Equatable, Sendable {
    case noSuchCall, notAllowed, failed
}

/// What a ringing call's panel offers.
public enum CallPanelAction: Equatable, Sendable {
    case answer, decline
    /// Local only: closes the panel. For a call waiting behind an active one, which the phone cannot answer.
    case close
}

/// Phone calls on the Mac: incoming calls for the panel, the active call for the menu, missed calls as notifications.
@MainActor
@Observable
public final class CallModel {
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "calls")

    /// Incoming calls that are ringing, newest last. Drives the panels. Empty while the switch is off.
    public var ringing: [AMCallState] { enabled ? trackedRinging : [] }
    public var active: AMCallState? { enabled ? trackedActive : nil }
    /// "02:13" for the active call, refreshed every second while a call is active; nil otherwise. The menu reads this.
    public var elapsedText: String? { enabled ? trackedElapsedText : nil }
    public private(set) var lastError: CallError?
    /// The "Show phone calls" switch. Off: nothing shows and missed calls are ignored, but call states are
    /// still followed, so switching it on mid-call shows the call.
    public var enabled: Bool = true {
        didSet { if !enabled { lastError = nil; failure = nil } }
    }
    /// A short line for a refused Answer, Decline, Mute or Hang up on call `id`; nil when there is
    /// nothing to say. It goes when the call ends, is closed or is gone, and never shows on another call.
    public func errorMessage(for id: String) -> String? {
        guard enabled, let failure, failure.callID == id else { return nil }
        switch failure.action {
        case .answer: return String(localized: "Couldn't answer on the phone.", bundle: .main)
        case .decline: return String(localized: "Couldn't decline on the phone.", bundle: .main)
        default: return String(localized: "Couldn't do that on the phone.", bundle: .main)
        }
    }

    private var trackedRinging: [AMCallState] = []
    private var trackedActive: AMCallState?
    /// The refused command's call and action, for the message.
    private var failure: (callID: String, action: AMCallAction)?
    private var trackedElapsedText: String?

    @ObservationIgnored private let nameFor: (String) -> String?
    @ObservationIgnored private let presenter: NotificationPresenter
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let ticker: @Sendable () async -> Void
    /// The Mac's own time when the active call was first seen active (never the phone's clock).
    @ObservationIgnored private var activeSince: Date?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var phoneID: String?
    @ObservationIgnored private var lastAction: AMCallAction?
    /// The call that was active when the phone disconnected, so a reconnect mid-call keeps its timer
    /// (the phone keeps call ids).
    @ObservationIgnored private var resumable: (callID: String, since: Date)?
    /// Calls whose panel the user closed with "Close"; they stay closed until the call ends.
    @ObservationIgnored private var closed: Set<String> = []

    public init(
        nameFor: @escaping (String) -> String?, presenter: NotificationPresenter,
        send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
        now: @escaping () -> Date = Date.init,
        ticker: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.ticker = ticker
        self.nameFor = nameFor
        self.presenter = presenter
        self.send = send
        self.now = now
    }

    // MARK: Connection

    public func connected(phoneID: String) {
        if phoneID != self.phoneID { resumable = nil }
        self.phoneID = phoneID
    }

    /// On disconnect: nothing of the call survives.
    public func reset() {
        trackedRinging = []
        setActive(nil)
        lastError = nil
        failure = nil
        closed = []
    }

    public func disconnected() {
        let remembered = trackedActive.flatMap { call in activeSince.map { (callID: call.callID, since: $0) } }
        reset()
        resumable = remembered ?? resumable
        // The phone id is kept, so reconnecting to the same phone resumes the timer.
    }

    // MARK: Display

    /// Contact name, else the phone's name for the caller, else the number, else "Unknown".
    public func displayName(_ c: AMCallState) -> String {
        Self.name(number: c.number, phoneName: c.displayName, contact: nameFor)
    }

    private static func name(number: String, phoneName: String, contact: (String) -> String?) -> String {
        if !number.isEmpty, let name = contact(number), !name.isEmpty { return name }
        if !phoneName.isEmpty { return phoneName }
        if !number.isEmpty { return number }
        return String(localized: "Unknown", bundle: .main)
    }

    /// The buttons a ringing call's panel shows.
    public func actions(for c: AMCallState) -> [CallPanelAction] {
        c.canAnswer ? [.answer, .decline] : [.close]
    }

    /// "02:13" for the active call, "1:02:05" past an hour; nil when no call is active.
    /// Measured on the Mac's clock from when the call was first seen active.
    public func elapsed(now: Date) -> String? {
        guard trackedActive != nil, let activeSince else { return nil }
        let total = max(0, Int(now.timeIntervalSince(activeSince)))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Keeps `active` and its timer together: a tick loop runs only while a call is active.
    private func setActive(_ s: AMCallState?) {
        if s?.callID != trackedActive?.callID {
            if let s {
                if let resumable, resumable.callID == s.callID { activeSince = resumable.since } else { activeSince = now() }
                resumable = nil
            } else {
                activeSince = nil
            }
        }
        trackedActive = s
        guard s != nil else {
            tickTask?.cancel()
            tickTask = nil
            trackedElapsedText = nil
            return
        }
        trackedElapsedText = elapsed(now: now())
        guard tickTask == nil else { return }
        let ticker = ticker
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await ticker()
                if Task.isCancelled { break }
                guard let self else { return }
                self.trackedElapsedText = self.elapsed(now: self.now())
            }
        }
    }

    // MARK: From the phone

    public func apply(_ s: AMCallState) {
        switch s.phase {
        case .ringing where s.incoming:
            guard !closed.contains(s.callID) else { return }
            if let i = trackedRinging.firstIndex(where: { $0.callID == s.callID }) {
                trackedRinging[i] = s
            } else {
                trackedRinging.append(s)
            }
        case .ringing, .active:
            // An outgoing call that is still ringing is shown like an active one: the menu offers Hang up.
            trackedRinging.removeAll { $0.callID == s.callID }
            setActive(s)
        case .ended:
            trackedRinging.removeAll { $0.callID == s.callID }
            closed.remove(s.callID)
            if failure?.callID == s.callID { failure = nil }
            if resumable?.callID == s.callID { resumable = nil }
            if trackedActive?.callID == s.callID { setActive(nil) }
        default:
            break
        }
    }

    public func result(_ r: AMCallCommandResult) {
        switch r.outcome {
        case .ok:
            lastError = nil
            if failure?.callID == r.callID { failure = nil }
        case .noSuchCall:
            lastError = .noSuchCall
            if failure?.callID == r.callID { failure = nil }
            trackedRinging.removeAll { $0.callID == r.callID }
            if trackedActive?.callID == r.callID { setActive(nil) }
        case .notAllowed:
            lastError = .notAllowed
            failure = (r.callID, lastAction ?? .UNRECOGNIZED(0))
        case .failed:
            lastError = .failed
            failure = (r.callID, lastAction ?? .UNRECOGNIZED(0))
        default:
            break
        }
    }

    /// A plain notification: categories belong to `CategoryRegistry`, so none is set here.
    public func missed(_ m: AMMissedCall) async {
        guard enabled, let phoneID else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Missed call", bundle: .main)
        content.subtitle = Self.name(number: m.number, phoneName: m.displayName, contact: nameFor)
        content.body = m.number
        do { try await presenter.deliver(id: "m|" + phoneID + "|" + String(m.atMs), content: content) } catch {
            Self.log.error("deliver of the missed call failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: From the user

    public func answer(_ id: String) async {
        guard ringing.contains(where: { $0.callID == id && $0.canAnswer }) else { return }
        await command(.answer, id)
    }

    public func decline(_ id: String) async {
        guard ringing.contains(where: { $0.callID == id && $0.canAnswer }) else { return }
        await command(.decline, id)
    }

    public func hangUp() async {
        guard let active else { return }
        await command(.hangUp, active.callID)
    }

    public func toggleMute() async {
        guard let active, active.muteSupported else { return }
        await command(active.muted ? .unmute : .mute, active.callID)
    }

    /// Closes a panel on this Mac only; the phone keeps ringing.
    public func close(_ id: String) {
        closed.insert(id)
        if failure?.callID == id { failure = nil }
        trackedRinging.removeAll { $0.callID == id }
    }

    private func command(_ action: AMCallAction, _ id: String) async {
        lastError = nil
        failure = nil
        lastAction = action
        var c = AMCallCommand()
        c.callID = id
        c.action = action
        await send(.callsCommand, c)
    }

    // MARK: Routing

    /// Handles a `calls.*` message from the phone. Returns false for any other type.
    @discardableResult
    public func route(_ e: AMEnvelope) async -> Bool {
        switch e.type {
        case MessageType.callsState.rawValue:
            if let s = try? AMCallState(serializedBytes: e.payload) { apply(s) }
        case MessageType.callsResult.rawValue:
            if let r = try? AMCallCommandResult(serializedBytes: e.payload) { result(r) }
        case MessageType.callsMissed.rawValue:
            if let m = try? AMMissedCall(serializedBytes: e.payload) { await missed(m) }
        case MessageType.callsAvailability.rawValue:
            break
        default:
            return false
        }
        return true
    }
}
