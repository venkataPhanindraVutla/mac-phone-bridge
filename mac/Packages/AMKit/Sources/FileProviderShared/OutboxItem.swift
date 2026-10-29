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
/// phone only, and drops it once that phone is forgotten or after 24 hours.
public struct OutboxEnvelope: Codable, Equatable, Sendable {
    /// Items older than this are dropped unsent.
    public static let maxAgeMs: Int64 = 24 * 60 * 60 * 1000
    /// The most items one share carries (the extension's activation rule allows 50).
    public static let maxItems = 50
    /// A larger file is not read: 50 texts at the 256 KiB cap, and some.
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

    /// What to do with this share now. It waits (`keep`) until its own phone is connected; it is
    /// dropped once that phone is no longer paired or the share is older than 24 hours. For its
    /// phone, files go only with `files.v1` and only while each is still a readable regular file;
    /// links and text only with `share.v1`. Everything else is skipped and counted.
    public func decision(connectedPhoneID: String?, shared: Set<String>, pairedPhoneIDs: Set<String>, nowMs: Int64,
                         isSendable: (String) -> Bool = OutboxFiles.isSendable) -> OutboxDecision {
        guard pairedPhoneIDs.contains(phoneID), nowMs - createdMs <= Self.maxAgeMs else { return .drop }
        guard connectedPhoneID == phoneID else { return .keep }
        var delivery = OutboxDelivery(files: [], shares: [], skipped: max(0, items.count - Self.maxItems))
        for item in items.prefix(Self.maxItems) {
            switch item.kind {
            case .file:
                if shared.contains("files.v1"), let path = item.path, isSendable(path) {
                    delivery.files.append(path)
                } else {
                    delivery.skipped += 1
                }
            case .link:
                if shared.contains("share.v1"), let url = item.url, !url.isEmpty {
                    delivery.shares.append(item)
                } else {
                    delivery.skipped += 1
                }
            case .text:
                if shared.contains("share.v1"), let text = item.text, !text.isEmpty {
                    delivery.shares.append(item)
                } else {
                    delivery.skipped += 1
                }
            }
        }
        return .deliver(delivery)
    }
}

public enum OutboxDecision: Equatable, Sendable {
    /// Its phone is not the one connected (or none is): leave it in the outbox.
    case keep
    /// Its phone was forgotten, or it is older than 24 hours: delete it unsent.
    case drop
    /// Send these to the connected phone, then delete it.
    case deliver(OutboxDelivery)
}

public struct OutboxDelivery: Equatable, Sendable {
    /// File paths, in the order shared.
    public var files: [String]
    /// Links and text, in the order shared.
    public var shares: [OutboxItem]
    /// Items not sent: the phone does not take their kind, or a file is gone, unreadable, a
    /// folder or a package.
    public var skipped: Int

    public init(files: [String], shares: [OutboxItem], skipped: Int) {
        self.files = files
        self.shares = shares
        self.skipped = skipped
    }
}

public enum OutboxFiles {
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
