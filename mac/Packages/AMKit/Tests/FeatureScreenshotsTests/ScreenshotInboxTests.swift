import AMProtocol
import FeatureFiles
import FeatureNotify
import Foundation
import SwiftProtobuf
import Testing
import UserNotifications
@testable import FeatureScreenshots

/// A 1×1 PNG, so the notification attachment gets a real image.
private let png = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

@MainActor
private final class FakePresenter: NotificationPresenter {
    var delivered: [(id: String, content: UNNotificationContent)] = []
    var authorizeCalls = 0
    /// Called during a delivery, to look at the files while the notification is being added.
    var onDeliver: (() -> Void)?
    func authorize() async -> Bool {
        authorizeCalls += 1
        return true
    }
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
    func deliver(id: String, content: UNNotificationContent) async throws {
        onDeliver?()
        delivered.append((id, content))
    }
    func remove(ids: [String]) {}
    func deliveredIDs() async -> [String] { delivered.map(\.id) }
}

@MainActor
private final class Rig {
    let presenter = FakePresenter()
    let defaults: UserDefaults
    let root: URL
    let desktop: URL
    let downloads: URL
    let temp: URL
    var written: [URL] = []
    var revealed: [URL] = []
    private(set) var inbox: ScreenshotInbox!

    init() {
        let suite = "ScreenshotInboxTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shots-" + UUID().uuidString, isDirectory: true)
        desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        // Not created: the inbox makes it when it needs it.
        temp = root.appendingPathComponent("tmp/screenshots", isDirectory: true)
        for folder in [desktop, downloads] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let defaults = defaults
        inbox = ScreenshotInbox(
            presenter: presenter,
            destination: { ScreenshotDestination.saved(in: defaults) },
            folders: (desktop: desktop, downloads: downloads, temp: temp),
            writeImage: { [weak self] url in
                self?.written.append(url)
                return FileManager.default.fileExists(atPath: url.path)
            },
            reveal: { [weak self] in self?.revealed.append($0) })
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func connect(_ shared: Set<String> = ["files.v1", "screenshots.v1"]) async {
        await inbox.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
    }

    func offer(_ id: String, kind: AMTransferKind = .screenshot) -> AMTransferOffer {
        var o = AMTransferOffer()
        o.transferID = id
        o.name = "../Screenshot_1.png"
        o.size = UInt64(png.count)
        o.kind = kind
        return o
    }

    /// What the engine does with an accepted offer: the file lands in the folder the inbox chose,
    /// under the sanitized name, then the transfer ends.
    @discardableResult
    func receive(_ id: String = "T1") async throws -> URL {
        let destination = inbox.incomingDestination(for: offer(id))
        guard case let .folder(folder) = destination else {
            Issue.record("refused: \(destination)")
            throw CancellationError()
        }
        let url = folder.appendingPathComponent("Screenshot_1.png")
        try png.write(to: url)
        let item = TransferItem(id: id, direction: .receive, name: "Screenshot_1.png", size: UInt64(png.count),
                                done: UInt64(png.count), kind: .screenshot, state: .done(url))
        await inbox.finished(item, at: url)
        return url
    }

    var userInfo: [AnyHashable: Any]? { presenter.delivered.last?.content.userInfo }
}

// MARK: destinations

@MainActor @Test func desktopDestinationIsDefault() async throws {
    let r = Rig()
    #expect(ScreenshotDestination.saved(in: r.defaults) == .desktop)
    r.defaults.set("somewhere", forKey: ScreenshotDestination.defaultsKey)
    #expect(ScreenshotDestination.saved(in: r.defaults) == .desktop)
    await r.connect()
    #expect(r.inbox.incomingDestination(for: r.offer("T0")) == .folder(r.desktop))
    let saved = try await r.receive()
    #expect(saved.deletingLastPathComponent().standardizedFileURL == r.desktop.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(r.userInfo?[ScreenshotInbox.pathKey] as? String == saved.path)
    #expect(r.written.isEmpty)
}

@MainActor @Test func downloadsDestinationIsUsed() async throws {
    let r = Rig()
    r.defaults.set(ScreenshotDestination.downloads.rawValue, forKey: ScreenshotDestination.defaultsKey)
    await r.connect()
    let saved = try await r.receive()
    #expect(saved.deletingLastPathComponent().standardizedFileURL == r.downloads.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(r.userInfo?[ScreenshotInbox.pathKey] as? String == saved.path)
}

@MainActor @Test func clipboardModeWritesImageAndDeletesFile() async throws {
    let r = Rig()
    r.defaults.set(ScreenshotDestination.clipboard.rawValue, forKey: ScreenshotDestination.defaultsKey)
    await r.connect()
    #expect(r.inbox.incomingDestination(for: r.offer("T0")) == .folder(r.temp))
    // The engine writes into the folder, so it must exist by now.
    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: r.temp.path, isDirectory: &isFolder) && isFolder.boolValue)
    var presentWhileDelivering: Bool?
    r.presenter.onDeliver = { presentWhileDelivering = FileManager.default.fileExists(atPath: r.written.first?.path ?? "") }
    let file = try await r.receive()
    #expect(r.written == [file])
    // Deleted only once the notification (with its thumbnail) was handed over.
    #expect(presentWhileDelivering == true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(r.presenter.delivered.count == 1)
    #expect(r.userInfo?[ScreenshotInbox.pathKey] == nil)
}

// MARK: notification

@MainActor @Test func notificationAttachesACopy() async throws {
    let r = Rig()
    await r.connect()
    let saved = try await r.receive("T7")
    let n = try #require(r.presenter.delivered.first)
    #expect(n.id == "shot|P1|T7")
    #expect(n.content.title == "Screenshot from Pixel")
    #expect(n.content.body == "Screenshot_1.png")
    let attachment = try #require(n.content.attachments.first)
    // The centre moves an attachment's file: it must not be the saved screenshot.
    #expect(attachment.url.standardizedFileURL != saved.standardizedFileURL)
    #expect(attachment.url.deletingLastPathComponent().standardizedFileURL.path.hasPrefix(r.temp.standardizedFileURL.path))
    #expect(FileManager.default.contentsEqual(atPath: attachment.url.path, andPath: saved.path))
    #expect(FileManager.default.fileExists(atPath: saved.path))
    #expect(r.presenter.authorizeCalls == 1)
}

@MainActor @Test func clickRevealsSavedFile() async throws {
    let r = Rig()
    await r.connect()
    let saved = try await r.receive()
    let userInfo = try #require(r.userInfo)
    #expect(r.inbox.handleResponse(userInfo: userInfo))
    #expect(r.revealed.map(\.path) == [saved.path])
}

@MainActor @Test func otherResponsesAreNotClaimed() async throws {
    let r = Rig()
    await r.connect()
    // A phone notification's click, and one with nothing in it.
    #expect(!r.inbox.handleResponse(userInfo: ["phoneID": "P1", "key": "0|com.example|1"]))
    #expect(!r.inbox.handleResponse(userInfo: [:]))
    #expect(r.revealed.isEmpty)
    // A Clipboard-mode screenshot is claimed, though there is no file to show.
    r.defaults.set(ScreenshotDestination.clipboard.rawValue, forKey: ScreenshotDestination.defaultsKey)
    try await r.receive()
    #expect(r.inbox.handleResponse(userInfo: try #require(r.userInfo)))
    #expect(r.revealed.isEmpty)
}

// MARK: gating and endings

@MainActor @Test func offerIsRefusedWithoutScreenshotsV1() async {
    let r = Rig()
    // Not connected yet.
    #expect(r.inbox.incomingDestination(for: r.offer("T1")) == .refuse(.disabled))
    await r.connect(["files.v1"])
    #expect(r.inbox.incomingDestination(for: r.offer("T1")) == .refuse(.disabled))
    await r.connect()
    #expect(r.inbox.incomingDestination(for: r.offer("T2", kind: .file)) == .refuse(.disabled))
    r.inbox.disconnected()
    #expect(r.inbox.incomingDestination(for: r.offer("T3")) == .refuse(.disabled))
}

@MainActor @Test func failedTransferIsNotNotified() async {
    let r = Rig()
    r.defaults.set(ScreenshotDestination.clipboard.rawValue, forKey: ScreenshotDestination.defaultsKey)
    await r.connect()
    _ = r.inbox.incomingDestination(for: r.offer("T1"))
    for state in [TransferItem.State.failed(.interrupted), .cancelled] {
        let item = TransferItem(id: "T1", direction: .receive, name: "Screenshot_1.png", size: 10, kind: .screenshot, state: state)
        await r.inbox.finished(item, at: nil)
    }
    #expect(r.presenter.delivered.isEmpty)
    #expect(r.written.isEmpty)
}

@MainActor @Test func availabilityIsKeptForTheSession() async throws {
    let r = Rig()
    await r.connect()
    var a = AMFeatureAvailability()
    a.enabled = false
    a.reason = .partialAccess
    var e = AMEnvelope()
    e.channel = .screenshots
    e.type = MessageType.screenshotsAvailability.rawValue
    e.payload = try a.serializedData()
    await r.inbox.message(e)
    #expect(r.inbox.phoneAvailability?.reason == .partialAccess)
    r.inbox.disconnected()
    #expect(r.inbox.phoneAvailability == nil)
}
