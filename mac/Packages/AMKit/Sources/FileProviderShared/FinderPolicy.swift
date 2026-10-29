import Foundation

/// The File Provider errors the extension answers with (ruling R19), named here so the choice
/// can be tested without the FileProvider framework. The extension turns each into its
/// `NSFileProviderError` or Cocoa error.
public enum FinderError: Equatable, Sendable {
    case noSuchItem
    /// The app or the phone is not there now; the system retries when signalled.
    case serverUnreachable
    /// Something failed that a retry will not fix by itself.
    case cannotSynchronize
    /// The item stays on the Mac only (a refused create).
    case excludedFromSync
    case insufficientQuota
    case noPermission
    case userCancelled
}

/// How the extension answers Finder (rulings R19 and R20). Browsing is read-only apart from new
/// files in writable roots.
public enum FinderPolicy {
    public enum Operation: Sendable { case read, create }

    /// The error for an app reply's `PhoneFilesError` (nil: no reply, the app went away).
    public static func error(for error: PhoneFilesError?, during operation: Operation) -> FinderError {
        switch (error, operation) {
        case (.cancelled, _): .userCancelled
        case (.unreachable, _), (nil, _): .serverUnreachable
        case (.failed, _): .cannotSynchronize
        case (.notFound, .read): .noSuchItem
        case (.notFound, .create): .cannotSynchronize
        case (.denied, .read): .noPermission
        case (.denied, .create): .excludedFromSync
        case (.noSpace, .read): .cannotSynchronize
        case (.noSpace, .create): .insufficientQuota
        }
    }

    public enum Change: Sendable { case delete, modify }

    public enum ChangeAnswer<Item>: Equatable where Item: Equatable {
        /// `NSError.fileProviderErrorForRejectedDeletion(of:)` with the server's item.
        case rejectDeletion(Item)
        /// The server's item as it is: nothing changed on the phone.
        case unchanged(Item)
        case error(FinderError)
    }

    /// Finder deleting or changing an item: refused, the contract's way, with the item as the
    /// phone has it; without it, `cannotSynchronize`.
    public static func answer<Item: Equatable>(to change: Change, known item: Item?) -> ChangeAnswer<Item> {
        guard let item else { return .error(.cannotSynchronize) }
        switch change {
        case .delete: return .rejectDeletion(item)
        case .modify: return .unchanged(item)
        }
    }

    public enum CreateKind: Sendable { case file, folder, other }

    public enum CreateDecision: Equatable, Sendable {
        case upload
        /// The phone has it already (a re-import): that item, nothing uploaded.
        case existing(EntryDTO)
        /// A re-import the phone has no match for: a nil item, no error.
        case notMatched
        /// The name is taken: `fileProviderErrorForCollision(with:)` that item.
        case collision(EntryDTO)
        case refuse(FinderError)
    }

    /// What to do with Finder's `createItem`. `existing` is the entry of that name in the parent
    /// folder, if any. A re-import (`mayAlreadyExist`) never uploads.
    public static func create(kind: CreateKind, mayAlreadyExist: Bool, rootWritable: Bool,
                              existing: EntryDTO?) -> CreateDecision {
        if mayAlreadyExist {
            guard let existing, kind != .other, existing.isDir == (kind == .folder) else { return .notMatched }
            return .existing(existing)
        }
        guard kind == .file, rootWritable else { return .refuse(.excludedFromSync) }
        if let existing { return .collision(existing) }
        return .upload
    }
}

/// The working set's sync anchor: a short hash of the roots (IDs, names, writable), the same
/// whatever their order.
public enum WorkingSetAnchor {
    public static func make(_ roots: [RootDTO]) -> Data {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            // A separator no string contains, so fields cannot run together.
            hash ^= 0xff
            hash &*= 0x0000_0100_0000_01b3
        }
        for root in roots.sorted(by: { $0.id < $1.id }) {
            mix(root.id)
            mix(root.name)
            mix(root.writable ? "w" : "r")
        }
        return Data("v1:\(String(hash, radix: 16)):\(roots.count)".utf8)
    }
}

/// Looking an entry up in its folder's listing, a page at a time.
public enum EntrySearch: Equatable, Sendable {
    case found(EntryDTO)
    /// The whole folder was listed and the name is not in it.
    case absent
    /// The pages ran out before the folder did: not known.
    case gaveUp

    public static func find(_ name: String, maxPages: Int = 20,
                            list: (Int) async throws -> ListingDTO) async throws -> EntrySearch {
        var offset = 0
        for _ in 0..<maxPages {
            let page = try await list(offset)
            if let entry = page.entries.first(where: { $0.name == name }) { return .found(entry) }
            guard page.more else { return .absent }
            guard page.nextOffset > offset else { return .gaveUp }
            offset = page.nextOffset
        }
        return .gaveUp
    }
}

public struct CachedEntry: Equatable, Sendable {
    public let rootID: String
    public let folderPath: String
    public let entry: EntryDTO

    public init(rootID: String, folderPath: String, entry: EntryDTO) {
        self.rootID = rootID
        self.folderPath = folderPath
        self.entry = entry
    }
}

/// The entries enumeration has seen, by item identifier, so an item lookup or a download needs
/// no listing. At most `capacity`; the oldest go first.
public final class EntryCache: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var entries: [String: CachedEntry] = [:]
    private var order: [String] = []
    private var head = 0

    public init(capacity: Int = 100_000) {
        self.capacity = capacity
    }

    public var count: Int { lock.withLock { entries.count } }

    public func store(_ list: [EntryDTO], rootID: String, folderPath: String) {
        lock.withLock {
            for entry in list {
                let path = folderPath.isEmpty ? entry.name : folderPath + "/" + entry.name
                let id = PhoneItemID.encode(rootID: rootID, path: path)
                if entries.updateValue(CachedEntry(rootID: rootID, folderPath: folderPath, entry: entry), forKey: id) == nil {
                    order.append(id)
                }
            }
            while entries.count > capacity, head < order.count {
                entries.removeValue(forKey: order[head])
                head += 1
            }
            if head > capacity {
                // Keep only the keys still cached, in order.
                order = order[head...].filter { entries[$0] != nil }
                head = 0
            }
        }
    }

    public func entry(for id: String) -> CachedEntry? {
        lock.withLock { entries[id] }
    }

    public func remove(_ id: String) {
        _ = lock.withLock { entries.removeValue(forKey: id) }
    }
}
