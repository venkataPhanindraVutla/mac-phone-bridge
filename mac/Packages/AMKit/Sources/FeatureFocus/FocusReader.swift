import Foundation
import Intents

/// Whether this app may read Focus status.
public enum FocusAuthorization: Equatable, Sendable {
    case authorized, denied, notDetermined
    /// This build can't read Focus status (no `INFocusStatusCenter`, or the entitlement is missing).
    case unavailable
}

/// The Mac's Focus status.
@MainActor
public protocol FocusReader: AnyObject {
    var authorization: FocusAuthorization { get }
    /// Asks the user, when macOS still can. Called only when the Focus setting is turned on.
    func requestAuthorization() async -> FocusAuthorization
    /// Whether any Focus is on; nil when unknown (not authorized, or macOS doesn't say).
    func isFocused() -> Bool?
}

/// Focus status from `INFocusStatusCenter.default`.
///
/// A build that can't use it (the class is missing, or the entitlement is: macOS then reports
/// `.restricted`) reads as `.unavailable`, and Settings says so. Whether the ad-hoc signed
/// Contributor build can read Focus status at all is an owner check.
///
/// Intents calls the authorization completion on a queue of its own, so that closure is made in
/// a `nonisolated` helper: one formed in this main-actor class would be main-actor isolated, and
/// Swift 6 traps when it runs anywhere else.
@MainActor
public final class SystemFocusReader: FocusReader {
    public init() {}

    private static var isPresent: Bool { NSClassFromString("INFocusStatusCenter") != nil }

    public var authorization: FocusAuthorization {
        guard Self.isPresent else { return .unavailable }
        return Self.map(INFocusStatusCenter.default.authorizationStatus)
    }

    public func requestAuthorization() async -> FocusAuthorization {
        guard Self.isPresent else { return .unavailable }
        return Self.map(await Self.request())
    }

    public func isFocused() -> Bool? {
        guard authorization == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    nonisolated static func map(_ status: INFocusStatusAuthorizationStatus) -> FocusAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    /// The completion handed to Intents, safe on any thread.
    nonisolated static func completion(
        _ continuation: CheckedContinuation<INFocusStatusAuthorizationStatus, Never>
    ) -> @Sendable (INFocusStatusAuthorizationStatus) -> Void {
        { status in continuation.resume(returning: status) }
    }

    nonisolated private static func request() async -> INFocusStatusAuthorizationStatus {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization(completionHandler: completion(continuation))
        }
    }
}
