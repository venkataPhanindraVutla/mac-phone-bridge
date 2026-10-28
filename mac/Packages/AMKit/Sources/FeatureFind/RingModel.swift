import AMProtocol
import ConnectionCore
import Foundation
import Observation

/// What the Mac knows about the phone ringing. Strings are looked up in the main bundle (the app's
/// Localizable.xcstrings); where there is none, as in package tests, the English default is used.
@MainActor
@Observable
public final class RingModel {
    public private(set) var ringing = false
    /// The phone is ringing but cannot override Total silence (no Do Not Disturb access).
    public private(set) var mayBeSilent = false
    /// The connection dropped while ringing: the phone may well still be ringing.
    public private(set) var possiblyStillRinging = false

    public init() {}

    /// The menu item's title.
    public var menuTitle: String {
        ringing
            ? String(localized: "Stop ringing", bundle: .main)
            : String(localized: "Ring phone", bundle: .main)
    }

    /// A line under the menu item, or nil.
    public var note: String? {
        if mayBeSilent {
            return String(localized: "The phone may be silent. Allow Do Not Disturb access in the phone app.", bundle: .main)
        }
        if possiblyStillRinging {
            return String(localized: "Phone may still be ringing. Stop it on the phone.", bundle: .main)
        }
        return nil
    }

    /// Sends `find.ring`, or `find.stop` while ringing.
    public func toggle(using server: MacServer) async {
        do {
            if ringing {
                try await server.send(.findStop, AMStopRingRequest(), channel: .find)
            } else {
                try await server.send(.findRing, AMRingRequest(), channel: .find)
            }
        } catch {
            // Not connected: the menu item is hidden then; nothing to do.
        }
    }

    public func apply(_ state: AMRingState) {
        ringing = state.ringing
        mayBeSilent = state.ringing && state.mayBeSilent
        possiblyStillRinging = false
    }

    /// On disconnect. A phone that was ringing may keep ringing; we cannot know. The next
    /// RingState (or `clearHint()` on a reconnect) clears the hint.
    public func reset() {
        possiblyStillRinging = ringing
        ringing = false
        mayBeSilent = false
    }

    /// On (re)connect: the phone reports again if it is still ringing.
    public func clearHint() { possiblyStillRinging = false }
}
