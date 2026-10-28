import AMProtocol
import Foundation

/// Hands the phone's `notify.*` messages to the model. Everything else is left to the caller.
public enum NotifyRouter {
    /// Returns true when the envelope was a notify message from the phone (even one that did not decode).
    @MainActor
    public static func route(_ e: AMEnvelope, to m: NotificationsModel) async -> Bool {
        switch e.type {
        case MessageType.notifyPosted.rawValue:
            if let n = try? AMPhoneNotification(serializedBytes: e.payload) { await m.posted(n) }
        case MessageType.notifyRemoved.rawValue:
            if let r = try? AMNotificationRemoved(serializedBytes: e.payload) { m.removed(r) }
        case MessageType.notifySnapshot.rawValue:
            if let s = try? AMActiveNotifications(serializedBytes: e.payload) { await m.snapshot(s) }
        case MessageType.notifyResult.rawValue:
            if let r = try? AMActionResult(serializedBytes: e.payload) { await m.result(r) }
        case MessageType.notifyIcon.rawValue:
            if let i = try? AMAppIcon(serializedBytes: e.payload) { m.icon(i) }
        case MessageType.notifyAvailability.rawValue:
            if let a = try? AMFeatureAvailability(serializedBytes: e.payload) { m.availability(a) }
        default:
            return false
        }
        return true
    }
}
