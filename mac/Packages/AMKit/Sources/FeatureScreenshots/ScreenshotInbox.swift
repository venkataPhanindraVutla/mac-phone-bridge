import AMProtocol
import ConnectionCore
import FeatureFiles
import FeatureNotify
import Foundation
import Observation
import os
import UserNotifications

/// Where phone screenshots go: the Settings choice "Save phone screenshots to".
public enum ScreenshotDestination: String, Codable, CaseIterable, Sendable {
    case desktop, downloads, clipboard

    /// The `UserDefaults` key the choice is stored under (its raw value).
    public static let defaultsKey = "screenshotDestination"

    /// The saved choice; Desktop when none (or an unknown one) is saved.
    public static func saved(in defaults: UserDefaults) -> ScreenshotDestination {
        defaults.string(forKey: defaultsKey).flatMap(ScreenshotDestination.init(rawValue:)) ?? .desktop
    }
}

/// Phone screenshots (SPEC section 17), while the phone shares `screenshots.v1`. A
/// `TRANSFER_KIND_SCREENSHOT` offer is received into the chosen folder (Clipboard mode: a temp
/// folder, then the image goes on the pasteboard and the file is deleted), and a notification
/// "Screenshot from <phone>" shows a thumbnail; a click shows the saved file in Finder.
///
/// The engine receives the bytes (`incomingDestination(for:)` picks the folder, `finished`
/// is its `onFinished`). Names, paths and image data are never logged.
@MainActor
@Observable
public final class ScreenshotInbox: SessionFeature {
    public let messagePrefixes = ["screenshots."]

    /// `userInfo` key of a screenshot notification: the saved file's path (none in Clipboard mode).
    public static let pathKey = "shotPath"
    /// `userInfo` key marking a screenshot notification, so its click is claimed in every mode.
    static let markerKey = "shot"

    /// The phone's last `screenshots.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?

    /// Where a screenshot under way goes, and whose it is: fixed at the offer, so a change of
    /// the setting or a disconnect before the end does not lose it.
    private struct Route {
        let mode: ScreenshotDestination
        let phoneID: String
        let phoneName: String
    }

    @ObservationIgnored private let presenter: any NotificationPresenter
    @ObservationIgnored private let destination: () -> ScreenshotDestination
    @ObservationIgnored private let folders: (desktop: URL, downloads: URL, temp: URL)
    @ObservationIgnored private let writeImage: (URL) -> Bool
    @ObservationIgnored private let reveal: (URL) -> Void
    /// The phone in session, while it shares `screenshots.v1`.
    @ObservationIgnored private var phone: (id: String, name: String)?
    /// By transfer ID, from the offer until the transfer ends.
    @ObservationIgnored private var routes: [String: Route] = [:]
    /// This session's one question for notification permission; every screenshot waits for its answer.
    @ObservationIgnored private var authorization: Task<Bool, Never>?
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "screenshots")

    public init(presenter: any NotificationPresenter, destination: @escaping () -> ScreenshotDestination,
                folders: (desktop: URL, downloads: URL, temp: URL), writeImage: @escaping (URL) -> Bool,
                reveal: @escaping (URL) -> Void) {
        self.presenter = presenter
        self.destination = destination
        self.folders = folders
        self.writeImage = writeImage
        self.reveal = reveal
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        phone = shared.contains("screenshots.v1") ? (phoneID, phoneName) : nil
        phoneAvailability = nil
        authorization = nil
    }

    public func disconnected() {
        phone = nil
        phoneAvailability = nil
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phone != nil, envelope.type == MessageType.screenshotsAvailability.rawValue,
              let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
        phoneAvailability = a
    }

    public func forget(phoneID: String) async {}

    // MARK: transfers

    /// Where the engine puts a phone offer of kind SCREENSHOT: the chosen folder, or the temp
    /// folder in Clipboard mode. Refused (`.disabled`) unless the phone in session shares
    /// `screenshots.v1`, and for any other kind.
    public func incomingDestination(for offer: AMTransferOffer) -> IncomingDestination {
        guard let phone, offer.kind == .screenshot else { return .refuse(.disabled) }
        let mode = destination()
        let folder = switch mode {
        case .desktop: folders.desktop
        case .downloads: folders.downloads
        case .clipboard: folders.temp
        }
        // Desktop and Downloads exist; the temp folder is made when first needed.
        if mode == .clipboard {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                Self.log.error("\(offer.transferID, privacy: .public) no folder: \(String(describing: type(of: error)), privacy: .public)")
                return .refuse(.io)
            }
        }
        routes[offer.transferID] = Route(mode: mode, phoneID: phone.id, phoneName: phone.name)
        return .folder(folder)
    }

    /// The engine's `onFinished` for a screenshot. Done: put it on the pasteboard in Clipboard
    /// mode, and notify. Any other ending: nothing to show (the engine removed the partial file).
    public func finished(_ item: TransferItem, at url: URL?) async {
        guard item.direction == .receive, item.kind == .screenshot,
              let route = routes.removeValue(forKey: item.id) else { return }
        guard case .done = item.state, let url else { return }
        let clipboard = route.mode == .clipboard
        // In Clipboard mode the file was only a way onto the pasteboard.
        defer { if clipboard { remove(url) } }
        if clipboard, !writeImage(url) {
            Self.log.error("\(item.id, privacy: .public) not put on the pasteboard")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Screenshot from \(route.phoneName)", bundle: .main)
        content.body = item.name
        var userInfo: [String: Any] = [Self.markerKey: true]
        if !clipboard { userInfo[Self.pathKey] = url.path }
        content.userInfo = userInfo
        // The centre moves an attachment's file into its own store: give it a copy.
        let copy = attachmentCopy(of: url)
        if let copy {
            do {
                content.attachments = [try UNNotificationAttachment(identifier: "shot", url: copy)]
            } catch {
                Self.log.error("\(item.id, privacy: .public) no thumbnail: \(String(describing: type(of: error)), privacy: .public)")
                remove(copy)
            }
        }
        _ = await authorized()
        do {
            try await presenter.deliver(id: "shot|" + route.phoneID + "|" + item.id, content: content)
        } catch {
            Self.log.error("\(item.id, privacy: .public) deliver failed: \(String(describing: type(of: error)), privacy: .public)")
            if let copy { remove(copy) }
        }
    }

    /// A click on a notification: true when it was a screenshot's, after showing the saved file
    /// in Finder (Clipboard mode has none). Only a file in Desktop or Downloads is shown.
    public func handleResponse(userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo[Self.markerKey] as? Bool == true else { return false }
        if let path = userInfo[Self.pathKey] as? String {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if [folders.desktop, folders.downloads].contains(where: { Self.isInside(url, $0) }) { reveal(url) }
        }
        return true
    }

    // MARK: helpers

    /// Asks for notification permission once per session. Runs from `onFinished`, never from the
    /// ordered message queue, so waiting here holds up nothing else.
    private func authorized() async -> Bool {
        let presenter = presenter
        let task = authorization ?? Task { await presenter.authorize() }
        authorization = task
        return await task.value
    }

    /// A copy of `url` in the temp folder for the notification, or nil when it can't be made.
    private func attachmentCopy(of url: URL) -> URL? {
        let fm = FileManager.default
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let copy = folders.temp.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try fm.createDirectory(at: folders.temp, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
            return copy
        } catch {
            Self.log.error("no attachment copy: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// Whether `url` (standardized) lies somewhere below `folder`.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.path
        return url.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
