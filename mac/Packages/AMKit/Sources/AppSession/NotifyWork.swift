import AMProtocol
import ConnectionCore
import FeatureCalls
import FeatureContacts
import FeatureNotify
import Foundation

/// One unit of work for the notification, contacts and calls models, handled in the order it arrived.
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
}

/// Everything that reaches the notification, contacts and calls models goes through here, so it
/// is handled one at a time in arrival order. Also decides what a server event means for them.
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

    /// Queues what a server event means for the models.
    public func handle(_ event: MacServerEvent) {
        for work in plan(event) { yield(work) }
    }

    /// Queues a `notify.*`, `contacts.*` or `calls.*` message; false for any other type.
    @discardableResult
    public func handle(message envelope: AMEnvelope) -> Bool {
        if envelope.type.hasPrefix("notify.") {
            yield(.message(envelope))
        } else if envelope.type.hasPrefix("contacts.") {
            yield(.contactsMessage(envelope))
        } else if envelope.type.hasPrefix("calls.") {
            yield(.callsMessage(envelope))
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
            return work + [.notificationsForget(phone.id), .contactsForget(phone.id)]
        default:
            return []
        }
    }

    private static let teardown: [NotifyWork] = [.disconnected, .contactsDisconnected, .callsDisconnected]

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
        }
    }
}
