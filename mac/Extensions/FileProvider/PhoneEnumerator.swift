import FileProvider
import FileProviderShared
import Foundation

/// The phone's browse roots: the domain's root container, and the working set. The app signals
/// the working set on connect and when the roots change; its sync anchor is a short hash of the
/// roots (`WorkingSetAnchor`). A change reports the roots now there and deletes the ones gone
/// when this process saw the older anchor; otherwise the anchor has expired and the system lists
/// the working set again. Folder contents are not tracked.
final class RootsEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    /// Root IDs by the anchors this process handed out, so a change can name deletions.
    private static let seen = AnchorMemory()
    private let app: AppLink
    /// The working set (reports changes); else the root container (always enumerated afresh).
    private let changes: Bool

    init(app: AppLink, changes: Bool) {
        self.app = app
        self.changes = changes
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let out = Unchecked(observer)
        Task {
            do {
                let roots = try await app.roots(fresh: true)
                out.value.didEnumerate(roots.map(PhoneItem.root))
                out.value.finishEnumerating(upTo: nil)
            } catch {
                out.value.finishEnumeratingWithError(FileProviderExtension.nsError(error, .read))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let out = Unchecked(observer)
        guard changes else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        Task {
            do {
                let roots = try await app.roots(fresh: true)
                let anchor = Self.anchor(roots)
                if anchor != syncAnchor {
                    guard let before = Self.seen.rootIDs(for: syncAnchor.rawValue) else {
                        throw NSFileProviderError(.syncAnchorExpired)
                    }
                    let gone = before.subtracting(roots.map(\.id)).map {
                        NSFileProviderItemIdentifier(PhoneItemID.encode(rootID: $0, path: ""))
                    }
                    if !gone.isEmpty { out.value.didDeleteItems(withIdentifiers: gone) }
                    out.value.didUpdate(roots.map(PhoneItem.root))
                }
                out.value.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            } catch {
                out.value.finishEnumeratingWithError(FileProviderExtension.nsError(error, .read))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let done = Once(completionHandler)
        guard changes else {
            done.call(Self.timeAnchor())
            return
        }
        Task {
            let roots = try? await app.roots(fresh: true)
            done.call(roots.map(Self.anchor))
        }
    }

    /// A hash of the roots: a renamed root is a change too.
    private static func anchor(_ roots: [RootDTO]) -> NSFileProviderSyncAnchor {
        let data = WorkingSetAnchor.make(roots)
        seen.remember(data, rootIDs: Set(roots.map(\.id)))
        return NSFileProviderSyncAnchor(data)
    }

    static func timeAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Int64(Date().timeIntervalSince1970 * 1000)).utf8))
    }
}

/// One phone folder, a page per `browse.list` (the page is the offset). Changes are not
/// tracked: asked for changes, it says the anchor expired and the system lists it again.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let app: AppLink
    private let cache: EntryCache
    private let rootID: String
    private let path: String

    init(app: AppLink, cache: EntryCache, rootID: String, path: String) {
        self.app = app
        self.cache = cache
        self.rootID = rootID
        self.path = path
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let out = Unchecked(observer)
        let offset = Self.offset(page)
        Task {
            do {
                let roots = try await app.roots()
                guard let root = roots.first(where: { $0.id == rootID }) else { throw NSFileProviderError(.noSuchItem) }
                let listing = try await app.list(rootID: rootID, path: path, offset: offset)
                cache.store(listing.entries, rootID: rootID, folderPath: path)
                out.value.didEnumerate(listing.entries.map {
                    PhoneItem.entry($0, rootID: rootID, folderPath: path, writable: root.writable)
                })
                let next = listing.more && listing.nextOffset > offset
                    ? NSFileProviderPage(Data(String(listing.nextOffset).utf8)) : nil
                out.value.finishEnumerating(upTo: next)
            } catch {
                out.value.finishEnumeratingWithError(FileProviderExtension.nsError(error, .read))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(RootsEnumerator.timeAnchor())
    }

    /// The system's initial pages (sorted by name or date) start at 0; ours carry the offset.
    private static func offset(_ page: NSFileProviderPage) -> Int {
        Int(String(decoding: page.rawValue, as: UTF8.self)).map { max(0, $0) } ?? 0
    }
}

/// Hands a value the system gave on one thread to a task on another.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The last few working-set anchors and their root IDs.
final class AnchorMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var anchors: [(Data, Set<String>)] = []

    func remember(_ anchor: Data, rootIDs: Set<String>) {
        lock.withLock {
            anchors.removeAll { $0.0 == anchor }
            anchors.append((anchor, rootIDs))
            if anchors.count > 16 { anchors.removeFirst(anchors.count - 16) }
        }
    }

    func rootIDs(for anchor: Data) -> Set<String>? {
        lock.withLock { anchors.first { $0.0 == anchor }?.1 }
    }
}
