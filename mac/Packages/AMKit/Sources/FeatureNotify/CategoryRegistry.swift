import AMProtocol
import CryptoKit
import Foundation
import UserNotifications

/// Notification categories carry the action buttons. Identical button sets share one category; the
/// registry keeps at most 64, least recently used first out, and re-registers the whole set on change.
@MainActor
public final class CategoryRegistry {
    public static let capacity = 64
    public static let copyActionID = "copy"

    private let apply: (Set<UNNotificationCategory>) -> Void
    private var order: [String] = []                       // least recently used first
    private var categories: [String: UNNotificationCategory] = [:]

    public init(apply: @escaping (Set<UNNotificationCategory>) -> Void) { self.apply = apply }

    public var count: Int { categories.count }

    public static func actionID(index: UInt32) -> String { "a|\(index)" }

    /// The id of a category with these buttons, registering it if it is new. A detected code adds
    /// "Copy code" as the first button.
    public func categoryID(actions: [AMNotificationAction], hasCode: Bool) -> String {
        let id = Self.identifier(actions: actions, hasCode: hasCode)
        if categories[id] != nil {
            order.removeAll { $0 == id }
            order.append(id)
            return id
        }
        categories[id] = Self.makeCategory(id: id, actions: actions, hasCode: hasCode)
        order.append(id)
        while order.count > Self.capacity {
            categories[order.removeFirst()] = nil
        }
        apply(Set(categories.values))
        return id
    }

    static func identifier(actions: [AMNotificationAction], hasCode: Bool) -> String {
        // Everything that shapes a button is hashed, so two sets that look different never share an id.
        var text = hasCode ? "code" : "nocode"
        for a in actions {
            text += "\n\(a.index)\t\(a.title)\t\(a.isReply ? "reply" : "button")\t\(a.isReply ? a.replyHint : "")"
        }
        let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "c|" + hex.prefix(16)
    }

    private static func makeCategory(id: String, actions: [AMNotificationAction], hasCode: Bool) -> UNNotificationCategory {
        var buttons: [UNNotificationAction] = []
        if hasCode {
            buttons.append(UNNotificationAction(
                identifier: copyActionID, title: String(localized: "Copy code", bundle: .main), options: []))
        }
        for a in actions {
            let aid = actionID(index: a.index)
            if a.isReply {
                buttons.append(UNTextInputNotificationAction(
                    identifier: aid, title: a.title, options: [],
                    textInputButtonTitle: String(localized: "Send", bundle: .main),
                    textInputPlaceholder: a.replyHint))
            } else {
                buttons.append(UNNotificationAction(identifier: aid, title: a.title, options: []))
            }
        }
        return UNNotificationCategory(
            identifier: id, actions: buttons, intentIdentifiers: [], options: [.customDismissAction])
    }
}
