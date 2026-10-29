import AMProtocol
import ConnectionCore
import FeatureClipboard
import FeatureNotify
import Foundation
import Observation
import os
import SwiftProtobuf
import UserNotifications

/// Links and text shared with the phone (SPEC section 15), while it shares `share.v1`.
/// A link from the phone opens in the default browser; anything else it shares lands on the
/// pasteboard with a notification. The Mac sends a dropped link as `share.link` and dropped
/// text, or the clipboard on request, as `share.text`.
///
/// Shared text and links are never logged, nor their size or hash.
@MainActor
@Observable
public final class ShareModel: SessionFeature {
    public let messagePrefixes = ["share."]

    /// How much of shared text the notification shows, in characters.
    public static let bodyCharacters = 200

    /// How the last explicit text send ended; nil before the first one of this connection.
    public private(set) var lastOutcome: ClipboardSendOutcome?

    @ObservationIgnored private let clipboard: ClipboardModel
    @ObservationIgnored private let presenter: any NotificationPresenter
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    /// The phone in session, while it shares `share.v1`.
    @ObservationIgnored private var phone: (id: String, name: String)?
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "share")

    public init(clipboard: ClipboardModel, presenter: any NotificationPresenter, openURL: @escaping (URL) -> Void,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void) {
        self.clipboard = clipboard
        self.presenter = presenter
        self.openURL = openURL
        self.send = send
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        lastOutcome = nil
        phone = shared.contains("share.v1") ? (phoneID, phoneName) : nil
    }

    public func disconnected() {
        phone = nil
        lastOutcome = nil
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phone != nil else { return }
        switch MessageType(rawValue: envelope.type) {
        case .shareLink:
            guard let m = try? AMSharedLink(serializedBytes: envelope.payload) else { return }
            if let url = LinkRules.link(m.url) {
                openURL(url)
            } else {
                await received(text: m.url)
            }
        case .shareText:
            if let m = try? AMSharedText(serializedBytes: envelope.payload) { await received(text: m.text) }
        default:
            break
        }
    }

    public func forget(phoneID: String) async {}

    // MARK: to the phone

    /// Sends `url` as `share.link` when it is one (`LinkRules`), else as `share.text`.
    public func sendLink(_ url: URL) async {
        guard phone != nil else { return }
        if let link = LinkRules.link(url.absoluteString) {
            var m = AMSharedLink()
            m.url = link.absoluteString
            lastOutcome = .sent
            await send(.shareLink, m)
        } else {
            _ = await sendText(url.absoluteString)
        }
    }

    /// Sends `text` as `share.text`; the phone puts it on its clipboard.
    @discardableResult
    public func sendText(_ text: String) async -> ClipboardSendOutcome {
        let outcome: ClipboardSendOutcome
        if phone == nil {
            outcome = .notConnected
        } else if text.isEmpty {
            outcome = .empty
        } else if text.utf8.count > ClipboardModel.maxBytes {
            outcome = .tooLarge
        } else {
            // The phone will have it: copying it again on the Mac must not send it back.
            clipboard.noteSentToPhone(text)
            var m = AMSharedText()
            m.text = text
            await send(.shareText, m)
            outcome = .sent
        }
        lastOutcome = outcome
        return outcome
    }

    /// "Send Clipboard to Phone": the pasteboard's text, whatever its types (the user asked).
    @discardableResult
    public func sendClipboard() async -> ClipboardSendOutcome {
        guard phone != nil else {
            lastOutcome = .notConnected
            return .notConnected
        }
        return await sendText(clipboard.currentText() ?? "")
    }

    // MARK: from the phone

    private func received(text: String) async {
        guard let phone, !text.isEmpty else { return }
        clipboard.acceptFromPhone(text)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Copied from \(phone.name)", bundle: .main)
        content.body = String(text.prefix(Self.bodyCharacters))
        do { try await presenter.deliver(id: "s|" + phone.id + "|" + UUID().uuidString, content: content) } catch {
            Self.log.error("deliver of shared text failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
