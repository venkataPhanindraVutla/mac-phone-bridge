#if FULL_BUILD
import AMProtocol
import ConnectionCore
import FeatureFiles
import FeatureShare
import FileProviderShared
import Foundation
import os

/// What "Send to Phone" (the Share extension, Full build) left in the App Group's `Outbox/`,
/// sent by the app (ruling R18). Each share goes only to the phone its sheet named, when that
/// phone is connected: at launch, on connect, and on the extension's Darwin notification. It is
/// dropped once that phone is forgotten, or 24 hours after it was shared. Files go with the
/// transfer engine (only with `files.v1`, and only regular files still there and readable);
/// links and text with the share model (only with `share.v1`). The outbox file goes before
/// anything is sent, so nothing is sent twice.
/// Also tells the extension, through the App Group defaults, which phone to name.
/// Only counts are logged, never paths, links or text.
@MainActor
final class ShareOutbox: SessionFeature {
    let messagePrefixes: [String] = []

    private let folder: URL
    private let defaults: UserDefaults?
    private let transfers: TransferEngine
    private let share: ShareModel
    private let pairedPhoneIDs: @MainActor () -> Set<String>
    /// The connected phone and what it shares.
    private var session: (phoneID: String, shared: Set<String>)?
    private var draining = false
    private var drainAgain = false
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "outbox")

    init(container: URL, defaults: UserDefaults?, transfers: TransferEngine, share: ShareModel,
         pairedPhoneIDs: @escaping @MainActor () -> Set<String>) {
        folder = container.appendingPathComponent(FullBuild.outboxFolder, isDirectory: true)
        self.defaults = defaults
        self.transfers = transfers
        self.share = share
        self.pairedPhoneIDs = pairedPhoneIDs
        observeShares()
        // Shares for forgotten phones, and old ones, go now; the rest wait for their phone.
        drainSoon()
    }

    // MARK: SessionFeature

    func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        session = (phoneID, shared)
        defaults?.set(phoneID, forKey: FullBuild.phoneIDKey)
        defaults?.set(phoneName, forKey: FullBuild.phoneNameKey)
        drainSoon()
    }

    func disconnected() {
        session = nil
    }

    func message(_ envelope: AMEnvelope) async {}

    /// The sheet stops naming the phone, and its shares go unsent.
    func forget(phoneID: String) async {
        if session?.phoneID == phoneID { session = nil }
        if defaults?.string(forKey: FullBuild.phoneIDKey) == phoneID {
            defaults?.removeObject(forKey: FullBuild.phoneIDKey)
            defaults?.removeObject(forKey: FullBuild.phoneNameKey)
        }
        var dropped = 0
        for (url, envelope) in pending() where envelope?.phoneID == phoneID {
            try? FileManager.default.removeItem(at: url)
            dropped += 1
        }
        if dropped > 0 { Self.log.info("dropped \(dropped, privacy: .public) shares of a forgotten phone") }
    }

    // MARK: draining

    private func observeShares() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let outbox = Unmanaged<ShareOutbox>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in outbox.drainSoon() }
            },
            FullBuild.darwinOutboxNote as CFString, nil, .deliverImmediately
        )
    }

    /// One drain at a time; a request during one runs another after it.
    private func drainSoon() {
        guard !draining else {
            drainAgain = true
            return
        }
        draining = true
        Task {
            repeat {
                drainAgain = false
                await drain()
            } while drainAgain
            draining = false
        }
    }

    private func drain() async {
        let paired = pairedPhoneIDs()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (url, envelope) in pending() {
            guard let envelope else {
                // Not an outbox file this app can read.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let decision = envelope.decision(connectedPhoneID: session?.phoneID, shared: session?.shared ?? [],
                                             pairedPhoneIDs: paired, nowMs: now)
            switch decision {
            case .keep:
                continue
            case .drop:
                try? FileManager.default.removeItem(at: url)
                Self.log.info("dropped a share of \(envelope.items.count, privacy: .public) items unsent")
            case let .deliver(delivery):
                try? FileManager.default.removeItem(at: url)
                await deliver(delivery)
            }
        }
    }

    private func deliver(_ delivery: OutboxDelivery) async {
        Self.log.info("""
            sending a share: \(delivery.files.count, privacy: .public) files, \
            \(delivery.shares.count, privacy: .public) links or texts, \(delivery.skipped, privacy: .public) skipped
            """)
        if !delivery.files.isEmpty {
            transfers.send(files: delivery.files.map { URL(fileURLWithPath: $0) })
        }
        for item in delivery.shares {
            switch item.kind {
            case .link:
                if let s = item.url, let url = URL(string: s) {
                    await share.sendLink(url)
                } else if let s = item.url {
                    await share.sendText(s)
                }
            case .text:
                if let text = item.text { await share.sendText(text) }
            case .file:
                break
            }
        }
    }

    /// The outbox's `.json` files, oldest first, each with its envelope (nil when unreadable).
    private func pending() -> [(URL, OutboxEnvelope?)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let files = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.creationDate ?? .distantPast)
        }
        return files.sorted { $0.1 < $1.1 }.map { url, _ in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= OutboxEnvelope.maxBytes, let data = try? Data(contentsOf: url) else { return (url, nil) }
            return (url, try? OutboxEnvelope.decode(data))
        }
    }
}
#endif
