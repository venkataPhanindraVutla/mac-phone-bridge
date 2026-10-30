#if FULL_BUILD
import AMProtocol
import ConnectionCore
import FeatureFiles
import FeatureShare
import FileProviderShared
import Foundation
import os

/// What "Send to Phone" (the Share extension, Full build) left in the App Group's `Outbox/`,
/// sent by the app (rulings R18, R21). Each share goes only to the phone its sheet named, when
/// that phone is connected: at launch, on connect, and on the extension's Darwin notification.
/// It is dropped once that phone is forgotten, 24 hours after it was shared, or when dated more
/// than 5 minutes ahead. Files go with the transfer engine (only with `files.v1`); links and text
/// with the share model (only with `share.v1`). Items whose capability is not shared now wait in
/// a rewritten envelope.
/// Files (ruling R24): the extension cloned each into `Outbox/<share>/<n>/<name>`, and the envelope
/// names only that share-relative path. The app takes it with `StagedUpload` (no link followed, a
/// regular file only) into a folder of its own, sends that copy, and deletes it when the transfer
/// ends; the share folder goes once its items are queued or dropped. So an envelope another
/// process planted can only send bytes that process already put in the container.
/// At most once: a share is sent only after its outbox file was removed.
/// Every outbox operation (listing, reading, deleting) first checks that `Outbox` is the
/// container's real folder, not a link planted there (`OutboxFiles.isTrustedOutbox`); if it is
/// not, nothing is done.
/// Also tells the extension, through the App Group defaults, which phone to name.
/// Only counts are logged, never paths, links or text.
@MainActor
final class ShareOutbox: SessionFeature {
    let messagePrefixes: [String] = []

    private let folder: URL
    /// The App Group container `folder` must be the real `Outbox` of.
    private let container: URL
    /// The app's own copies of shared files, each in a folder of its own, while they are sent.
    private let copies: URL
    /// That folder, by transfer ID, until its transfer ends.
    private var sending: [String: URL] = [:]
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
        self.container = container
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        copies = caches.appendingPathComponent("io.github.anmirror.mac/outbox-sends", isDirectory: true)
        // Copies an earlier run was still sending.
        try? FileManager.default.removeItem(at: copies)
        self.defaults = defaults
        self.transfers = transfers
        self.share = share
        self.pairedPhoneIDs = pairedPhoneIDs
        // Rewrites left half done: with the original still there nothing was sent, so the rewrite
        // goes; with it gone, the rewrite holds what still waits and takes a place of its own.
        let rewrites = trusted() ? (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] : []
        for url in rewrites {
            guard let original = OutboxFiles.original(ofPending: url.lastPathComponent) else { continue }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(original).path) {
                try? FileManager.default.removeItem(at: url)
            } else {
                settle(url)
            }
        }
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
        guard trusted() else { return }
        var dropped = 0
        for (url, envelope) in pending() where envelope?.phoneID == phoneID {
            try? FileManager.default.removeItem(at: url)
            if let envelope { removeShareFolders(envelope.shareFolders) }
            dropped += 1
        }
        if dropped > 0 { Self.log.info("dropped \(dropped, privacy: .public) shares of a forgotten phone") }
    }

    /// A transfer ended: the copy it sent goes.
    func transferFinished(_ item: TransferItem) {
        guard let copy = sending.removeValue(forKey: item.id) else { return }
        try? FileManager.default.removeItem(at: copy)
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
        guard trusted() else { return }
        let paired = pairedPhoneIDs()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let outbox = folder
        for (url, envelope) in pending() {
            guard let envelope else {
                // Not an outbox file this app can read (or one naming a path outside its share);
                // its share folder goes with the orphans.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let decision = envelope.decision(connectedPhoneID: session?.phoneID, shared: session?.shared ?? [],
                                             pairedPhoneIDs: paired, nowMs: now,
                                             isSendable: { OutboxFiles.isSendable($0, in: outbox) })
            switch decision {
            case .keep:
                continue
            case .drop:
                try? FileManager.default.removeItem(at: url)
                removeShareFolders(envelope.shareFolders)
                Self.log.info("dropped a share of \(envelope.items.count, privacy: .public) items unsent")
            case let .deliver(delivery):
                // What waits is written first, under a name the drain does not read.
                var rewrite: URL?
                if !delivery.kept.isEmpty {
                    let pending = folder.appendingPathComponent(OutboxFiles.pendingName(for: url.lastPathComponent))
                    guard (try? envelope.keeping(delivery.kept).encoded().write(to: pending, options: .atomic)) != nil else {
                        continue
                    }
                    rewrite = pending
                }
                // Sent only once its file is gone: at most once.
                guard (try? FileManager.default.removeItem(at: url)) != nil else {
                    if let rewrite { try? FileManager.default.removeItem(at: rewrite) }
                    continue
                }
                if let rewrite {
                    settle(rewrite)
                    Self.log.info("\(delivery.kept.count, privacy: .public) items wait for the phone to take them")
                }
                await deliver(delivery, to: envelope.phoneID)
                // Its files are queued (copied out) or dropped; files still waiting keep theirs.
                removeShareFolders(envelope.shareFolders.subtracting(envelope.keeping(delivery.kept).shareFolders))
            }
        }
        removeOrphanShareFolders(nowMs: now)
    }

    /// Share folders no envelope (or pending rewrite) names, unchanged for a few minutes.
    private func removeOrphanShareFolders(nowMs: Int64) {
        guard trusted() else { return }
        var referenced = Set<String>()
        for (_, envelope) in pending() { if let envelope { referenced.formUnion(envelope.shareFolders) } }
        let rewrites = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in rewrites where OutboxFiles.original(ofPending: url.lastPathComponent) != nil {
            if let data = try? Data(contentsOf: url), let envelope = try? OutboxEnvelope.decode(data) {
                referenced.formUnion(envelope.shareFolders)
            }
        }
        let removed = OutboxFiles.removeOrphans(in: folder, container: container, referenced: referenced, nowMs: nowMs)
        if let removed, removed > 0 { Self.log.info("removed \(removed, privacy: .public) orphan share folders") }
    }

    /// The outbox is the container's real folder; else logs (no path) and says no.
    private func trusted() -> Bool {
        if OutboxFiles.isTrustedOutbox(folder, container: container) { return true }
        // No outbox yet (nothing was ever shared): nothing to do, nothing to say.
        var info = stat()
        if lstat(folder.path, &info) != 0, errno == ENOENT { return false }
        Self.log.error("outbox is not the container's own folder: left alone")
        return false
    }

    private func removeShareFolders(_ names: Set<String>) {
        // Checked again: a delivery awaits between the drain's check and this.
        guard trusted() else { return }
        for name in names where name.utf8.count == 36 && UUID(uuidString: name) != nil {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Moves a pending rewrite into the outbox as a share of its own. If that fails it stays
    /// pending, and the next launch tries again (its original is gone).
    private func settle(_ pending: URL) {
        let target = folder.appendingPathComponent(UUID().uuidString + ".json")
        if (try? FileManager.default.moveItem(at: pending, to: target)) == nil {
            Self.log.error("a rewritten share stays pending")
        }
    }

    /// Files are queued at once; links and text one by one, while `phoneID` is still connected.
    private func deliver(_ delivery: OutboxDelivery, to phoneID: String) async {
        Self.log.info("""
            sending a share: \(delivery.files.count, privacy: .public) files, \
            \(delivery.shares.count, privacy: .public) links or texts, \(delivery.skipped, privacy: .public) skipped
            """)
        if !delivery.files.isEmpty {
            // Each file taken out of the outbox into a folder of the app's own, off the main actor.
            let outbox = folder, copies = copies
            let staged: [(folder: URL, file: URL)] = await Task.detached(priority: .userInitiated) {
                delivery.files.compactMap { path -> (URL, URL)? in
                    guard let steps = OutboxFiles.steps(ofShared: path), let name = steps.last else { return nil }
                    let own = copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let copy = own.appendingPathComponent(name)
                    do {
                        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
                        try StagedUpload.copy(steps, under: outbox, to: copy)
                        return (own, copy)
                    } catch {
                        try? FileManager.default.removeItem(at: own)
                        return nil
                    }
                }
            }.value
            if staged.count < delivery.files.count {
                Self.log.info("\(delivery.files.count - staged.count, privacy: .public) files not taken from the outbox")
            }
            let ids = transfers.send(files: staged.map(\.file))
            for (id, copy) in zip(ids, staged) { sending[id] = copy.folder }
        }
        for (i, item) in delivery.shares.enumerated() {
            guard session?.phoneID == phoneID else {
                Self.log.info("phone gone: \(delivery.shares.count - i, privacy: .public) links or texts not sent")
                return
            }
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
        guard trusted() else { return [] }
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
