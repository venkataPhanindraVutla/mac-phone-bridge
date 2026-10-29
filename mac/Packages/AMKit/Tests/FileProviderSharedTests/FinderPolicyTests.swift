import Foundation
import Testing
@testable import FileProviderShared

private func entry(_ name: String, dir: Bool = false) -> EntryDTO {
    EntryDTO(name: name, isDir: dir, size: dir ? 0 : 3, modifiedMs: 1, mime: "")
}

@Test func errorsMapToTheFileProviderContract() {
    // Reading: listing, item lookup, download.
    #expect(FinderPolicy.error(for: .notFound, during: .read) == .noSuchItem)
    #expect(FinderPolicy.error(for: .denied, during: .read) == .noPermission)
    #expect(FinderPolicy.error(for: .unreachable, during: .read) == .serverUnreachable)
    #expect(FinderPolicy.error(for: nil, during: .read) == .serverUnreachable, "the app is gone")
    #expect(FinderPolicy.error(for: .failed, during: .read) == .cannotSynchronize)
    #expect(FinderPolicy.error(for: .cancelled, during: .read) == .userCancelled)
    // Creating: a refused create is excluded from sync, never "no such item".
    #expect(FinderPolicy.error(for: .denied, during: .create) == .excludedFromSync)
    #expect(FinderPolicy.error(for: .notFound, during: .create) == .cannotSynchronize)
    #expect(FinderPolicy.error(for: .noSpace, during: .create) == .insufficientQuota)
    #expect(FinderPolicy.error(for: .failed, during: .create) == .cannotSynchronize)
    #expect(FinderPolicy.error(for: .unreachable, during: .create) == .serverUnreachable)
    #expect(FinderPolicy.error(for: .cancelled, during: .create) == .userCancelled)
}

@Test func changesFromFinderAreRefusedTheContractWay() {
    // Delete: rejected with the server's item (the system restores it); unknown item: cannot sync.
    #expect(FinderPolicy.answer(to: .delete, known: "item") == .rejectDeletion("item"))
    #expect(FinderPolicy.answer(to: .delete, known: String?.none) == .error(.cannotSynchronize))
    // Modify: the unchanged server item.
    #expect(FinderPolicy.answer(to: .modify, known: "item") == .unchanged("item"))
    #expect(FinderPolicy.answer(to: .modify, known: String?.none) == .error(.cannotSynchronize))
}

@Test func createUploadsOnlyNewFilesIntoWritableRoots() {
    let a = entry("a.txt")
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: false, rootWritable: true, existing: nil) == .upload)
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: false, rootWritable: true, existing: a) == .collision(a))
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: false, rootWritable: false, existing: nil)
        == .refuse(.excludedFromSync))
    #expect(FinderPolicy.create(kind: .folder, mayAlreadyExist: false, rootWritable: true, existing: nil)
        == .refuse(.excludedFromSync))
    #expect(FinderPolicy.create(kind: .other, mayAlreadyExist: false, rootWritable: true, existing: nil)
        == .refuse(.excludedFromSync))
}

@Test func reimportMatchesExistingItemsAndNeverUploads() {
    let a = entry("a.txt"), dir = entry("d", dir: true)
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: true, rootWritable: true, existing: a) == .existing(a))
    #expect(FinderPolicy.create(kind: .folder, mayAlreadyExist: true, rootWritable: false, existing: dir) == .existing(dir))
    // No match (or a file where a folder is): nil item, no error, nothing uploaded.
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: true, rootWritable: true, existing: nil) == .notMatched)
    #expect(FinderPolicy.create(kind: .file, mayAlreadyExist: true, rootWritable: true, existing: dir) == .notMatched)
    #expect(FinderPolicy.create(kind: .other, mayAlreadyExist: true, rootWritable: true, existing: a) == .notMatched)
}

@Test func workingSetAnchorIsAShortHashOfTheRoots() {
    let roots = [RootDTO(id: "a", name: "Phone", writable: true), RootDTO(id: "b", name: "Docs", writable: false)]
    let anchor = WorkingSetAnchor.make(roots)
    #expect(anchor.count < 500)
    #expect(anchor == WorkingSetAnchor.make(roots.reversed()), "order does not matter")
    #expect(anchor != WorkingSetAnchor.make([roots[0]]))
    #expect(anchor != WorkingSetAnchor.make([roots[0], RootDTO(id: "b", name: "Docs 2", writable: false)]), "renamed")
    #expect(anchor != WorkingSetAnchor.make([roots[0], RootDTO(id: "b", name: "Docs", writable: true)]), "writable")
    let many = (0..<2000).map { RootDTO(id: "root-\($0)", name: String(repeating: "x", count: 200), writable: true) }
    #expect(WorkingSetAnchor.make(many).count < 500)
}

@Test func entrySearchNeverSaysAbsentWhenItGaveUp() async throws {
    // 3 pages of 2; the name is on the last.
    let pages = [["a", "b"], ["c", "d"], ["e", "f"]]
    var asked: [Int] = []
    let list: (Int) async throws -> ListingDTO = { offset in
        asked.append(offset)
        let i = offset / 2
        return ListingDTO(entries: pages[i].map { entry($0) }, nextOffset: offset + 2, more: i < pages.count - 1)
    }
    #expect(try await EntrySearch.find("e", maxPages: 5, list: list) == .found(entry("e")))
    #expect(asked == [0, 2, 4])
    #expect(try await EntrySearch.find("zz", maxPages: 5, list: list) == .absent, "the whole folder was listed")
    #expect(try await EntrySearch.find("e", maxPages: 2, list: list) == .gaveUp, "pages left unread")
    // A page that does not move on ends the search: unknown, not absent.
    let stuck: (Int) async throws -> ListingDTO = { _ in ListingDTO(entries: [entry("a")], nextOffset: 0, more: true) }
    #expect(try await EntrySearch.find("b", maxPages: 5, list: stuck) == .gaveUp)
}

@Test func entryCacheKeepsWhatEnumerationSaw() {
    let cache = EntryCache(capacity: 3)
    cache.store([entry("a"), entry("b")], rootID: "r", folderPath: "x")
    let id = PhoneItemID.encode(rootID: "r", path: "x/a")
    #expect(cache.entry(for: id) == CachedEntry(rootID: "r", folderPath: "x", entry: entry("a")))
    #expect(cache.entry(for: PhoneItemID.encode(rootID: "r", path: "a")) == nil)
    // Root-level entries.
    cache.store([entry("c")], rootID: "r", folderPath: "")
    #expect(cache.entry(for: PhoneItemID.encode(rootID: "r", path: "c"))?.folderPath == "")
    // Over capacity, the oldest go first.
    cache.store([entry("d")], rootID: "r", folderPath: "x")
    #expect(cache.count == 3)
    #expect(cache.entry(for: id) == nil)
    #expect(cache.entry(for: PhoneItemID.encode(rootID: "r", path: "x/d")) != nil)
    // A newer listing replaces what was seen.
    cache.store([EntryDTO(name: "b", isDir: false, size: 99, modifiedMs: 2, mime: "")], rootID: "r", folderPath: "x")
    #expect(cache.entry(for: PhoneItemID.encode(rootID: "r", path: "x/b"))?.entry.size == 99)
    cache.remove(PhoneItemID.encode(rootID: "r", path: "x/b"))
    #expect(cache.entry(for: PhoneItemID.encode(rootID: "r", path: "x/b")) == nil)
}
