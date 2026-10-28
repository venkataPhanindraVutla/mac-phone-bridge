import AMProtocol
import Foundation
import Observation
import SwiftProtobuf
import UserNotifications

/// Turns phone notifications into macOS notifications and the user's clicks into messages for the phone.
/// Notification content is never kept here: it lives in Notification Center only.
@MainActor
@Observable
public final class NotificationsModel {
    public private(set) var authorized: Bool?
    public private(set) var phoneAvailability: AMFeatureAvailability?

    @ObservationIgnored private let presenter: NotificationPresenter
    @ObservationIgnored private let icons: IconCache
    @ObservationIgnored private let load: (String) -> NotifySettings
    @ObservationIgnored private let save: (String, NotifySettings) -> Void
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private let nameFor: (String) -> String?
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let attachmentDirectory: URL
    @ObservationIgnored private lazy var registry = CategoryRegistry { [presenter] in presenter.setCategories($0) }
    @ObservationIgnored private var phoneID: String?
    @ObservationIgnored private var requestedIcons: Set<String> = []

    public init(
        presenter: NotificationPresenter, icons: IconCache,
        load: @escaping (String) -> NotifySettings, save: @escaping (String, NotifySettings) -> Void,
        copy: @escaping (String) -> Void,
        nameFor: @escaping (String) -> String? = { _ in nil },
        attachmentDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("am-notify-attachments"),
        send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    ) {
        self.presenter = presenter
        self.icons = icons
        self.load = load
        self.save = save
        self.copy = copy
        self.nameFor = nameFor
        self.attachmentDirectory = attachmentDirectory
        self.send = send
    }

    // MARK: Connection

    public func connected(phoneID: String) async {
        self.phoneID = phoneID
        requestedIcons = []
        authorized = await presenter.authorize()
        await sendFilter(phoneID: phoneID)
    }

    public func disconnected() {
        phoneID = nil
        phoneAvailability = nil
        requestedIcons = []
    }

    // MARK: From the phone

    public func posted(_ n: AMPhoneNotification) async {
        guard let phoneID else { return }
        recordSeen(package: n.package, appName: n.appName, phoneID: phoneID)

        if authorized != false {
            let id = Self.macID(phoneID: phoneID, key: n.key)
            let content = makeContent(n, phoneID: phoneID)
            do { try await presenter.deliver(id: id, content: content) } catch {
                // Delivery can fail when the user has since turned notifications off; nothing to do.
            }
        }
        if !n.package.isEmpty, icons.url(for: n.package) == nil, requestedIcons.insert(n.package).inserted {
            var request = AMIconRequest()
            request.package = n.package
            await send(.notifyIconRequest, request)
        }
    }

    public func removed(_ r: AMNotificationRemoved) {
        guard let phoneID else { return }
        presenter.remove(ids: [Self.macID(phoneID: phoneID, key: r.key)])
    }

    public func snapshot(_ s: AMActiveNotifications) async {
        guard let phoneID else { return }
        let prefix = Self.macID(phoneID: phoneID, key: "")
        let active = Set(s.keys.map { Self.macID(phoneID: phoneID, key: $0) })
        let stale = await presenter.deliveredIDs().filter { $0.hasPrefix(prefix) && !active.contains($0) }
        if !stale.isEmpty { presenter.remove(ids: stale) }
    }

    public func result(_ r: AMActionResult) async {
        guard r.outcome == .gone, let phoneID else { return }   // OK needs nothing; FAILED is not shown
        presenter.remove(ids: [Self.macID(phoneID: phoneID, key: r.key)])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "This notification is no longer on the phone.", bundle: .main)
        content.interruptionLevel = .passive
        do { try await presenter.deliver(id: "i|" + UUID().uuidString, content: content) } catch {
            // As for posted: nothing useful to do.
        }
    }

    public func icon(_ i: AMAppIcon) {
        guard !i.package.isEmpty, !i.png.isEmpty else { return }
        icons.store(i.png, for: i.package)
    }

    public func availability(_ a: AMFeatureAvailability) { phoneAvailability = a }

    // MARK: From the user

    public func handleResponse(actionID: String, userInfo: [AnyHashable: Any], replyText: String?) async {
        guard let phoneID, userInfo["phoneID"] as? String == phoneID,
              let key = userInfo["key"] as? String else { return }

        if actionID == UNNotificationDismissActionIdentifier {
            var dismiss = AMDismissNotification()
            dismiss.key = key
            await send(.notifyDismiss, dismiss)
        } else if actionID == CategoryRegistry.copyActionID {
            if let code = userInfo["code"] as? String { copy(code) }
        } else if actionID.hasPrefix("a|"), let index = UInt32(actionID.dropFirst(2)) {
            var invoke = AMInvokeAction()
            invoke.key = key
            invoke.actionIndex = index
            if let replyText { invoke.replyText = replyText }
            await send(.notifyInvoke, invoke)
        }
        // The default action (a click on the body) does nothing else.
    }

    // MARK: Settings

    public func settings(for phoneID: String) -> NotifySettings { load(phoneID) }

    public func update(_ settings: NotifySettings, phoneID: String) async {
        save(phoneID, settings)
        if phoneID == self.phoneID { await sendFilter(phoneID: phoneID) }
    }

    // MARK: Helpers

    static func macID(phoneID: String, key: String) -> String { "n|" + phoneID + "|" + key }

    private func sendFilter(phoneID: String) async {
        let settings = load(phoneID)
        var filter = AMNotificationFilter()
        filter.enabled = settings.enabled
        filter.mutedPackages = settings.mutedPackages.sorted()
        await send(.notifyFilter, filter)
    }

    private func recordSeen(package: String, appName: String, phoneID: String) {
        guard !package.isEmpty else { return }
        var settings = load(phoneID)
        let name = appName.isEmpty ? package : appName
        if settings.seenApps[package] != name {
            settings.seenApps[package] = name
            save(phoneID, settings)
        }
    }

    /// At least 7 digits once `+ ( ) - .` and spaces are stripped, and nothing else.
    static func looksLikePhoneNumber(_ title: String) -> Bool {
        let stripped = title.filter { !"+().- ".contains($0) }
        return stripped.count >= 7 && stripped.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private func makeContent(_ n: AMPhoneNotification, phoneID: String) -> UNNotificationContent {
        let appName = n.appName.isEmpty ? n.package : n.appName
        var title = n.title
        if Self.looksLikePhoneNumber(title), let name = nameFor(title), !name.isEmpty { title = name }

        let content = UNMutableNotificationContent()
        if title.isEmpty {
            content.title = appName
        } else {
            content.title = title
            content.subtitle = appName
        }
        content.body = n.text

        if n.alert {
            content.sound = .default
        } else {
            content.interruptionLevel = .passive
        }

        let code = OneTimeCode.detect(title: n.title, text: n.text)
        content.categoryIdentifier = registry.categoryID(actions: n.actions, hasCode: code != nil)
        var info: [String: Any] = [
            "phoneID": phoneID, "key": n.key, "actionIndices": n.actions.map { Int($0.index) },
        ]
        if let code { info["code"] = code }
        content.userInfo = info

        if let attachment = makeAttachment(n) { content.attachments = [attachment] }
        return content
    }

    /// The picture, else the cached app icon. The system takes the file it is given, so it gets its own copy.
    private func makeAttachment(_ n: AMPhoneNotification) -> UNNotificationAttachment? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            let target: URL
            if !n.imageJpeg.isEmpty {
                target = attachmentDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                try n.imageJpeg.write(to: target)
            } else if let icon = icons.url(for: n.package) {
                target = attachmentDirectory.appendingPathComponent(UUID().uuidString + ".png")
                try fm.copyItem(at: icon, to: target)
            } else {
                return nil
            }
            return try UNNotificationAttachment(identifier: "image", url: target)
        } catch {
            return nil
        }
    }
}
