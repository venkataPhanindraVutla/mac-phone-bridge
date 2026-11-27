import AMProtocol
import Foundation
import Observation
import os

/// One phone notification as the history keeps it: text only, no picture.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let phoneID: String
    /// The phone's notification key (SPEC section 10).
    public let key: String
    public let package: String
    /// The app's name, or its package when the phone gave none.
    public let appName: String
    public var title: String
    public var text: String
    /// A one-time code found in the text, for "Copy Code".
    public var code: String?
    public var postedAt: Date
    /// Still on the phone, as far as this Mac knows. Not saved: unknown until the phone says again.
    public var live: Bool

    enum CodingKeys: String, CodingKey { case id, phoneID, key, package, appName, title, text, code, postedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        phoneID = try c.decode(String.self, forKey: .phoneID)
        key = try c.decode(String.self, forKey: .key)
        package = try c.decode(String.self, forKey: .package)
        appName = try c.decode(String.self, forKey: .appName)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        postedAt = try c.decode(Date.self, forKey: .postedAt)
        live = false
    }

    init(phoneID: String, key: String, package: String, appName: String, title: String, text: String,
         code: String?, postedAt: Date) {
        id = UUID()
        self.phoneID = phoneID
        self.key = key
        self.package = package
        self.appName = appName
        self.title = title
        self.text = text
        self.code = code
        self.postedAt = postedAt
        live = true
    }
}

/// Phone notifications the Mac received, kept after they are gone so the user can look back
/// ("Notification history"). Newest first, at most `maxEntries`, none older than
/// `retentionDays` (0 = off: nothing is kept and the file goes). A notification updated while it
/// is still on the phone replaces its row; an alerting update moves it to the top.
///
/// The bytes go through `load` / `save` (the app seals them with a Keychain key); a save is
/// delayed by `saveDelay` so a burst of posts writes once. `save(nil)` deletes the file.
/// Content is never logged.
@MainActor
@Observable
public final class NotificationHistory {
    public static let maxEntries = 1_000
    /// The Settings choices, in days; 0 is off.
    public static let retentionChoices = [0, 1, 7, 30]

    public private(set) var entries: [HistoryEntry] = []
    public var retentionDays: Int {
        didSet {
            guard retentionDays != oldValue else { return }
            prune()
            scheduleSave()
        }
    }

    @ObservationIgnored private let save: (Data?) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let saveDelay: Duration?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "notify-history")

    public init(retentionDays: Int, load: () -> Data?, save: @escaping (Data?) -> Void,
                now: @escaping () -> Date = Date.init, saveDelay: Duration? = .seconds(2)) {
        self.retentionDays = retentionDays
        self.save = save
        self.now = now
        self.saveDelay = saveDelay
        if let data = load() {
            do { entries = try JSONDecoder().decode([HistoryEntry].self, from: data) } catch {
                Self.log.error("history unreadable: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        prune()
    }

    // MARK: from the phone

    /// `n` reached the Mac; `title` is the one shown (a caller's name in place of a number).
    public func record(_ n: AMPhoneNotification, title: String, phoneID: String) {
        guard retentionDays > 0, !(title.isEmpty && n.text.isEmpty) else { return }
        let code = OneTimeCode.detect(title: n.title, text: n.text)
        if let i = entries.firstIndex(where: { $0.live && $0.phoneID == phoneID && $0.key == n.key }) {
            var entry = entries[i]
            guard entry.title != title || entry.text != n.text else { return }
            entry.title = title
            entry.text = n.text
            entry.code = code
            if n.alert {
                entry.postedAt = now()
                entries.remove(at: i)
                entries.insert(entry, at: 0)
            } else {
                entries[i] = entry
            }
        } else {
            entries.insert(HistoryEntry(phoneID: phoneID, key: n.key, package: n.package,
                                        appName: n.appName.isEmpty ? n.package : n.appName,
                                        title: title, text: n.text, code: code, postedAt: now()), at: 0)
        }
        prune()
        scheduleSave()
    }

    /// The phone no longer shows `key`.
    public func removed(key: String, phoneID: String) {
        for i in entries.indices where entries[i].phoneID == phoneID && entries[i].key == key { entries[i].live = false }
    }

    /// The phone's snapshot: exactly `keys` are still on it.
    public func active(keys: Set<String>, phoneID: String) {
        for i in entries.indices where entries[i].phoneID == phoneID { entries[i].live = keys.contains(entries[i].key) }
    }

    /// No phone: nothing is known to be on it.
    public func disconnected() {
        for i in entries.indices { entries[i].live = false }
    }

    // MARK: from the user and the app

    public func clear() {
        entries = []
        scheduleSave()
    }

    /// The phone was forgotten: its entries go.
    public func forget(phoneID: String) {
        keep { $0.phoneID != phoneID }
    }

    /// Entries of phones no longer paired go (one forgotten while the app was not running).
    public func keepOnly(phoneIDs: Set<String>) {
        keep { phoneIDs.contains($0.phoneID) }
    }

    /// Drops what is older than the retention, and the overflow.
    public func prune() {
        guard retentionDays > 0 else {
            if !entries.isEmpty { entries = [] }
            return
        }
        let oldest = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        if entries.contains(where: { $0.postedAt < oldest }) { entries.removeAll { $0.postedAt < oldest } }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// Writes now what a delayed save still holds (the app quits).
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty else { return }
        dirty = false
        if entries.isEmpty {
            save(nil)
            return
        }
        do { save(try JSONEncoder().encode(entries)) } catch {
            Self.log.error("history not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func keep(_ include: (HistoryEntry) -> Bool) {
        let before = entries.count
        entries.removeAll { !include($0) }
        if entries.count != before { scheduleSave() }
    }

    private func scheduleSave() {
        dirty = true
        guard let saveDelay else { return } // tests call flush()
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            self?.flush()
        }
    }
}
