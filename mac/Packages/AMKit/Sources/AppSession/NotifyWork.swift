import AMProtocol
import ConnectionCore
import FeatureCalls
import FeatureContacts
import FeatureNotify
import Foundation

/// One unit of work for the notification, contacts and calls models and the registered session
/// features, handled in the order it arrived.
public enum NotifyWork: Equatable, Sendable {
    case connected(String)
    case disconnected
    case message(AMEnvelope)
    /// The phone was forgotten: its notifications, missed calls and notices leave Notification Center.
    case notificationsForget(String)
    case contactsConnected(String)
    case contactsDisconnected
    case contactsMessage(AMEnvelope)
    /// The Mac's "Use phone contacts for caller names" switch, with its new value.
    case contactsToggled(Bool)
    case contactsForget(String)
    case callsConnected(String)
    case callsDisconnected
    case callsMessage(AMEnvelope)
    /// Phone ID, phone name and the shared capabilities, for every registered feature.
    case featureConnected(String, String, Set<String>)
    case featureDisconnected
    /// For the registered features whose prefixes match its type.
    case featureMessage(AMEnvelope)
    case featureForget(String)
}

/// Everything that reaches the notification, contacts and calls models and the registered
/// session features goes through here, so it is handled one at a time in arrival order. Also
/// decides what a server event means for them.
@MainActor
public final class NotifyWorkQueue {
    private enum Item: Sendable {
        case work(NotifyWork)
        case barrier(CheckedContinuation<Void, Never>)
    }

    /// The phone in session, as far as this queue has been told.
    public private(set) var connectedPhoneID: String?

    private let notifications: NotificationsModel
    private let calls: CallModel
    private let contacts: ContactsSession
    /// In registration order, which is the order they are called in.
    private var features: [any SessionFeature] = []
    private let items: AsyncStream<Item>.Continuation
    private var drain: Task<Void, Never>?

    public init(notifications: NotificationsModel, calls: CallModel, contacts: ContactsSession) {
        self.notifications = notifications
        self.calls = calls
        self.contacts = contacts
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        items = continuation
        drain = Task { [weak self] in
            for await item in stream {
                switch item {
                case let .work(work): await self?.perform(work)
                case let .barrier(done): done.resume()
                }
            }
        }
    }

    public func yield(_ work: NotifyWork) { items.yield(.work(work)) }

    /// Adds a feature for the session: it is told about every connect, disconnect and forget
    /// from now on, and gets every message whose type starts with one of its prefixes.
    public func register(_ feature: any SessionFeature) {
        features.append(feature)
    }

    /// Queues what a server event means for the models.
    public func handle(_ event: MacServerEvent) {
        for work in plan(event) { yield(work) }
    }

    /// Queues a `notify.*`, `contacts.*` or `calls.*` message, or one a registered feature
    /// handles; false for any other type.
    @discardableResult
    public func handle(message envelope: AMEnvelope) -> Bool {
        if envelope.type.hasPrefix("notify.") {
            yield(.message(envelope))
        } else if envelope.type.hasPrefix("contacts.") {
            yield(.contactsMessage(envelope))
        } else if envelope.type.hasPrefix("calls.") {
            yield(.callsMessage(envelope))
        } else if features.contains(where: { Self.handles($0, envelope) }) {
            yield(.featureMessage(envelope))
        } else {
            return false
        }
        return true
    }

    /// Returns once everything queued before the call has been handled.
    public func drained() async {
        await withCheckedContinuation { items.yield(.barrier($0)) }
    }

    /// The work a server event stands for. Only the connected phone's going away ends the session;
    /// forgetting any phone wipes what this Mac holds of it.
    func plan(_ event: MacServerEvent) -> [NotifyWork] {
        switch event {
        case let .connected(phone, shared):
            connectedPhoneID = phone.id
            var work: [NotifyWork] = []
            // Contacts first, so the store is there when the phone's first notifications are shown.
            if shared.contains("contacts.v1") { work.append(.contactsConnected(phone.id)) }
            if shared.contains("calls.v1") { work.append(.callsConnected(phone.id)) }
            if shared.contains("notify.v1") { work.append(.connected(phone.id)) }
            work.append(.featureConnected(phone.id, phone.name, shared))
            return work
        case let .disconnected(phone):
            guard connectedPhoneID == nil || connectedPhoneID == phone.id else { return [] }
            connectedPhoneID = nil
            return Self.teardown
        case let .unpaired(phone):
            var work: [NotifyWork] = []
            if connectedPhoneID == phone.id {
                connectedPhoneID = nil
                work = Self.teardown
            }
            return work + [.notificationsForget(phone.id), .contactsForget(phone.id), .featureForget(phone.id)]
        default:
            return []
        }
    }

    private static let teardown: [NotifyWork] = [
        .disconnected, .contactsDisconnected, .callsDisconnected, .featureDisconnected,
    ]

    private static func handles(_ feature: any SessionFeature, _ envelope: AMEnvelope) -> Bool {
        feature.messagePrefixes.contains { envelope.type.hasPrefix($0) }
    }

    private func perform(_ work: NotifyWork) async {
        switch work {
        case let .connected(phoneID): await notifications.connected(phoneID: phoneID)
        case .disconnected: notifications.disconnected()
        case let .message(envelope): _ = await NotifyRouter.route(envelope, to: notifications)
        case let .notificationsForget(phoneID): await notifications.forget(phoneID: phoneID)
        case let .contactsConnected(phoneID): await contacts.connected(phoneID: phoneID)
        case .contactsDisconnected: contacts.disconnected()
        case let .contactsMessage(envelope): await contacts.message(envelope)
        case let .contactsToggled(on): await contacts.toggled(on: on)
        case let .contactsForget(phoneID): contacts.forget(phoneID: phoneID)
        case let .callsConnected(phoneID): calls.connected(phoneID: phoneID)
        case .callsDisconnected: calls.disconnected()
        case let .callsMessage(envelope): await calls.route(envelope)
        case let .featureConnected(phoneID, phoneName, shared):
            for f in features { await f.connected(phoneID: phoneID, phoneName: phoneName, shared: shared) }
        case .featureDisconnected:
            for f in features { f.disconnected() }
        case let .featureMessage(envelope):
            for f in features where Self.handles(f, envelope) { await f.message(envelope) }
        case let .featureForget(phoneID):
            for f in features { await f.forget(phoneID: phoneID) }
        }
    }
}
