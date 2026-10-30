import AppKit
import FileProviderShared
import os
import UniformTypeIdentifiers

/// The Share menu's "Send to Phone" (F-04, F-10): the sheet names the phone the app last
/// connected to ("Send to <phone>"). Send writes one `OutboxEnvelope` for that phone into the
/// App Group's `Outbox/` and posts the Darwin notification; the app sends it now if that phone
/// is connected, else when it next connects (within 24 hours). Each file is cloned into the
/// outbox (`Outbox/<share>/<n>/<name>`, ruling R24) and the envelope names only that relative
/// path: the unsandboxed app never opens a path a share names elsewhere on the Mac. Nothing
/// shared is logged, only counts.
final class ShareViewController: NSViewController {
    private static let log = Logger(subsystem: "io.github.anmirror.mac.share", category: "share")

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton(title: String(localized: "Send"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private var phone: (id: String, name: String)?

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        detailLabel.textColor = .secondaryLabelColor
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, sendButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        phone = Self.savedPhone()
        if let phone {
            titleLabel.stringValue = String(localized: "Send to \(phone.name)")
            detailLabel.isHidden = true
        } else {
            titleLabel.stringValue = String(localized: "Send to Phone")
            detailLabel.stringValue = String(localized: "Pair a phone in Android Mirroring first.")
            sendButton.isEnabled = false
        }
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    @objc private func send() {
        guard let phone else { return cancel() }
        sendButton.isEnabled = false
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let input = Unchecked(providers)
        guard let outbox = Self.outboxFolder() else { return finish(false) }
        let share = UUID()
        Task {
            var items: [OutboxItem] = []
            for (index, provider) in input.value.prefix(OutboxEnvelope.maxItems).enumerated() {
                if let item = await Self.item(from: provider, outbox: outbox, share: share, index: index) { items.append(item) }
            }
            switch OutboxEnvelope.check(items) {
            case .ok:
                let written = Self.write(items, for: phone.id, in: outbox)
                if !written { Self.removeShare(share, in: outbox) }
                self.finish(written)
            case .nothingToSend:
                Self.removeShare(share, in: outbox)
                self.refuse(String(localized: "Nothing to send."))
            case .textTooLong:
                Self.removeShare(share, in: outbox)
                self.refuse(String(localized: "The text is too long to send."))
            }
        }
    }

    /// Says why nothing was written; the sheet stays until Cancel.
    private func refuse(_ reason: String) {
        detailLabel.stringValue = reason
        detailLabel.isHidden = false
        Self.log.info("share refused")
    }

    private func finish(_ written: Bool) {
        if written {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.fileWriteUnknown))
        }
    }

    // MARK: private

    /// The phone the app last connected to, from the App Group's defaults.
    private static func savedPhone() -> (id: String, name: String)? {
        guard let group = FullBuild.appGroupID(in: .main), let defaults = UserDefaults(suiteName: group),
              let id = defaults.string(forKey: FullBuild.phoneIDKey), !id.isEmpty,
              let name = defaults.string(forKey: FullBuild.phoneNameKey)
        else { return nil }
        return (id, name)
    }

    /// A file URL as a file (cloned into the share's outbox folder; a folder, a package or an
    /// unreadable file is skipped), a web (or other) URL as a link, plain text as text.
    private static func item(from provider: NSItemProvider, outbox: URL, share: UUID, index: Int) async -> OutboxItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, UTType.fileURL), url.isFileURL {
            return await stage(url, outbox: outbox, share: share, index: index)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider, UTType.url) {
            return url.isFileURL ? await stage(url, outbox: outbox, share: share, index: index) : .link(url.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider), !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL {
                    url = u
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let s = item as? String {
                    url = URL(string: s)
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                var text: String?
                if let s = item as? String {
                    text = s
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else if let a = item as? NSAttributedString {
                    text = a.string
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// The App Group's `Outbox/`; nil without a group (an unsigned build).
    private static func outboxFolder() -> URL? {
        guard let group = FullBuild.appGroupID(in: .main),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent(FullBuild.outboxFolder, isDirectory: true)
    }

    /// The file's clone in the share's folder, as an outbox item; nil when it can't be one.
    /// Off the main thread: off APFS the copy is a full one.
    private static func stage(_ url: URL, outbox: URL, share: UUID, index: Int) async -> OutboxItem? {
        do {
            let path = try await Task.detached(priority: .userInitiated) {
                try OutboxFiles.stage(url, in: outbox, share: share, index: index)
            }.value
            return .file(path)
        } catch {
            log.info("a shared file was skipped")
            return nil
        }
    }

    /// A share that is not written leaves no copies behind.
    private static func removeShare(_ share: UUID, in outbox: URL) {
        try? FileManager.default.removeItem(at: outbox.appendingPathComponent(share.uuidString, isDirectory: true))
    }

    /// Writes the share for `phoneID` into `Outbox/` and tells the app; false if it could not.
    private static func write(_ items: [OutboxItem], for phoneID: String, in outbox: URL) -> Bool {
        let envelope = OutboxEnvelope(phoneID: phoneID, createdMs: Int64(Date().timeIntervalSince1970 * 1000), items: items)
        do {
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            try envelope.encoded().write(to: outbox.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch {
            log.error("outbox write failed: \((error as NSError).code, privacy: .public)")
            return false
        }
        log.info("shared \(items.count, privacy: .public) items")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(FullBuild.darwinOutboxNote as CFString), nil, nil, true)
        return true
    }
}

/// Hands a value to a task on another thread.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
