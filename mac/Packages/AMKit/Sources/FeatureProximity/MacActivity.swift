import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// What the Mac is doing: whether someone is using it, and whether its screen is locked or asleep.
@MainActor
public protocol MacActivity: AnyObject {
    /// Seconds since the last keyboard, mouse or trackpad input.
    func idleSeconds() -> TimeInterval
    var screenLocked: Bool { get }
    var asleep: Bool { get }
    /// Some process keeps the screen from idle sleep: a video call, video playback, a presentation.
    var screenKeptAwake: Bool { get }
    /// Called on the main actor when the Mac or its screens wake.
    var onWake: (() -> Void)? { get set }
}

/// The Mac's activity from CoreGraphics and NSWorkspace.
///
/// The sleep and wake observers are made in a `nonisolated` helper: a closure formed in this
/// main-actor class would be main-actor isolated, and Swift 6 traps if it ever runs off the main
/// thread. They hop to the main queue themselves.
@MainActor
public final class SystemMacActivity: MacActivity {
    public private(set) var asleep = false
    public var onWake: (() -> Void)?
    /// Kept for the life of the process; they hold this object weakly.
    private var observers: [NSObjectProtocol] = []

    /// `center` is for tests.
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers = Self.observe(center, activity: self)
    }

    public func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Also true when this user's session isn't on the console (another user is switched in), or
    /// there's no session to ask about: locking makes no sense then.
    public var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    /// Any `PreventUserIdleDisplaySleep` or `NoDisplaySleepAssertion` power assertion, from any
    /// process. If the status can't be read, it reads as kept awake.
    public var screenKeptAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let counts = status?.takeRetainedValue() as? [String: Any] else { return true }
        return Self.keepsScreenAwake(counts.compactMapValues { ($0 as? NSNumber)?.intValue })
    }

    /// Whether assertion counts by type include one that keeps the screen awake.
    nonisolated static func keepsScreenAwake(_ counts: [String: Int]) -> Bool {
        [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypeNoDisplaySleep]
            .contains { (counts[$0] ?? 0) > 0 }
    }

    /// Every wake notification counts, even one whose sleep went unseen: a reset is harmless.
    private func setAsleep(_ value: Bool) {
        asleep = value
        if !value { onWake?() }
    }

    nonisolated private static func observe(_ center: NotificationCenter, activity: SystemMacActivity) -> [NSObjectProtocol] {
        let sleeps = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification]
        let wakes = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification]
        func observer(_ name: Notification.Name, asleep: Bool) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak activity] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { activity?.setAsleep(asleep) }
                }
            }
        }
        return sleeps.map { observer($0, asleep: true) } + wakes.map { observer($0, asleep: false) }
    }
}
