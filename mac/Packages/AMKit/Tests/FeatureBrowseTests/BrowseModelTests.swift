import AMProtocol
import AMTestSupport
import ConnectionCore
import FeatureFiles
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureBrowse

/// A model on a real transfer engine, with fakes around both and a temporary folder.
@MainActor
private final class Rig {
    let bulk = FakeBulk()
    let sent = SentLog()
    let dir: URL
    let engine: TransferEngine
    let model: BrowseModel

    /// Deadlines a minute off unless a test sets them: a busy runner must not make them pass.
    init(requestTimeout: Duration = .seconds(60)) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-browse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        let sent = sent
        engine = TransferEngine(
            bulk: bulk,
            send: { type, message in sent.all.append((type, message)) },
            destination: { _ in .refuse(.disabled) },
            freeBytes: { _ in nil },
            timing: TransferTiming(acceptTimeout: .seconds(60), stallTimeout: .seconds(60),
                                   progressInterval: .zero, freeMargin: 0)
        )
        model = BrowseModel(engine: engine, send: { type, message in sent.all.append((type, message)) },
                            requestTimeout: requestTimeout)
        let model = model
        engine.onFinished = { item, _, _ in model.transferFinished(item) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    func connect(shared: Set<String> = ["browse.v1"]) async {
        await engine.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
        await model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
    }

    func disconnect() {
        engine.disconnected()
        model.disconnected()
    }

    func deliver<M: SwiftProtobuf.Message>(_ type: MessageType, _ m: M) async {
        await model.message(envelope(.browse, type, m))
    }

    func pushRoots(_ ids: [String], writable: Bool = true) async {
        var roots = AMBrowseRoots()
        roots.roots = ids.map { id in
            var r = AMBrowseRoot()
            r.id = id
            r.name = "Root \(id)"
            r.kind = .pickedFolder
            r.writable = writable
            return r
        }
        await deliver(.browseRoots, roots)
    }

    var lists: [AMBrowseListRequest] { sent.of(.browseList, AMBrowseListRequest.self) }
    var reads: [AMBrowsePath] { sent.of(.browseRead, AMBrowsePath.self) }
    var browseTypes: [MessageType] { sent.types.filter { $0.rawValue.hasPrefix("browse.") } }

    /// Answers the newest `browse.list`.
    func answerList(_ entries: [AMBrowseEntry], next: UInt32? = nil, more: Bool = false,
                    outcome: AMBrowseOutcome = .ok) async {
        var l = AMBrowseListing()
        l.requestID = lists.last?.requestID ?? 0
        l.outcome = outcome
        if outcome == .ok {
            l.entries = entries
            l.nextOffset = next ?? ((lists.last?.offset ?? 0) + UInt32(entries.count))
            l.more = more
        }
        await deliver(.browseListing, l)
    }

    func answer(_ requestID: UInt64, _ outcome: AMBrowseOutcome) async {
        var r = AMBrowseResult()
        r.requestID = requestID
        r.outcome = outcome
        await deliver(.browseResult, r)
    }

    /// Connects, pushes root `r1`, opens `path` in it and answers with `entries`.
    func opened(_ path: String = "", _ entries: [AMBrowseEntry] = [], more: Bool = false) async throws {
        await connect()
        await pushRoots(["r1"])
        let before = lists.count
        let task = Task { await model.open(BrowseLocation(rootID: "r1", path: path)) }
        try await until("browse.list") { self.lists.count == before + 1 }
        await answerList(entries, more: more)
        await task.value
    }

    func write(_ data: Data, as name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

private func entry(_ name: String, dir: Bool = false, size: UInt64 = 10) -> AMBrowseEntry {
    var e = AMBrowseEntry()
    e.name = name
    e.isDir = dir
    e.size = dir ? 0 : size
    e.modifiedMs = 1_700_000_000_000
    return e
}

// MARK: roots

@MainActor @Test func connectRequestsRoots() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await until("browse.roots_request") { r.browseTypes == [.browseRootsRequest] }
    #expect(!r.model.rootsLoaded)
    await r.pushRoots(["r1", "r2"])
    #expect(r.model.roots.map(\.id) == ["r1", "r2"])
    #expect(r.model.rootsLoaded)
    #expect(r.model.available)

    // A phone that does not share browse.v1 gets nothing browse.*.
    let other = Rig(); defer { other.cleanUp() }
    await other.connect(shared: ["files.v1"])
    await other.model.open(BrowseLocation(rootID: "r1", path: ""))
    await other.model.makeFolder(named: "x")
    #expect(await other.model.download(entry("a"), to: other.dir.appendingPathComponent("a")) == .failure(.transfer(.disabled)))
    try await Task.sleep(for: .milliseconds(50))
    #expect(other.browseTypes.isEmpty)
    #expect(!other.model.available)
}

@MainActor @Test func rootRemovalClearsLocation() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    #expect(r.model.location == BrowseLocation(rootID: "r1", path: "docs"))
    await r.pushRoots(["r1", "r2"])
    #expect(r.model.location != nil, "its root is still there")
    await r.pushRoots(["r2"])
    #expect(r.model.location == nil)
    #expect(r.model.entries.isEmpty)
    #expect(r.model.notice == .revoked)
}

@MainActor @Test func availabilityOffClearsRoots() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("a.txt")])
    var off = AMFeatureAvailability()
    off.enabled = false
    off.reason = .needsPermission
    await r.deliver(.browseAvailability, off)
    #expect(r.model.phoneAvailability == off)
    #expect(r.model.roots.isEmpty)
    #expect(r.model.location == nil)
    #expect(r.model.entries.isEmpty)
    #expect(r.model.notice == nil, "the tab says to turn browsing on, nothing else")
    #expect(r.model.rootsLoaded)

    // Back on: loading again, and the roots are asked for again.
    let asked = r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count
    var on = AMFeatureAvailability()
    on.enabled = true
    await r.deliver(.browseAvailability, on)
    #expect(!r.model.rootsLoaded)
    try await until("roots asked again") { r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == asked + 1 }
}

@MainActor @Test func availabilityBackOnWithNoRootsTimesOut() async throws {
    let r = Rig(requestTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1"])
    var off = AMFeatureAvailability()
    off.enabled = false
    await r.deliver(.browseAvailability, off)
    var on = AMFeatureAvailability()
    on.enabled = true
    await r.deliver(.browseAvailability, on)
    try await until("timed out") { r.model.notice == .timedOut }
    #expect(!r.model.rootsLoaded)
}

@MainActor @Test func refreshRootsWaitsForTheOutstandingRequest() async throws {
    let r = Rig(); defer { r.cleanUp() }
    // The roots deadline passes when the test says: a busy runner cannot end the wait early.
    let sleeps = ManualSleeps()
    r.model.sleep = sleeps.sleep
    await r.connect()
    try await until("first request") { r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == 1 }
    try await until("its deadline") { sleeps.pending == 1 }
    r.model.refreshRoots()
    try await Task.sleep(for: .milliseconds(30))
    #expect(r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == 1, "one is already waiting")
    sleeps.fire()
    try await until("timed out") { r.model.notice == .timedOut }
    // Try Again: asked once more, and the notice goes while it waits.
    r.model.refreshRoots()
    #expect(r.model.notice == nil)
    try await until("retry") { r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == 2 }
    await r.pushRoots(["r1"])
    #expect(r.model.rootsLoaded)
    r.model.refreshRoots()
    try await until("refresh after the answer") { r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == 3 }
}

// MARK: listing

@MainActor @Test func openListsFirstPage() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1"])
    let task = Task { await r.model.open(BrowseLocation(rootID: "r1", path: "DCIM/Camera")) }
    try await until("browse.list") { !r.lists.isEmpty }
    let request = try #require(r.lists.last)
    #expect(request.rootID == "r1")
    #expect(request.path == "DCIM/Camera")
    #expect(request.offset == 0)
    #expect(request.limit == BrowseModel.pageSize)
    #expect(request.requestID != 0)
    #expect(r.model.loading)
    await r.answerList([entry("Sub", dir: true), entry("a.jpg")], next: 2, more: true)
    await task.value
    #expect(r.model.entries.map(\.name) == ["Sub", "a.jpg"])
    #expect(r.model.hasMore)
    #expect(!r.model.loading)
    #expect(r.model.location == BrowseLocation(rootID: "r1", path: "DCIM/Camera"))
    #expect(r.model.notice == nil)
}

@MainActor @Test func loadMoreUsesNextOffset() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", (0..<3).map { entry("f\($0)") }, more: true)
    let task = Task { await r.model.loadMore() }
    try await until("second page") { r.lists.count == 2 }
    #expect(r.lists.last?.offset == 3)
    // A second loadMore while the page is coming asks nothing more.
    await r.model.loadMore()
    #expect(r.lists.count == 2)
    await r.answerList([entry("f3"), entry("f4")], more: false)
    await task.value
    #expect(r.model.entries.map(\.name) == ["f0", "f1", "f2", "f3", "f4"])
    #expect(!r.model.hasMore)
    await r.model.loadMore()
    #expect(r.lists.count == 2, "nothing more to load")
}

@MainActor @Test func upGoesToParent() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("a/b")
    var task = Task { await r.model.up() }
    try await until("list a") { r.lists.count == 2 }
    #expect(r.lists.last?.path == "a")
    await r.answerList([])
    await task.value
    task = Task { await r.model.up() }
    try await until("list root") { r.lists.count == 3 }
    #expect(r.lists.last?.path == "")
    await r.answerList([])
    await task.value
    #expect(r.model.location == BrowseLocation(rootID: "r1", path: ""))
    await r.model.up()
    #expect(r.lists.count == 3, "the root has no parent")
}

@MainActor @Test func revokedAnswerShowsRevoked() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1"])
    let task = Task { await r.model.open(BrowseLocation(rootID: "r1", path: "")) }
    try await until("browse.list") { !r.lists.isEmpty }
    await r.answerList([], outcome: .revoked)
    await task.value
    #expect(r.model.notice == .revoked)
    #expect(r.model.entries.isEmpty)
}

@MainActor @Test func requestTimesOut() async throws {
    let r = Rig(requestTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1"])
    await r.model.open(BrowseLocation(rootID: "r1", path: ""))
    #expect(r.model.notice == .timedOut)
    #expect(!r.model.loading)
    // The answer that comes after all changes nothing.
    await r.answerList([entry("late")])
    #expect(r.model.entries.isEmpty)
    #expect(r.model.notice == .timedOut)
}

@MainActor @Test func lateListingAfterRootRemovalIsIgnored() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1", "r2"])
    let task = Task { await r.model.open(BrowseLocation(rootID: "r1", path: "")) }
    try await until("browse.list") { !r.lists.isEmpty }
    await r.pushRoots(["r2"])
    #expect(r.model.location == nil)
    #expect(r.model.notice == .revoked)
    #expect(!r.model.loading)
    await r.answerList([entry("late")])
    await task.value
    #expect(r.model.entries.isEmpty)
    #expect(r.model.location == nil)
    #expect(!r.model.loading)
    #expect(r.model.notice == .revoked)
}

@MainActor @Test func repeatedNameAcrossPagesIsKeptOnce() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("a"), entry("b"), entry("c")], more: true)
    // A file was added before "c" between pages: "c" comes again at the new offset.
    let more = Task { await r.model.loadMore() }
    try await until("page 2") { r.lists.count == 2 }
    await r.answerList([entry("c"), entry("d")], more: true)
    await more.value
    #expect(r.model.entries.map(\.name) == ["a", "b", "c", "d"])
    #expect(r.lists.last?.offset == 3)

    // The multi-page reload keeps each name once too.
    let task = Task { await r.model.reload() }
    try await until("reload 1") { r.lists.count == 3 }
    await r.answerList([entry("a"), entry("b"), entry("c")], more: true)
    try await until("reload 2") { r.lists.count == 4 }
    await r.answerList([entry("c"), entry("d"), entry("e")], more: false)
    await task.value
    #expect(r.model.entries.map(\.name) == ["a", "b", "c", "d", "e"])
    #expect(!r.model.hasMore)
}

@MainActor @Test func rootsThatNeverComeTimeOut() async throws {
    let r = Rig(requestTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    try await until("timed out") { r.model.notice == .timedOut }
    #expect(!r.model.rootsLoaded)
}

@MainActor @Test func answersForUnknownRequestAreIgnored() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1"])
    let task = Task { await r.model.open(BrowseLocation(rootID: "r1", path: "")) }
    try await until("browse.list") { !r.lists.isEmpty }
    let id = try #require(r.lists.last?.requestID)
    var stray = AMBrowseListing()
    stray.requestID = id + 100
    stray.outcome = .ok
    stray.entries = [entry("stray")]
    await r.deliver(.browseListing, stray)
    await r.answer(id + 101, .revoked)
    #expect(r.model.entries.isEmpty)
    #expect(r.model.notice == nil)
    #expect(r.model.loading)
    await r.answerList([entry("real")])
    await task.value
    #expect(r.model.entries.map(\.name) == ["real"])
    // A second answer to the same request changes nothing.
    var again = AMBrowseListing()
    again.requestID = id
    again.outcome = .ok
    again.entries = [entry("late")]
    await r.deliver(.browseListing, again)
    #expect(r.model.entries.map(\.name) == ["real"])
}

@MainActor @Test func disconnectFailsPendingRequests() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("a.txt")])
    let delete = Task { await r.model.delete(entry("a.txt")) }
    try await until("browse.delete") { r.browseTypes.contains(.browseDelete) }
    let download = Task { await r.model.download(entry("a.txt"), to: r.dir.appendingPathComponent("a.txt")) }
    try await until("browse.read") { !r.reads.isEmpty }
    r.disconnect()
    await delete.value
    #expect(await download.value == .failure(.transfer(.interrupted)))
    #expect(r.model.roots.isEmpty)
    #expect(r.model.entries.isEmpty)
    #expect(r.model.location == nil)
    #expect(r.model.notice == nil, "a lost connection is not a notice")
    #expect(!r.model.available)
}

// MARK: changes

@MainActor @Test func deleteSendsAndReloads() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("old", dir: true), entry("x.txt")])
    let task = Task { await r.model.delete(entry("old", dir: true)) }
    try await until("browse.delete") { r.browseTypes.contains(.browseDelete) }
    let request = try #require(r.sent.of(.browseDelete, AMBrowsePath.self).last)
    #expect(request.rootID == "r1")
    #expect(request.path == "docs/old")
    #expect(request.requestID != 0)
    await r.answer(request.requestID, .ok)
    try await until("reload") { r.lists.count == 2 }
    #expect(r.lists.last?.path == "docs")
    #expect(r.lists.last?.offset == 0)
    await r.answerList([entry("x.txt")])
    await task.value
    #expect(r.model.entries.map(\.name) == ["x.txt"])
    #expect(r.model.notice == nil)
}

@MainActor @Test func reloadKeepsAsManyEntriesAsWereLoaded() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", (0..<3).map { entry("f\($0)") }, more: true)
    let more = Task { await r.model.loadMore() }
    try await until("page 2") { r.lists.count == 2 }
    await r.answerList((3..<6).map { entry("f\($0)") }, more: true)
    await more.value
    let task = Task { await r.model.makeFolder(named: "New") }
    try await until("browse.mkdir") { r.browseTypes.contains(.browseMkdir) }
    await r.answer(try #require(r.sent.of(.browseMkdir, AMBrowsePath.self).last).requestID, .ok)
    try await until("reload 1") { r.lists.count == 3 }
    #expect(r.lists.last?.offset == 0)
    await r.answerList([entry("New", dir: true)] + (0..<2).map { entry("f\($0)") }, more: true)
    try await until("reload 2") { r.lists.count == 4 }
    #expect(r.lists.last?.offset == 3)
    #expect(r.model.entries.count == 6, "the old list stays until the reload is in")
    await r.answerList((2..<5).map { entry("f\($0)") }, more: true)
    await task.value
    #expect(r.model.entries.map(\.name) == ["New", "f0", "f1", "f2", "f3", "f4"])
    #expect(r.model.hasMore)
}

@MainActor @Test func makeFolderSendsSanitizedNameOnly() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs")
    for bad in ["../x", "a/b", ".hidden", "x\u{202E}y", "  "] {
        r.model.dismissNotice()
        await r.model.makeFolder(named: bad)
        #expect(r.model.notice == .badName, "\(bad)")
    }
    #expect(!r.browseTypes.contains(.browseMkdir))
    let task = Task { await r.model.makeFolder(named: "  Photos ") }
    try await until("browse.mkdir") { r.browseTypes.contains(.browseMkdir) }
    #expect(r.model.notice == nil)
    let request = try #require(r.sent.of(.browseMkdir, AMBrowsePath.self).last)
    #expect(request.path == "docs/Photos")
    await r.answer(request.requestID, .denied)
    await task.value
    #expect(r.model.notice == .denied)
}

@MainActor @Test func renameExistingShowsExists() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt"), entry("b.txt")])
    let task = Task { await r.model.rename(entry("a.txt"), to: "b.txt") }
    try await until("browse.rename") { r.browseTypes.contains(.browseRename) }
    let request = try #require(r.sent.of(.browseRename, AMBrowseRename.self).last)
    #expect(request.rootID == "r1")
    #expect(request.path == "docs/a.txt")
    #expect(request.newName == "b.txt")
    await r.answer(request.requestID, .exists)
    await task.value
    #expect(r.model.notice == .exists)
    #expect(r.lists.count == 1, "nothing changed: no reload")

    await r.model.rename(entry("a.txt"), to: "x/y.txt")
    #expect(r.model.notice == .badName)
    r.model.dismissNotice()
    await r.model.rename(entry("a.txt"), to: "   ")
    #expect(r.model.notice == .badName, "nothing left after trimming")
    #expect(r.sent.of(.browseRename, AMBrowseRename.self).count == 1)
}

@MainActor @Test func deleteOfAFolderBeingWrittenShowsInUse() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("busy", dir: true)])
    let task = Task { await r.model.delete(entry("busy", dir: true)) }
    try await until("browse.delete") { r.browseTypes.contains(.browseDelete) }
    await r.answer(try #require(r.sent.of(.browseDelete, AMBrowsePath.self).last).requestID, .exists)
    await task.value
    #expect(r.model.notice == .inUse)
    #expect(r.lists.count == 1)
}

// MARK: downloads

/// Plays the phone answering `read` with `bytes` as transfer `id`.
@MainActor
private func phoneSends(_ r: Rig, _ read: AMBrowsePath, _ bytes: Data, id: String = "t1") async throws {
    var offer = AMTransferOffer()
    offer.transferID = id
    offer.name = "a.txt"
    offer.size = UInt64(bytes.count)
    offer.kind = .file
    offer.requestID = read.requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("files.accept") { r.sent.of(.filesAccept, AMTransferAccept.self).contains { $0.transferID == id } }
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneSends, context: id))
    try await phone.send(bytes)
    var complete = AMTransferComplete()
    complete.transferID = id
    complete.sha256 = sha(bytes)
    await r.engine.message(envelope(.files, .filesComplete, complete))
}

@MainActor @Test func downloadExpectsRequestThenCompletes() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    let file = r.dir.appendingPathComponent("promised/a.txt")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let task = Task { await r.model.download(entry("a.txt"), to: file) }
    try await until("browse.read") { !r.reads.isEmpty }
    let read = try #require(r.reads.last)
    #expect(read.rootID == "r1")
    #expect(read.path == "docs/a.txt")
    #expect(read.requestID != 0)
    let bytes = Data((0..<3000).map { UInt8($0 % 251) })
    try await phoneSends(r, read, bytes)
    #expect(await task.value == .success(file))
    #expect(try Data(contentsOf: file) == bytes)
    // User-started: listed like any receive.
    #expect(r.engine.transfers.first?.direction == .receive)
}

@MainActor @Test func readFailureCompletesWithBrowseOutcome() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("gone.txt")])
    let file = r.dir.appendingPathComponent("gone.txt")
    let task = Task { await r.model.download(entry("gone.txt"), to: file) }
    try await until("browse.read") { !r.reads.isEmpty }
    let read = try #require(r.reads.last)
    await r.answer(read.requestID, .notFound)
    #expect(await task.value == .failure(.browse(.notFound)))
    #expect(r.model.notice == .notFound)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    // The expectation is gone: a late offer for that request is denied.
    var offer = AMTransferOffer()
    offer.transferID = "late"; offer.size = 1; offer.kind = .file; offer.requestID = read.requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
}

@MainActor @Test func downloadsBeyondEightWaitTheirTurn() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", (0..<10).map { entry("f\($0)") })
    var tasks: [Task<Result<URL, TransferFailure>, Never>] = []
    for i in 0..<10 {
        let e = entry("f\(i)"), file = r.dir.appendingPathComponent("f\(i)")
        tasks.append(Task { await r.model.download(e, to: file) })
    }
    try await until("the first eight reads") { r.reads.map(\.path) == (0..<8).map { "f\($0)" } }
    // Absence: at most eight outstanding.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.reads.count == 8, "at most eight outstanding")

    // The tenth is cancelled while it waits: it never asks the phone.
    tasks[9].cancel()
    #expect(await tasks[9].value == .failure(.transfer(.cancelled)))

    // One ends: the ninth goes out.
    await r.answer(r.reads[0].requestID, .io)
    #expect(await tasks[0].value == .failure(.browse(.io)))
    try await until("ninth read") { r.reads.count == 9 && r.reads.last?.path == "f8" }
    // Absence: the cancelled one never goes.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.reads.count == 9, "the cancelled one never went")
    #expect(!r.reads.contains { $0.path == "f9" })
    r.disconnect()
    for t in tasks[1..<9] { #expect(await t.value == .failure(.transfer(.interrupted))) }
}

@MainActor @Test func cancelledDownloadCancelsItsRequest() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", [entry("a.txt")])
    let task = Task { await r.model.download(entry("a.txt"), to: r.dir.appendingPathComponent("a.txt")) }
    try await until("browse.read") { !r.reads.isEmpty }
    task.cancel()
    #expect(await task.value == .failure(.transfer(.cancelled)))
    var offer = AMTransferOffer()
    offer.transferID = "late"; offer.size = 1; offer.kind = .file; offer.requestID = try #require(r.reads.last).requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
}

// MARK: uploads

@MainActor @Test func uploadSendsWithTargetNoOverwrite() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    let bytes = Data(repeating: 4, count: 500)
    let file = try r.write(bytes, as: "b.txt")
    let folder = r.dir.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    await r.model.upload([folder, file])
    try await until("files.offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    let offers = r.sent.of(.filesOffer, AMTransferOffer.self)
    #expect(offers.count == 1, "the folder is skipped")
    let offer = try #require(offers.first)
    #expect(offer.name == "b.txt")
    #expect(offer.target.rootID == "r1")
    #expect(offer.target.dirPath == "docs")
    #expect(!offer.target.overwrite)

    // The phone takes it; once received, the folder reloads.
    var accept = AMTransferAccept(); accept.transferID = offer.transferID
    await r.engine.message(envelope(.files, .filesAccept, accept))
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneReceives, context: offer.transferID))
    #expect(try await readAll(phone, bytes.count) == bytes)
    try await until("files.complete") { !r.sent.of(.filesComplete, AMTransferComplete.self).isEmpty }
    #expect(r.lists.count == 1, "no reload before the phone has it")
    var received = AMTransferReceived(); received.transferID = offer.transferID
    await r.engine.message(envelope(.files, .filesReceived, received))
    try await until("reload") { r.lists.count == 2 }
    #expect(r.lists.last?.path == "docs")
    await r.answerList([entry("a.txt"), entry("b.txt")])
    try await until("entries") { r.model.entries.count == 2 }
}

@MainActor @Test func completedTransferFreesASlot() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", (0..<10).map { entry("f\($0)") })
    var tasks: [Task<Result<URL, TransferFailure>, Never>] = []
    for i in 0..<10 {
        let e = entry("f\(i)"), file = r.dir.appendingPathComponent("f\(i)")
        tasks.append(Task { await r.model.download(e, to: file) })
    }
    try await until("eight reads") { r.reads.count == 8 }
    let bytes = Data(repeating: 1, count: 64)
    try await phoneSends(r, r.reads[0], bytes)
    #expect(await tasks[0].value == .success(r.dir.appendingPathComponent("f0")))
    try await until("ninth read") { r.reads.count == 9 && r.reads.last?.path == "f8" }
    // Absence: one slot freed, one read sent.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.reads.count == 9, "one slot freed, one read sent")
    r.disconnect()
    for t in tasks[1...] { _ = await t.value }
}

@MainActor @Test func cancelledQueuedReadIsNeverPosted() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("", (0..<10).map { entry("f\($0)") })
    var tasks: [Task<Result<URL, TransferFailure>, Never>] = []
    for i in 0..<9 {
        let e = entry("f\(i)"), file = r.dir.appendingPathComponent("f\(i)")
        tasks.append(Task { await r.model.download(e, to: file) })
    }
    try await until("eight reads") { r.reads.count == 8 }
    // Cancelled, and a slot frees in the same turn, before the cancel reaches the model.
    tasks[8].cancel()
    await r.answer(r.reads[0].requestID, .io)
    #expect(await tasks[8].value == .failure(.transfer(.cancelled)))
    // A download whose task is cancelled before it starts never queues.
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await r.model.download(entry("f9"), to: r.dir.appendingPathComponent("f9"))
    }
    #expect(await early.value == .failure(.transfer(.cancelled)))
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.reads.count == 8, "neither was sent")
    #expect(!r.reads.contains { $0.path == "f8" || $0.path == "f9" })
    r.disconnect()
    for t in tasks { _ = await t.value }
}

// MARK: any folder (Finder, Full build)

@MainActor @Test func listOfAnyFolderLeavesTheShownFolderAlone() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    let task = Task { await r.model.list(rootID: "r1", path: "pics/2026", offset: 500) }
    try await until("browse.list") { r.lists.count == 2 }
    let request = try #require(r.lists.last)
    #expect(request.rootID == "r1")
    #expect(request.path == "pics/2026")
    #expect(request.offset == 500)
    #expect(request.limit == BrowseModel.pageSize)
    await r.answerList([entry("p.jpg"), entry("q", dir: true)], next: 502, more: true)
    let listing = try #require(try? await task.value.get())
    #expect(listing.entries.map(\.name) == ["p.jpg", "q"])
    #expect(listing.nextOffset == 502)
    #expect(listing.more)
    // The Files tab still shows its own folder.
    #expect(r.model.location == BrowseLocation(rootID: "r1", path: "docs"))
    #expect(r.model.entries.map(\.name) == ["a.txt"])

    // A refusal is the phone's outcome, and no notice for the tab.
    let refused = Task { await r.model.list(rootID: "r1", path: "gone", offset: 0) }
    try await until("browse.list") { r.lists.count == 3 }
    await r.answerList([], outcome: .notFound)
    #expect(await refused.value == .failure(.browse(.notFound)))
    #expect(r.model.notice == nil)
    #expect(r.model.location?.path == "docs")
}

@MainActor @Test func listOfAnyFolderNeedsBrowseShared() async throws {
    let off = Rig(); defer { off.cleanUp() }
    #expect(await off.model.list(rootID: "r1", path: "", offset: 0) == .failure(.transfer(.interrupted)))
    await off.connect(shared: ["files.v1"])
    #expect(await off.model.list(rootID: "r1", path: "", offset: 0) == .failure(.transfer(.disabled)))
    #expect(off.browseTypes.isEmpty)

    // The session ends while waiting: interrupted.
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let task = Task { await r.model.list(rootID: "r1", path: "", offset: 0) }
    try await until("browse.list") { r.lists.count == 1 }
    r.disconnect()
    #expect(await task.value == .failure(.transfer(.interrupted)))

    // No answer: timed out.
    let slow = Rig(requestTimeout: .milliseconds(50)); defer { slow.cleanUp() }
    await slow.connect()
    #expect(await slow.model.list(rootID: "r1", path: "", offset: 0) == .failure(.transfer(.timedOut)))
}

@MainActor @Test func uploadIntoAnyFolderEndsWithTheTransfer() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    let bytes = Data(repeating: 7, count: 300)
    let file = try r.write(bytes, as: "c.txt")
    let task = Task { await r.model.upload(file: file, into: BrowseLocation(rootID: "r1", path: "pics")) }
    try await until("files.offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    let offer = try #require(r.sent.of(.filesOffer, AMTransferOffer.self).last)
    #expect(offer.name == "c.txt")
    #expect(offer.target.rootID == "r1")
    #expect(offer.target.dirPath == "pics")
    #expect(!offer.target.overwrite)
    var accept = AMTransferAccept(); accept.transferID = offer.transferID
    await r.engine.message(envelope(.files, .filesAccept, accept))
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneReceives, context: offer.transferID))
    #expect(try await readAll(phone, bytes.count) == bytes)
    // The phone answers only after files.complete: the last bytes can be read before the engine
    // has sent it, and an earlier files.received would be ignored.
    try await until("files.complete") { !r.sent.of(.filesComplete, AMTransferComplete.self).isEmpty }
    var received = AMTransferReceived(); received.transferID = offer.transferID
    await r.engine.message(envelope(.files, .filesReceived, received))
    let item = try #require(try? await task.value.get())
    #expect(item.name == "c.txt")
    #expect(item.size == 300)
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.lists.count == 1, "another folder than the shown one: no reload")

    // Refused by the phone: its reason.
    let second = try r.write(bytes, as: "d.txt")
    let refused = Task { await r.model.upload(file: second, into: BrowseLocation(rootID: "r1", path: "docs")) }
    try await until("files.offer") { r.sent.of(.filesOffer, AMTransferOffer.self).count == 2 }
    var reject = AMTransferReject()
    reject.transferID = try #require(r.sent.of(.filesOffer, AMTransferOffer.self).last).transferID
    reject.reason = .noSpace
    await r.engine.message(envelope(.files, .filesReject, reject))
    #expect(await refused.value == .failure(.transfer(.noSpace)))

    // A folder is not sent.
    let folder = r.dir.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(await r.model.upload(file: folder, into: BrowseLocation(rootID: "r1")) == .failure(.browse(.badPath)))
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).count == 2)
}

@MainActor @Test func quietReadLeavesTheTabNoticeAlone() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [entry("a.txt")])
    let task = Task {
        await r.model.download(entry("gone.txt"), in: BrowseLocation(rootID: "r1", path: "pics"),
                               to: r.dir.appendingPathComponent("x"), quiet: true)
    }
    try await until("browse.read") { !r.reads.isEmpty }
    await r.answer(try #require(r.reads.last).requestID, .notFound)
    #expect(await task.value == .failure(.browse(.notFound)))
    #expect(r.model.notice == nil, "Finder's read is not the Files tab's")
}

@MainActor @Test func cancelledUploadStopsItsTransfer() async throws {
    let r = Rig(); defer { r.cleanUp() }
    try await r.opened("docs", [])
    let file = try r.write(Data(repeating: 1, count: 100), as: "c.txt")
    let task = Task { await r.model.upload(file: file, into: BrowseLocation(rootID: "r1", path: "docs")) }
    try await until("files.offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    let id = try #require(r.sent.of(.filesOffer, AMTransferOffer.self).last).transferID
    task.cancel()
    #expect(await task.value == .failure(.transfer(.cancelled)))
    try await until("files.cancel") { r.sent.of(.filesCancel, AMTransferCancel.self).contains { $0.transferID == id } }

    // Cancelled before it starts: nothing is offered.
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await r.model.upload(file: file, into: BrowseLocation(rootID: "r1", path: "docs"))
    }
    #expect(await early.value == .failure(.transfer(.cancelled)))
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).count == 1)
}

// MARK: final wave: requests the phone drops (item 4), the roots-timeout notice (item 12)

@MainActor @Test func readsInAGoneRootAreRevoked() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1", "r2"])
    var tasks: [Task<Result<URL, TransferFailure>, Never>] = []
    // Eight reads in r2 fill the slots; a ninth in r2 and one in r1 wait here.
    for i in 0..<9 {
        let file = r.dir.appendingPathComponent("b\(i)")
        tasks.append(Task { await r.model.download(entry("b\(i)"), in: BrowseLocation(rootID: "r2"), to: file, quiet: true) })
        try await until("read \(i)") { r.reads.count == min(i + 1, 8) }
    }
    let kept = Task { await r.model.download(entry("a"), in: BrowseLocation(rootID: "r1"), to: r.dir.appendingPathComponent("a"), quiet: true) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(r.reads.count == 8)
    // r2 goes: the phone drops its reads without a word; they end now, not at the deadline.
    await r.pushRoots(["r1"])
    for t in tasks { #expect(await t.value == .failure(.browse(.revoked))) }
    // Their slots free up: r1's read goes out.
    try await until("r1 read") { r.reads.contains { $0.rootID == "r1" } }
    #expect(r.reads.count == 9, "the queued r2 read never went")
    kept.cancel()
    _ = await kept.value
}

@MainActor @Test func readWithItsOfferInIsLeftToTheEngine() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.pushRoots(["r1", "r2"])
    let file = r.dir.appendingPathComponent("b")
    let task = Task { await r.model.download(entry("b"), in: BrowseLocation(rootID: "r2"), to: file, quiet: true) }
    try await until("browse.read") { r.reads.count == 1 }
    var offer = AMTransferOffer()
    offer.transferID = "p1"; offer.size = 4; offer.kind = .file; offer.requestID = try #require(r.reads.last).requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("accept") { !r.sent.of(.filesAccept, AMTransferAccept.self).isEmpty }
    // The root goes, but the transfer is live: it ends on its own terms.
    await r.pushRoots(["r1"])
    #expect(r.engine.transfers.first { $0.id == "p1" }?.isFinal == false)
    var cancel = AMTransferCancel(); cancel.transferID = "p1"
    await r.engine.message(envelope(.files, .filesCancel, cancel))
    #expect(await task.value == .failure(.transfer(.cancelled)))
}

@MainActor @Test func dismissingTheRootsTimeoutAsksAgain() async throws {
    let r = Rig(requestTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    try await until("timed out") { r.model.notice == .timedOut }
    #expect(!r.model.rootsLoaded)
    let asked = r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count
    // Dismissing it must not leave the tab spinning for ever: the roots are asked for again.
    r.model.dismissNotice()
    #expect(r.model.notice == nil)
    try await until("asked again") { r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == asked + 1 }
    try await until("timed out again") { r.model.notice == .timedOut }

    // With the roots in, any notice just closes.
    await r.pushRoots(["r1"])
    #expect(r.model.rootsLoaded)
    let open = Task { await r.model.open(BrowseLocation(rootID: "r1")) }
    try await until("browse.list") { r.lists.count == 1 }
    await r.answerList([], outcome: .notFound)
    await open.value
    #expect(r.model.notice == .notFound)
    let now = r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count
    r.model.dismissNotice()
    #expect(r.model.notice == nil)
    try await Task.sleep(for: .milliseconds(30))
    #expect(r.sent.of(.browseRootsRequest, AMBrowseRootsRequest.self).count == now)
}
