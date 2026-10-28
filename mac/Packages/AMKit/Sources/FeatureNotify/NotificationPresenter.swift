import Foundation
import UserNotifications

/// The slice of UNUserNotificationCenter the model needs. The real adapter lives in the app; tests use a fake.
@MainActor
public protocol NotificationPresenter: AnyObject {
    /// Asks for permission (once) and returns whether notifications may be shown.
    func authorize() async -> Bool
    /// Replaces the registered categories with exactly this set.
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// Shows the notification, or replaces the one already shown under the same id.
    func deliver(id: String, content: UNNotificationContent) async throws
    func remove(ids: [String])
    func deliveredIDs() async -> [String]
}
