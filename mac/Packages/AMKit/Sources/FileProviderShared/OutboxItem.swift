import Foundation

/// One thing shared with "Send to Phone": a file (by its path; the unsandboxed app reads it), a
/// link, or text.
public struct OutboxItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, link, text }

    public var kind: Kind
    public var path: String?
    public var url: String?
    public var text: String?

    public init(kind: Kind, path: String? = nil, url: String? = nil, text: String? = nil) {
        self.kind = kind
        self.path = path
        self.url = url
        self.text = text
    }

    public static func file(_ path: String) -> OutboxItem { OutboxItem(kind: .file, path: path) }
    public static func link(_ url: String) -> OutboxItem { OutboxItem(kind: .link, url: url) }
    public static func text(_ text: String) -> OutboxItem { OutboxItem(kind: .text, text: text) }
}

/// One share, as the Share extension writes it to the App Group's `Outbox/`: the items, the
/// phone the sheet named ("Send to <phone>") and when (ruling R18). The app sends it to that
/// phone only, and drops it once that phone is forgotten or after 24 hours. Items the phone
/// cannot take now (its capability is not shared) wait in a rewritten envelope (ruling R21).
public struct OutboxEnvelope: Codable, Equatable, Sendable {
    /// Items older than this are dropped unsent.
    public static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000
    /// A share dated further ahead than this is not one this Mac made: dropped.
    public static let maxFutureMs: Int64 = 5 * 60 * 1000
    /// The most items one share carries (the extension's activation rule allows 50).
    public static let maxItems = 50
    /// The most text one item carries, in UTF-8 bytes (the `share.text` cap).
    public static let maxTextBytes = 262_144
    /// A larger file is not read: 50 texts at the cap, and some.
    public static let maxBytes = 16 * 1024 * 1024

    public var phoneID: String
    /// Milliseconds since 1970, when the user shared.
    public var createdMs: Int64
    public var items: [OutboxItem]

    public init(phoneID: String, createdMs: Int64, items: [OutboxItem]) {
        self.phoneID = phoneID
        self.createdMs = createdMs
        self.items = items
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> OutboxEnvelope {
        guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(OutboxEnvelope.self, from: data)
    }

    /// The same share (phone and time) with only `items`: what waits after a partial delivery.
    public func keeping(_ items: [OutboxItem]) -> OutboxEnvelope {
        OutboxEnvelope(phoneID: phoneID, createdMs: createdMs, items: items)
    }

    public enum SheetCheck: Equatable, Sendable {
        case ok
        /// "Nothing to send."
        case nothingToSend
        /// "The text is too long to send."
        case textTooLong
    }

    /// What the Share sheet says before writing a share: nothing usable, or text over the cap.
    public static func check(_ items: [OutboxItem]) -> SheetCheck {
        if items.contains(where: { $0.kind == .text && ($0.text?.utf8.count ?? 0) > maxTextBytes }) { return .textTooLong }
        let usable = items.contains {
            switch $0.kind {
            case .file: !($0.path ?? "").isEmpty
            case .link: !($0.url ?? "").isEmpty
            case .text: !($0.text ?? "").isEmpty
            }
        }
        return usable ? .ok : .nothingToSend
    }

    /// What to do with this share now. It is dropped once its phone is no longer paired, when it
    /// is older than 24 hours, or dated more than 5 minutes ahead. It waits (`keep`) until its
    /// own phone is connected. For its phone: files go with `files.v1` while each is a readable
    /// regular file (else dropped); links and text with `share.v1`. Items whose capability is
    /// not shared now are `kept` for a rewritten envelope (R21). Nothing to send and nothing
    /// dropped leaves it as it is (`keep`).
    public func decision(connectedPhoneID: String?, shared: Set<String>, pairedPhoneIDs: Set<String>, nowMs: Int64,
                         isSendable: (String) -> Bool = OutboxFiles.isSendable) -> OutboxDecision {
        guard pairedPhoneIDs.contains(phoneID), nowMs - createdMs <= Self.maxAgeMs,
              createdMs - nowMs <= Self.maxFutureMs else { return .drop }
        guard connectedPhoneID == phoneID else { return .keep }
        var delivery = OutboxDelivery(files: [], shares: [], skipped: max(0, items.count - Self.maxItems), kept: [])
        for item in items.prefix(Self.maxItems) {
            switch item.kind {
            case .file:
                if !shared.contains("files.v1") {
                    delivery.kept.append(item)
                } else if let path = item.path, isSendable(path) {
                    delivery.files.append(path)
                } else {
                    delivery.skipped += 1
                }
            case .link:
                if !shared.contains("share.v1") {
                    delivery.kept.append(item)
                } else if let url = item.url, !url.isEmpty {
                    delivery.shares.append(item)
                } else {
                    delivery.skipped += 1
                }
            case .text:
                if !shared.contains("share.v1") {
                    delivery.kept.append(item)
                } else if let text = item.text, !text.isEmpty, text.utf8.count <= Self.maxTextBytes {
                    delivery.shares.append(item)
                } else {
                    delivery.skipped += 1
                }
            }
        }
        if delivery.files.isEmpty, delivery.shares.isEmpty, delivery.skipped == 0 { return .keep }
        return .deliver(delivery)
    }
}

public enum OutboxDecision: Equatable, Sendable {
    /// Leave it in the outbox as it is: its phone is not the one connected (or none is), or
    /// nothing in it can go yet.
    case keep
    /// Its phone was forgotten, or it is too old (or dated ahead): delete it unsent.
    case drop
    /// Send these to the connected phone; the share is replaced by `kept`, if any are left.
    case deliver(OutboxDelivery)
}

public struct OutboxDelivery: Equatable, Sendable {
    /// File paths, in the order shared.
    public var files: [String]
    /// Links and text, in the order shared.
    public var shares: [OutboxItem]
    /// Items dropped: a file gone, unreadable, a folder or a package; an empty field; text over
    /// the cap; items past the 50th.
    public var skipped: Int
    /// Items waiting for a capability the phone does not share now (R21).
    public var kept: [OutboxItem]

    public init(files: [String], shares: [OutboxItem], skipped: Int, kept: [OutboxItem]) {
        self.files = files
        self.shares = shares
        self.skipped = skipped
        self.kept = kept
    }
}

public enum OutboxFiles {
    private static let pendingSuffix = ".rewrite.pending"

    /// The name a rewrite of the outbox file `original` is written under before it takes a
    /// place of its own; the drain reads `.json` files only.
    public static func pendingName(for original: String) -> String {
        original + pendingSuffix
    }

    /// The outbox file a pending rewrite was made from; nil for any other name.
    public static func original(ofPending name: String) -> String? {
        guard name.hasSuffix(pendingSuffix) else { return nil }
        let original = String(name.dropLast(pendingSuffix.count))
        return original.hasSuffix(".json") ? original : nil
    }

    /// Whether `path` is an absolute path to a regular file (or a link to one) that can be read
    /// now. Folders and packages are not sent, as with any other send (`SendableFiles`).
    public static func isSendable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]),
              values.isRegularFile == true, values.isPackage != true
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}
