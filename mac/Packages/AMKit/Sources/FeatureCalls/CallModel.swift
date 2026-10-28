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

    /// Incoming calls that are ringing, newest last. Drives the panels.
    public private(set) var ringing: [AMCallState] = []
    public private(set) var active: AMCallState?
    public private(set) var lastError: CallError?
    /// The "Show phone calls" switch. Off: call states and missed calls are ignored.
    public var enabled: Bool = true {
        didSet { if !enabled { reset() } }
    }

    @ObservationIgnored private let nameFor: (String) -> String?
    @ObservationIgnored private let presenter: NotificationPresenter
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var phoneID: String?
    /// Calls whose panel the user closed with "Close"; they stay closed until the call ends.
    @ObservationIgnored private var closed: Set<String> = []

    public init(
        nameFor: @escaping (String) -> String?, presenter: NotificationPresenter,
        send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.nameFor = nameFor
        self.presenter = presenter
        self.send = send
        self.now = now
    }

    // MARK: Connection

    public func connected(phoneID: String) { self.phoneID = phoneID }

    /// On disconnect: nothing of the call survives.
    public func reset() {
        ringing = []
        active = nil
        lastError = nil
        closed = []
    }

    public func disconnected() {
        reset()
        phoneID = nil
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
    public func elapsed(now: Date) -> String? {
        guard let active else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(active.sinceMs) / 1000)
        let total = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `elapsed(now:)` at the model's clock.
    public func elapsed() -> String? { elapsed(now: now()) }

    // MARK: From the phone

    public func apply(_ s: AMCallState) {
        guard enabled else { return }
        switch s.phase {
        case .ringing where s.incoming:
            guard !closed.contains(s.callID) else { return }
            if let i = ringing.firstIndex(where: { $0.callID == s.callID }) {
                ringing[i] = s
            } else {
                ringing.append(s)
            }
        case .ringing, .active:
            // An outgoing call that is still ringing is shown like an active one: the menu offers Hang up.
            ringing.removeAll { $0.callID == s.callID }
            active = s
        case .ended:
            ringing.removeAll { $0.callID == s.callID }
            closed.remove(s.callID)
            if active?.callID == s.callID { active = nil }
        default:
            break
        }
    }

    public func result(_ r: AMCallCommandResult) {
        switch r.outcome {
        case .ok:
            lastError = nil
        case .noSuchCall:
            lastError = .noSuchCall
            ringing.removeAll { $0.callID == r.callID }
            if active?.callID == r.callID { active = nil }
        case .notAllowed:
            lastError = .notAllowed
        case .failed:
            lastError = .failed
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
        ringing.removeAll { $0.callID == id }
    }

    private func command(_ action: AMCallAction, _ id: String) async {
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
