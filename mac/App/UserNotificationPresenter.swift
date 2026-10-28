import FeatureNotify
import Foundation
@preconcurrency import UserNotifications

/// The real notification centre behind `NotificationPresenter`. It is the centre's delegate: banners
/// show while the app is active, and the user's clicks, replies and dismissals go to `onResponse`.
/// `CategoryRegistry` owns the whole category set, so categories are set only through `setCategories`.
@MainActor
final class UserNotificationPresenter: NSObject, NotificationPresenter, UNUserNotificationCenterDelegate {
    /// (actionID, userInfo, reply text). Set by the app once the model exists.
    var onResponse: ((String, [AnyHashable: Any], String?) async -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func deliver(id: String, content: UNNotificationContent) async throws {
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func deliveredIDs() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await self.onResponse?(actionID, userInfo, reply)
            done()
        }
    }
}
