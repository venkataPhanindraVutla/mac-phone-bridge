import AMProtocol
import AMTestSupport
import ConnectionCore
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureFiles

// MARK: test doubles

// FakeBulk, MemoryPipe, SentLog, until, readAll, randomBytes, sha and phoneHex are in AMTestSupport.

func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .files
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

extension TransferTiming {
    static let fast = TransferTiming(acceptTimeout: .seconds(5), stallTimeout: .seconds(5),
                                     progressInterval: .zero, freeMargin: 64 << 20)
}

/// Holds the engine's sends until opened.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}

/// An engine with fakes around it and a temporary folder for files.
@MainActor
final class Rig {
    let bulk = FakeBulk()
    let sent = SentLog()
    let dir: URL
    var free: Int64?
    var destination: IncomingDestination
    var destinationCalls = 0
    var finished: [(item: TransferItem, offer: AMTransferOffer, url: URL?)] = []
    /// While set, each send is recorded and then waits for the gate.
    var gate: Gate?
    private(set) var engine: TransferEngine!

    init(timing: TransferTiming = .fast) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        destination = .folder(dir)
        var n = 0
        engine = TransferEngine(
            bulk: bulk,
            send: { [weak self] type, message in
                self?.sent.all.append((type, message))
                if let gate = self?.gate { await gate.wait() }
            },
            destination: { [weak self] _ in
                guard let self else { return .refuse(.io) }
                self.destinationCalls += 1
                return self.destination
            },
            freeBytes: { [weak self] _ in MainActor.assumeIsolated { self?.free } },
            timing: timing,
            newID: {
                n += 1
                return "m\(n)"
            })
        engine.onFinished = { [weak self] item, offer, url in self?.finished.append((item, offer, url)) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    func connect(shared: Set<String> = ["files.v1"]) async {
        await engine.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
    }

    func deliver<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) async {
        await engine.message(envelope(type, message))
    }

    func item(_ id: String) -> TransferItem? { engine.transfers.first { $0.id == id } }

    /// Names in `dir`, hidden ones included.
    func files(in folder: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? dir).path)) ?? []).sorted()
    }

    func write(_ data: Data, as name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // Phone-side messages.

    func offer(_ id: String, name: String = "photo.jpg", size: UInt64, requestID: UInt64 = 0) -> AMTransferOffer {
        var o = AMTransferOffer()
        o.transferID = id; o.name = name; o.size = size; o.mime = "image/jpeg"; o.kind = .file; o.requestID = requestID
        return o
    }

    func accept(_ id: String) async {
        var a = AMTransferAccept(); a.transferID = id
        await deliver(.filesAccept, a)
    }

    func complete(_ id: String, _ hash: Data) async {
        var c = AMTransferComplete(); c.transferID = id; c.sha256 = hash
        await deliver(.filesComplete, c)
    }

    func received(_ id: String) async {
        var r = AMTransferReceived(); r.transferID = id
        await deliver(.filesReceived, r)
    }

    /// Delivers an incoming offer and links a pipe for it once the engine accepts; returns the phone end.
    func startReceive(_ offer: AMTransferOffer) async throws -> MemoryPipe {
        await deliver(.filesOffer, offer)
        try await until("files.accept for \(offer.transferID)") {
            self.sent.of(.filesAccept, AMTransferAccept.self).contains { $0.transferID == offer.transferID }
        }
        let (mac, phone) = MemoryPipe.pair()
        engine.link(mac, grant: BulkGrant(role: .phoneSends, context: offer.transferID))
        return phone
    }

    /// Plays the phone for one Mac send: accept, link, read every byte, wait for complete, received.
    func phoneTakes(_ id: String, size: Int) async throws -> Data {
        await accept(id)
        let (mac, phone) = MemoryPipe.pair()
        engine.link(mac, grant: BulkGrant(role: .phoneReceives, context: id))
        let bytes = try await readAll(phone, size)
        try await until("files.complete for \(id)") {
            self.sent.of(.filesComplete, AMTransferComplete.self).contains { $0.transferID == id }
        }
        await received(id)
        return bytes
    }
}

// MARK: connect

@MainActor @Test func connectSendsEndpointWhenBulkCapabilityShared() async throws {
    for cap in ["files.v1", "screenshots.v1", "photos.v1", "browse.v1"] {
        let r = Rig(); defer { r.cleanUp() }
        await r.connect(shared: ["notify.v1", cap])
        try await until("files.endpoint") { r.sent.types == [.filesEndpoint] }
        #expect(r.sent.of(.filesEndpoint, AMBulkEndpoint.self).first?.port == 4242)
        #expect(r.bulk.allowed == [Data(hexString: phoneHex)])
    }
}

@MainActor @Test func connectWithoutBulkCapabilitySendsNothing() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect(shared: ["notify.v1", "calls.v1"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.all.isEmpty)

    // No port yet (listener restarting): nothing either.
    let r2 = Rig(); defer { r2.cleanUp() }
    r2.bulk.port = nil
    await r2.connect()
    try await Task.sleep(for: .milliseconds(50))
    #expect(r2.sent.all.isEmpty)
}

// MARK: Mac sends

@MainActor @Test func sendOffersWithTokenAndStreamsOnLink() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(600 * 1024 + 7)
    let url = try r.write(bytes, as: "Holiday 1.jpg")
    let ids = r.engine.send(files: [url])
    #expect(ids == ["m1"])

    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    let offer = try #require(r.sent.of(.filesOffer, AMTransferOffer.self).first)
    #expect(offer.transferID == "m1")
    #expect(offer.name == "Holiday 1.jpg")
    #expect(offer.size == UInt64(bytes.count))
    #expect(offer.mime == "image/jpeg")
    #expect(offer.kind == .file)
    #expect(!offer.hasTarget)
    // allow (on connect) comes before the token, which is the one in the offer.
    #expect(r.bulk.calls == ["allow", "issue"])
    #expect(r.bulk.issued.first?.role == .phoneReceives)
    #expect(r.bulk.issued.first?.context == "m1")
    #expect(offer.token == r.bulk.issued.first?.token)
    #expect(r.item("m1")?.state == .waiting)
    #expect(r.item("m1")?.direction == .send)

    await r.accept("m1")
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneReceives, context: "m1"))
    let got = try await readAll(phone, bytes.count)
    #expect(got == bytes)
    try await until("complete") { !r.sent.of(.filesComplete, AMTransferComplete.self).isEmpty }
    #expect(r.sent.of(.filesComplete, AMTransferComplete.self).first?.sha256 == sha(bytes))

    var p = AMTransferProgress(); p.transferID = "m1"; p.bytesDone = 1000
    await r.deliver(.filesProgress, p)
    #expect(r.item("m1")?.done == 1000)

    await r.received("m1")
    #expect(r.item("m1")?.state == .done(nil))
    #expect(r.item("m1")?.done == UInt64(bytes.count))
    #expect(mac.isClosed)
    #expect(r.finished.map(\.item.id) == ["m1"])
}

@MainActor @Test func linkBeforeAcceptStillStreams() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(70_000)
    _ = r.engine.send(files: [try r.write(bytes, as: "a.bin")])
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    // The bulk connection can overtake the accept, which waits in the message queue.
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneReceives, context: "m1"))
    await r.accept("m1")
    #expect(try await readAll(phone, bytes.count) == bytes)
}

@MainActor @Test func rejectShowsReasonAndStartsNext() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let a = try r.write(randomBytes(10), as: "a.txt")
    let b = try r.write(randomBytes(20), as: "b.txt")
    #expect(r.engine.send(files: [a, b]) == ["m1", "m2"])
    try await until("first offer") { r.sent.of(.filesOffer, AMTransferOffer.self).count == 1 }
    #expect(r.item("m2")?.state == .queued)

    var reject = AMTransferReject(); reject.transferID = "m1"; reject.reason = .noSpace
    await r.deliver(.filesReject, reject)
    #expect(r.item("m1")?.state == .failed(.noSpace))
    #expect(r.bulk.revoked.contains("m1"))
    try await until("second offer") { r.sent.of(.filesOffer, AMTransferOffer.self).count == 2 }
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).last?.transferID == "m2")
    #expect(r.item("m2")?.state == .waiting)
    // Active and queued first, then finished.
    #expect(r.engine.transfers.map(\.id) == ["m2", "m1"])
}

@MainActor @Test func acceptTimeoutFailsTimedOut() async throws {
    let r = Rig(timing: TransferTiming(acceptTimeout: .milliseconds(200), stallTimeout: .seconds(5),
                                       progressInterval: .zero, freeMargin: 0))
    defer { r.cleanUp() }
    await r.connect()
    _ = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")])
    try await until("timed out") { r.item("m1")?.state == .failed(.timedOut) }
    try await until("files.failed") {
        r.sent.of(.filesFailed, AMTransferFailed.self).first.map { $0.transferID == "m1" && $0.reason == .timedOut } == true
    }
}

@MainActor @Test func folderURLIsNotOffered() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let folder = r.dir.appendingPathComponent("Album", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let missing = r.dir.appendingPathComponent("gone.txt")
    let ids = r.engine.send(files: [folder, missing])
    #expect(ids.count == 2)
    #expect(r.item(ids[0])?.state == .failed(.io))
    #expect(r.item(ids[1])?.state == .failed(.io))
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty)
    #expect(r.bulk.issued.isEmpty)
}

@MainActor @Test func fiftyFilesRunOneAtATime() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let contents = (0..<50).map { randomBytes(1000 + $0) }
    let urls = try contents.enumerated().map { try r.write($1, as: "f\($0).bin") }
    let ids = r.engine.send(files: urls)
    #expect(ids.count == 50)
    for (i, id) in ids.enumerated() {
        try await until("offer \(i + 1)") { r.sent.of(.filesOffer, AMTransferOffer.self).count == i + 1 }
        // Only this file is out; the rest wait.
        #expect(r.engine.transfers.filter { $0.state == .waiting || $0.state == .active }.map(\.id) == [id])
        #expect(r.engine.transfers.filter { $0.state == .queued }.count == 49 - i)
        let got = try await r.phoneTakes(id, size: contents[i].count)
        #expect(got == contents[i])
        try await until("done \(i)") { r.item(id)?.state == .done(nil) }
    }
    #expect(r.engine.transfers.count == 20)
    #expect(r.engine.transfers.allSatisfy { $0.state == .done(nil) })
    #expect(r.engine.transfers.first?.id == ids.last)
}

@MainActor @Test func sizeAbove4GiBIsKept() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let size: UInt64 = 5_000_000_000
    // A sparse file: the size is real, the disk use is not.
    let url = r.dir.appendingPathComponent("video.mp4")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: size)
    try h.close()

    let id = try #require(r.engine.send(files: [url]).first)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).first?.size == size)
    #expect(r.item(id)?.size == size)
    var p = AMTransferProgress(); p.transferID = id; p.bytesDone = 4_294_967_297
    await r.deliver(.filesProgress, p)
    #expect(r.item(id)?.done == 4_294_967_297)
    r.engine.cancel(id)

    // Receiving: the offer's 64-bit size survives the free-space check and the item.
    r.free = 6_000_000_000
    let phone = try await r.startReceive(r.offer("t1", name: "big.mov", size: size))
    #expect(r.item("t1")?.size == size)
    #expect(r.item("t1")?.state == .active)
    phone.close()
    r.free = 5_000_000_000 + (64 << 20) - 1
    await r.deliver(.filesOffer, r.offer("t2", size: 5_000_000_000))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).last?.reason == .noSpace }
}

// MARK: Mac receives

@MainActor @Test func receiveWritesPartThenMovesOnHashMatch() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(700 * 1024 + 3)
    let phone = try await r.startReceive(r.offer("t1", size: UInt64(bytes.count)))
    let accept = try #require(r.sent.of(.filesAccept, AMTransferAccept.self).first)
    #expect(r.bulk.issued.first?.role == .phoneSends)
    #expect(r.bulk.issued.first?.context == "t1")
    #expect(accept.token == r.bulk.issued.first?.token)
    #expect(r.destinationCalls == 1)

    try await phone.send(bytes.prefix(300_000))
    try await until("partial bytes") { r.item("t1")?.done == 300_000 }
    // Only a hidden part file so far.
    let partial = r.files()
    #expect(partial.count == 1)
    #expect(partial.first?.hasPrefix(".") == true && partial.first?.hasSuffix(".part") == true)
    #expect(r.item("t1")?.state == .active)

    try await phone.send(bytes.dropFirst(300_000))
    await r.complete("t1", sha(bytes))
    try await until("done") { r.item("t1")?.state == .done(r.dir.appendingPathComponent("photo.jpg")) }
    #expect(r.files() == ["photo.jpg"])
    #expect(try Data(contentsOf: r.dir.appendingPathComponent("photo.jpg")) == bytes)
    try await until("received") { r.sent.of(.filesReceived, AMTransferReceived.self).map(\.transferID) == ["t1"] }
    #expect(r.sent.of(.filesProgress, AMTransferProgress.self).last?.bytesDone ?? 0 >= 300_000)
    #expect(r.finished.count == 1)
    #expect(r.finished.first?.url == r.dir.appendingPathComponent("photo.jpg"))
    #expect(r.finished.first?.offer.transferID == "t1")
}

@MainActor @Test func completeBeforeLastByteStillMoves() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(5000)
    let phone = try await r.startReceive(r.offer("t1", name: "a.txt", size: 5000))
    try await phone.send(bytes.prefix(10))
    await r.complete("t1", sha(bytes))
    try await phone.send(bytes.dropFirst(10))
    try await until("done") { r.item("t1")?.state == .done(r.dir.appendingPathComponent("a.txt")) }
}

@MainActor @Test func collisionGetsCounter() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    _ = try r.write(Data("old".utf8), as: "photo.jpg")
    // Collisions ignore case, even on a case-sensitive volume.
    _ = try r.write(Data("old".utf8), as: "PHOTO (1).jpg")
    let bytes = randomBytes(100)
    let phone = try await r.startReceive(r.offer("t1", name: "../../photo.jpg", size: 100))
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes))
    let expected = r.dir.appendingPathComponent("photo (2).jpg")
    try await until("done") { r.item("t1")?.state == .done(expected) }
    #expect(try Data(contentsOf: expected) == bytes)
    #expect(try Data(contentsOf: r.dir.appendingPathComponent("photo.jpg")) == Data("old".utf8))
    #expect(r.item("t1")?.name == "photo.jpg")
}

@MainActor @Test func hashMismatchDeletesPart() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(4096)
    let phone = try await r.startReceive(r.offer("t1", size: 4096))
    try await phone.send(bytes)
    await r.complete("t1", sha(Data("something else".utf8)))
    try await until("failed") { r.item("t1")?.state == .failed(.hashMismatch) }
    try await until("files.failed") {
        r.sent.of(.filesFailed, AMTransferFailed.self).map(\.reason) == [.hashMismatch]
    }
    #expect(r.files().isEmpty)
    #expect(r.sent.of(.filesReceived, AMTransferReceived.self).isEmpty)
}

@MainActor @Test func extraBytesFail() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = randomBytes(2000)
    let phone = try await r.startReceive(r.offer("t1", size: 1000))
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes.prefix(1000)))
    try await until("failed") { r.item("t1")?.state == .failed(.hashMismatch) }
    #expect(r.files().isEmpty)

    // Extra bytes after the last expected one, before files.complete, fail it too.
    let phone2 = try await r.startReceive(r.offer("t2", size: 1000))
    try await phone2.send(bytes.prefix(1000))
    try await until("all bytes") { r.item("t2")?.done == 1000 }
    try await phone2.send(bytes.suffix(5))
    try await until("failed") { r.item("t2")?.state == .failed(.hashMismatch) }
    #expect(r.files().isEmpty)
}

@MainActor @Test func bulkEndsEarlyFailsInterrupted() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let phone = try await r.startReceive(r.offer("t1", size: 1000))
    try await phone.send(randomBytes(400))
    phone.close()
    try await until("failed") { r.item("t1")?.state == .failed(.interrupted) }
    try await until("files.failed") { r.sent.of(.filesFailed, AMTransferFailed.self).map(\.reason) == [.interrupted] }
    #expect(r.files().isEmpty)
}

@MainActor @Test func offerLargerThanFreeSpaceIsRejected() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    r.free = 100 << 20
    await r.deliver(.filesOffer, r.offer("t1", size: 40 << 20))     // 40 + 64 > 100 MiB
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).count == 1 }
    let reject = try #require(r.sent.of(.filesReject, AMTransferReject.self).first)
    #expect(reject.transferID == "t1")
    #expect(reject.reason == .noSpace)
    #expect(r.bulk.issued.isEmpty)
    #expect(r.item("t1")?.state == .failed(.noSpace))
    #expect(r.files().isEmpty)

    // 30 + 64 <= 100 MiB fits.
    await r.deliver(.filesOffer, r.offer("t2", size: 30 << 20))
    try await until("accept") { r.sent.of(.filesAccept, AMTransferAccept.self).map(\.transferID) == ["t2"] }
}

@MainActor @Test func refusedDestinationRejectsWithReason() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    r.destination = .refuse(.disabled)
    await r.deliver(.filesOffer, r.offer("t1", size: 10))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.disabled] }
}

@MainActor @Test func unexpectedRequestIDIsDenied() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    await r.deliver(.filesOffer, r.offer("t1", size: 10, requestID: 77))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).count == 1 }
    #expect(r.sent.of(.filesReject, AMTransferReject.self).first?.reason == .denied)
    #expect(r.destinationCalls == 0)
    #expect(r.bulk.issued.isEmpty)
}

@MainActor @Test func expectedRequestWritesToFileDestination() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let target = try r.write(Data("placeholder".utf8), as: "promised.jpg")
    let requestID = r.engine.nextRequestID()
    #expect(r.engine.nextRequestID() == requestID + 1)
    var result: Result<URL, TransferFailure>?
    r.engine.expect(requestID: requestID, destination: .file(target)) { result = $0 }

    let bytes = randomBytes(3000)
    let phone = try await r.startReceive(r.offer("t1", name: "IMG_1.HEIC", size: 3000, requestID: requestID))
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes))
    try await until("completion") { result != nil }
    #expect(result == .success(target))
    #expect(try Data(contentsOf: target) == bytes)
    #expect(r.files() == ["promised.jpg"])
    #expect(r.destinationCalls == 0)

    // The expectation is used up: the same request ID again is denied.
    await r.deliver(.filesOffer, r.offer("t2", size: 10, requestID: requestID))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
}

@MainActor @Test func requestDeadlineFiresWhenIdle() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let id = r.engine.nextRequestID()
    var result: Result<URL, TransferFailure>?
    let start = ContinuousClock.now
    r.engine.expect(requestID: id, destination: .folder(r.dir), deadline: .milliseconds(150)) { result = $0 }
    try await until("deadline") { result != nil }
    #expect(result == .failure(.transfer(.timedOut)))
    #expect(ContinuousClock.now - start >= .milliseconds(140))
    // The request is gone: a late offer for it is denied.
    await r.deliver(.filesOffer, r.offer("t1", size: 10, requestID: id))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
}

@MainActor @Test func requestDeadlinePausesWhileReceiving() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // A phone send under way: the answer to a request would queue behind it.
    let phone = try await r.startReceive(r.offer("t1", size: 1000))
    let id = r.engine.nextRequestID()
    var result: Result<URL, TransferFailure>?
    r.engine.expect(requestID: id, destination: .folder(r.dir), deadline: .milliseconds(150)) { result = $0 }
    try await Task.sleep(for: .milliseconds(400))
    #expect(result == nil, "no countdown while a receive is live")

    // The receive ends: the request gets a full deadline from now.
    let bytes = randomBytes(1000)
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes))
    try await until("t1 done") { r.item("t1").map { $0.isFinal } == true }
    let ended = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(60))
    #expect(result == nil)
    try await until("deadline") { result != nil }
    #expect(result == .failure(.transfer(.timedOut)))
    #expect(ContinuousClock.now - ended >= .milliseconds(140))
}

@MainActor @Test func requestDeadlineIsNotArmedUntilTheQueueDrains() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // Two phone sends: one active, one queued behind it.
    let phone = try await r.startReceive(r.offer("t1", size: 10))
    await r.deliver(.filesOffer, r.offer("t2", size: 10))
    let id = r.engine.nextRequestID()
    var result: Result<URL, TransferFailure>?
    r.engine.expect(requestID: id, destination: .folder(r.dir), deadline: .milliseconds(100)) { result = $0 }
    let bytes = randomBytes(10)
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes))
    try await until("t1 done") { r.item("t1").map { $0.isFinal } == true }
    // t2 is still live (now waiting for its link): the deadline stays paused.
    try await Task.sleep(for: .milliseconds(300))
    #expect(result == nil)
    r.engine.cancel("t2")
    try await until("deadline") { result != nil }
    #expect(result == .failure(.transfer(.timedOut)))
}

@MainActor @Test func cancelRequestEndsTheRequestOrItsTransfer() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // Still waiting for its offer: it fails CANCELLED, and a late offer is denied.
    let a = r.engine.nextRequestID()
    var first: Result<URL, TransferFailure>?
    r.engine.expect(requestID: a, destination: .folder(r.dir)) { first = $0 }
    r.engine.cancelRequest(a)
    #expect(first == .failure(.transfer(.cancelled)))

    // Its offer came: the transfer is cancelled, and the phone is told.
    let b = r.engine.nextRequestID()
    var second: Result<URL, TransferFailure>?
    r.engine.expect(requestID: b, destination: .folder(r.dir)) { second = $0 }
    let phone = try await r.startReceive(r.offer("t1", size: 1000, requestID: b))
    try await phone.send(randomBytes(100))
    try await until("bytes") { r.item("t1")?.done == 100 }
    r.engine.cancelRequest(b)
    #expect(second == .failure(.transfer(.cancelled)))
    #expect(r.item("t1")?.state == .cancelled)
    try await until("files.cancel") { r.sent.of(.filesCancel, AMTransferCancel.self).map(\.transferID) == ["t1"] }
    #expect(r.files().isEmpty, "the partial file is gone")
    #expect(r.engine.lastReceiveFailure == nil, "a cancel the user asked for is no failure")

    // Unknown IDs are ignored.
    r.engine.cancelRequest(9999)
}

@MainActor @Test func failRequestAndFilesFailedAnswerTheRequest() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let a = r.engine.nextRequestID(), b = r.engine.nextRequestID()
    var results: [UInt64: Result<URL, TransferFailure>] = [:]
    r.engine.expect(requestID: a, destination: .folder(r.dir)) { results[a] = $0 }
    r.engine.expect(requestID: b, destination: .folder(r.dir)) { results[b] = $0 }

    r.engine.failRequest(a, .browse(.notFound))
    var failed = AMTransferFailed(); failed.requestID = b; failed.reason = .notFound
    await r.deliver(.filesFailed, failed)
    #expect(results[a] == .failure(.browse(.notFound)))
    #expect(results[b] == .failure(.transfer(.notFound)))
}

// MARK: failures

@MainActor @Test func disconnectFailsAndDeletesPartial() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // A receive with bytes on disk, a send waiting for its accept, one queued and one request.
    let phone = try await r.startReceive(r.offer("t1", size: 10_000))
    try await phone.send(randomBytes(4000))
    try await until("partial") { r.item("t1")?.done == 4000 }
    #expect(r.files().count == 1)
    let ids = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt"), try r.write(randomBytes(10), as: "b.txt")])
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    var request: Result<URL, TransferFailure>?
    r.engine.expect(requestID: r.engine.nextRequestID(), destination: .folder(r.dir)) { request = $0 }

    r.engine.disconnected()

    #expect(r.item("t1")?.state == .failed(.interrupted))
    #expect(r.item(ids[0])?.state == .failed(.interrupted))
    #expect(r.item(ids[1])?.state == .failed(.interrupted))
    #expect(request == .failure(.transfer(.interrupted)))
    #expect(r.files() == ["a.txt", "b.txt"])
    #expect(r.bulk.revokeAllCount >= 1)
    #expect(r.bulk.allowed.last == .some(nil))
    // Tokens die before the door closes.
    #expect(r.bulk.calls.suffix(2) == ["revokeAll", "allow"])
    // The phone's end sees the link close.
    #expect(try await phone.receive(maximum: 10) == nil)
    // Nothing is sent to a phone that is gone.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.of(.filesFailed, AMTransferFailed.self).isEmpty)
    #expect(r.sent.of(.filesCancel, AMTransferCancel.self).isEmpty)
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).count == 1)
}

@MainActor @Test func stalledLinkTimesOut() async throws {
    let r = Rig(timing: TransferTiming(acceptTimeout: .seconds(5), stallTimeout: .milliseconds(300),
                                       progressInterval: .zero, freeMargin: 0))
    defer { r.cleanUp() }
    await r.connect()
    let phone = try await r.startReceive(r.offer("t1", size: 10_000))
    // Taken before the bytes move: the limit counts from the last byte, which comes later.
    let start = ContinuousClock.now
    try await phone.send(randomBytes(1000))
    try await until("timed out") { r.item("t1")?.state == .failed(.timedOut) }
    #expect(ContinuousClock.now - start >= .milliseconds(250))
    try await until("files.failed") { r.sent.of(.filesFailed, AMTransferFailed.self).map(\.reason) == [.timedOut] }
    #expect(r.files().isEmpty)
    #expect(try await phone.receive(maximum: 10) == nil)

    // Sending: a phone that accepts and never opens the bulk connection times out the same way.
    let a = Data(count: 2 << 20)
    let id = try #require(r.engine.send(files: [try r.write(a, as: "a.bin")]).first)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    await r.accept(id)
    try await until("still timed out") { r.item(id)?.state == .failed(.timedOut) }
}

@MainActor @Test func cancelDeletesPartialAndSendsCancel() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let phone = try await r.startReceive(r.offer("t1", size: 10_000))
    try await phone.send(randomBytes(2000))
    try await until("partial") { r.item("t1")?.done == 2000 }
    r.engine.cancel("t1")
    #expect(r.item("t1")?.state == .cancelled)
    try await until("files.cancel") { r.sent.of(.filesCancel, AMTransferCancel.self).map(\.transferID) == ["t1"] }
    #expect(r.files().isEmpty)
    #expect(try await phone.receive(maximum: 10) == nil)

    // A queued send is dropped without a message; the phone's cancel stops an active one.
    let ids = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt"), try r.write(randomBytes(10), as: "b.txt")])
    r.engine.cancel(ids[1])
    #expect(r.item(ids[1])?.state == .cancelled)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    var c = AMTransferCancel(); c.transferID = ids[0]
    await r.deliver(.filesCancel, c)
    #expect(r.item(ids[0])?.state == .cancelled)
    try await until("t1's cancel and one offer") {
        r.sent.of(.filesCancel, AMTransferCancel.self).count == 1 && r.sent.of(.filesOffer, AMTransferOffer.self).count == 1
    }
    // Absence: the phone's cancel is not answered, and the cancelled queued one is never offered.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.of(.filesCancel, AMTransferCancel.self).count == 1)
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).count == 1)
}

@MainActor @Test func strayLinkIsClosed() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let (mac, _) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneSends, context: "nobody"))
    #expect(mac.isClosed)
}

// MARK: fix round 1

@MainActor @Test func sendWhileDisconnectedFailsAndIsNotOfferedOnConnect() async throws {
    let r = Rig(); defer { r.cleanUp() }
    let ids = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")])
    #expect(r.item(ids[0])?.state == .failed(.interrupted))
    await r.connect()
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty)
    #expect(r.bulk.issued.isEmpty)

    // Nothing queued in one session survives into the next.
    let queued = r.engine.send(files: [try r.write(randomBytes(10), as: "b.txt"), try r.write(randomBytes(10), as: "c.txt")])
    r.engine.disconnected()
    await r.connect()
    try await until("both failed, the first issued") {
        queued.allSatisfy { r.item($0)?.state == .failed(.interrupted) } && r.bulk.issued.map(\.context) == [queued[0]]
    }
    // Absence: only the first was ever offered (and that offer, still in the outbox, was dropped as stale).
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.bulk.issued.map(\.context) == [queued[0]])
    #expect(!r.sent.of(.filesOffer, AMTransferOffer.self).contains { $0.transferID == queued[1] })
}

@MainActor @Test func noOfferWhenPhoneDoesNotShareFiles() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect(shared: ["photos.v1"])
    let ids = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")])
    #expect(r.item(ids[0])?.state == .failed(.interrupted))
    try await until("endpoint") { !r.sent.all.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.types == [.filesEndpoint])
    #expect(r.bulk.issued.isEmpty)
}

@MainActor @Test func forgetFailsWhatIsStillQueued() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let ids = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt"), try r.write(randomBytes(10), as: "b.txt")])
    #expect(r.item(ids[1])?.state == .queued)
    // Another phone: nothing changes.
    await r.engine.forget(phoneID: "ffff")
    #expect(r.item(ids[1])?.state == .queued)
    await r.engine.forget(phoneID: phoneHex)
    #expect(ids.allSatisfy { r.item($0)?.state == .failed(.interrupted) })
}

@MainActor @Test func staleMessagesDoNotReachTheNextSession() async throws {
    let r = Rig(); defer { r.cleanUp() }
    let gate = Gate()
    r.gate = gate
    await r.connect()
    try await until("first endpoint") { r.sent.types == [.filesEndpoint] }
    // Queued behind the held endpoint: an accept for this session.
    await r.deliver(.filesOffer, r.offer("t1", size: 10))
    r.engine.disconnected()
    await r.connect()
    gate.open()
    try await until("second endpoint") { r.sent.types == [.filesEndpoint, .filesEndpoint] }
    // Absence: the old session's accept never goes.
    try await Task.sleep(for: .milliseconds(50))
    #expect(r.sent.types == [.filesEndpoint, .filesEndpoint])
}

@MainActor @Test func onFinishedComesAfterSendReturns() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let folder = r.dir.appendingPathComponent("Album", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    final class Box { var returned: [String] = []; var seen: [Bool] = [] }
    let box = Box()
    r.engine.onFinished = { item, _, _ in box.seen.append(box.returned.contains(item.id)) }
    box.returned = r.engine.send(files: [folder])
    try await until("callback") { box.seen.count == 1 }
    #expect(box.seen == [true])
}

@MainActor @Test func offerWithLiveIDIsDenied() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let id = try #require(r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")]).first)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    await r.deliver(.filesOffer, r.offer(id, size: 10))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
    #expect(r.item(id)?.state == .waiting)
    #expect(r.item(id)?.direction == .send)
    #expect(r.engine.transfers.filter { $0.id == id }.count == 1)
    // A link for the wrong direction does not touch the send either.
    let (mac, _) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneSends, context: id))
    #expect(mac.isClosed)
    #expect(r.item(id)?.state == .waiting)
}

@MainActor @Test func failedWithoutReasonMapsTheSameWay() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let id = try #require(r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")]).first)
    var f = AMTransferFailed(); f.transferID = id
    await r.deliver(.filesFailed, f)
    #expect(r.item(id)?.state == .failed(.io))

    let request = r.engine.nextRequestID()
    var result: Result<URL, TransferFailure>?
    r.engine.expect(requestID: request, destination: .folder(r.dir)) { result = $0 }
    var g = AMTransferFailed(); g.requestID = request
    await r.deliver(.filesFailed, g)
    #expect(result == .failure(.transfer(.io)))
}

@MainActor @Test func zeroByteTransferBothDirections() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // An empty file still gets its bulk link (one per transfer, SPEC section 13), with no bytes on it.
    let phone = try await r.startReceive(r.offer("t1", name: "empty.txt", size: 0))
    await r.complete("t1", sha(Data()))
    let saved = r.dir.appendingPathComponent("empty.txt")
    try await until("received") { r.item("t1")?.state == .done(saved) }
    #expect(try Data(contentsOf: saved).isEmpty)
    phone.close()

    let id = try #require(r.engine.send(files: [try r.write(Data(), as: "nothing.txt")]).first)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    #expect(r.sent.of(.filesOffer, AMTransferOffer.self).first?.size == 0)
    #expect(try await r.phoneTakes(id, size: 0).isEmpty)
    #expect(r.sent.of(.filesComplete, AMTransferComplete.self).first?.sha256 == sha(Data()))
    try await until("done") { r.item(id)?.state == .done(nil) }
}

@MainActor @Test func collisionIgnoresCaseAndNormalization() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // On disk: decomposed and upper case. Offered: precomposed and lower case.
    _ = try r.write(Data("old".utf8), as: "CAFE\u{301}.TXT")
    let bytes = randomBytes(50)
    let phone = try await r.startReceive(r.offer("t1", name: "caf\u{e9}.txt", size: 50))
    try await phone.send(bytes)
    await r.complete("t1", sha(bytes))
    let expected = r.dir.appendingPathComponent("caf\u{e9} (1).txt")
    try await until("done") { r.item("t1")?.state == .done(expected) }
    #expect(try Data(contentsOf: expected) == bytes)
    #expect(r.files().count == 2)
}

@MainActor @Test func noTargetOfferWithoutFilesButTargetOfferWithBrowse() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect(shared: ["browse.v1"])
    let plain = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")])
    #expect(r.item(plain[0])?.state == .failed(.interrupted))
    var target = AMBrowseTarget()
    target.rootID = "r1"; target.dirPath = "Docs"
    let write = r.engine.send(files: [try r.write(randomBytes(10), as: "b.txt")], target: target)
    try await until("offer") { !r.sent.of(.filesOffer, AMTransferOffer.self).isEmpty }
    let offers = r.sent.of(.filesOffer, AMTransferOffer.self)
    #expect(offers.map(\.transferID) == [write[0]])
    #expect(offers.first?.target == target)
}

// MARK: Task 7: late bulk port, what the UI lists

@MainActor @Test func endpointSentWhenPortArrivesAfterConnect() async throws {
    let r = Rig(); defer { r.cleanUp() }
    // The bulk listener is still coming back after wake when the phone reconnects.
    r.bulk.port = nil
    await r.connect()
    r.engine.bulkPortChanged()
    try await Task.sleep(for: .milliseconds(30))
    #expect(r.sent.all.isEmpty)

    r.bulk.port = 5000
    r.engine.bulkPortChanged()
    try await until("files.endpoint") { r.sent.types == [.filesEndpoint] }
    #expect(r.sent.of(.filesEndpoint, AMBulkEndpoint.self).map(\.port) == [5000])
    // The same port again is not announced twice.
    r.engine.bulkPortChanged()
    // A new port is.
    r.bulk.port = 5001
    r.engine.bulkPortChanged()
    try await until("second endpoint") { r.sent.types.count == 2 }
    #expect(r.sent.of(.filesEndpoint, AMBulkEndpoint.self).map(\.port) == [5000, 5001])

    // Not connected, or no bulk capability shared: nothing.
    r.engine.disconnected()
    r.bulk.port = 5002
    r.engine.bulkPortChanged()
    await r.connect(shared: ["notify.v1"])
    r.bulk.port = 5003
    r.engine.bulkPortChanged()
    try await until("still two") { r.sent.types.count == 2 }
    // Absence: nothing more goes.
    try await Task.sleep(for: .milliseconds(30))
    #expect(r.sent.types.count == 2)

    // A reconnect announces the port at connect, and only once.
    await r.connect(shared: ["photos.v1"])
    r.engine.bulkPortChanged()
    try await until("reconnect endpoint") {
        r.sent.of(.filesEndpoint, AMBulkEndpoint.self).map(\.port) == [5000, 5001, 5003]
    }
    // Absence: announced once only.
    try await Task.sleep(for: .milliseconds(30))
    #expect(r.sent.of(.filesEndpoint, AMBulkEndpoint.self).map(\.port) == [5000, 5001, 5003])
}

@MainActor @Test func macRefusalsAreNotListed() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    // A feature that is off on the Mac.
    r.destination = .refuse(.disabled)
    await r.deliver(.filesOffer, r.offer("t1", size: 10))
    // An answer to a request the Mac never made.
    await r.deliver(.filesOffer, r.offer("t2", size: 10, requestID: 77))
    try await until("rejects") { r.sent.of(.filesReject, AMTransferReject.self).count == 2 }
    #expect(r.engine.transfers.isEmpty)
    #expect(r.engine.lastFailure(.receive) == nil)
    // Still reported to whoever watches endings.
    #expect(r.finished.map(\.item.id) == ["t1", "t2"])
    #expect(r.finished.map(\.item.state) == [.failed(.disabled), .failed(.denied)])

    // A refusal the user can act on is listed.
    r.destination = .folder(r.dir)
    r.free = 0
    await r.deliver(.filesOffer, r.offer("t3", size: 10))
    try await until("no space") { r.item("t3")?.state == .failed(.noSpace) }
    #expect(r.engine.lastFailure(.receive)?.newest.id == "t3")
}

@MainActor @Test func lastFailureStaysUntilNextTransferStarts() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let a = try r.write(randomBytes(10), as: "a.txt")
    let b = try r.write(randomBytes(10), as: "b.txt")
    _ = r.engine.send(files: [a, b])
    try await until("first offer") { r.sent.of(.filesOffer, AMTransferOffer.self).count == 1 }
    var reject = AMTransferReject(); reject.transferID = "m1"; reject.reason = .noSpace
    await r.deliver(.filesReject, reject)
    #expect(r.engine.lastFailure(.send)?.newest.id == "m1")
    #expect(r.engine.lastFailure(.send)?.newest.state == .failed(.noSpace))
    #expect(r.engine.lastFailure(.send)?.count == 1)
    // The rest of the same batch going on does not hide it.
    try await until("second offer") { r.item("m2")?.state == .waiting }
    #expect(r.engine.lastFailure(.send)?.newest.id == "m1")

    // The user cancelling is not a failure to report.
    r.engine.cancel("m2")
    #expect(r.item("m2")?.state == .cancelled)
    #expect(r.engine.lastFailure(.send)?.count == 1)

    // A phone offer (a screenshot, say) is the other direction: "Couldn't send" stays.
    await r.deliver(.filesOffer, r.offer("t1", size: 10))
    #expect(r.engine.lastFailure(.send)?.newest.id == "m1")

    // A new send clears it; the phone cancelling that one is a failure again.
    _ = r.engine.send(files: [a])
    #expect(r.engine.lastFailure(.send) == nil)
    try await until("third offer") { r.item("m3")?.state == .waiting }
    var cancel = AMTransferCancel(); cancel.transferID = "m3"
    await r.deliver(.filesCancel, cancel)
    #expect(r.engine.lastFailure(.send)?.newest.id == "m3")
    #expect(r.engine.lastFailure(.send)?.newest.state == .cancelled)
    #expect(r.engine.lastFailure(.receive) == nil)
}

@MainActor @Test func lastFailureCountsTheBatch() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let files = try (1...3).map { try r.write(randomBytes(10), as: "f\($0).txt") }
    _ = r.engine.send(files: files)
    try await until("first offer") { r.item("m1")?.state == .waiting }
    var reject = AMTransferReject(); reject.transferID = "m1"; reject.reason = .noSpace
    await r.deliver(.filesReject, reject)
    try await until("second offer") { r.item("m2")?.state == .waiting }
    reject.transferID = "m2"
    await r.deliver(.filesReject, reject)
    #expect(r.engine.lastFailure(.send)?.count == 2)
    #expect(r.engine.lastFailure(.send)?.newest.id == "m2")
    #expect(r.engine.lastFailure(.send)?.sameReason == true)
    // The connection going takes the third: three failed, for two reasons.
    r.engine.disconnected()
    #expect(r.engine.lastFailure(.send)?.count == 3)
    #expect(r.engine.lastFailure(.send)?.newest.state == .failed(.interrupted))
    #expect(r.engine.lastFailure(.send)?.sameReason == false)
}

@MainActor @Test func targetedSendsAreMarked() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect(shared: ["files.v1", "browse.v1"])
    let plain = r.engine.send(files: [try r.write(randomBytes(10), as: "a.txt")])
    var target = AMBrowseTarget()
    target.rootID = "r1"
    let write = r.engine.send(files: [try r.write(randomBytes(10), as: "b.txt")], target: target)
    #expect(r.item(plain[0])?.targeted == false)
    #expect(r.item(write[0])?.targeted == true)
}

private func item(_ id: String, _ direction: TransferItem.Direction, _ state: TransferItem.State) -> TransferItem {
    TransferItem(id: id, direction: direction, name: id, size: 10, kind: .file, state: state)
}

@Test func menuShowsActivePerDirectionAndWaitingCount() {
    // Nothing under way: no lines. Finished ones are never in the menu.
    #expect(TransferMenu.lines([]).isEmpty)
    #expect(TransferMenu.lines([item("d", .send, .done(nil)), item("f", .receive, .failed(.io))]).isEmpty)

    // One per direction, sends first, with how many more wait behind it.
    let lines = TransferMenu.lines([
        item("r1", .receive, .active), item("s1", .send, .active), item("s2", .send, .queued),
        item("r2", .receive, .queued), item("s3", .send, .queued), item("s0", .send, .done(nil)),
    ])
    #expect(lines.map(\.item.id) == ["s1", "r1"])
    #expect(lines.map(\.waiting) == [2, 1])

    // The one under way is shown even when it is not first in the list.
    let waiting = TransferMenu.lines([item("s1", .send, .queued), item("s2", .send, .waiting)])
    #expect(waiting.map(\.item.id) == ["s2"])
    #expect(waiting.map(\.waiting) == [1])

    // Only queued ones (between two transfers): the first of them.
    let queued = TransferMenu.lines([item("r1", .receive, .queued), item("r2", .receive, .queued)])
    #expect(queued.map(\.item.id) == ["r1"])
    #expect(queued.map(\.waiting) == [1])
}

@Test func screenshotReceivesAreNotMenuLines() {
    // R13: phone screenshots arrive on their own; the menu shows only what the user moves.
    func shot(_ id: String, _ state: TransferItem.State) -> TransferItem {
        TransferItem(id: id, direction: .receive, name: id, size: 10, kind: .screenshot, state: state)
    }
    #expect(TransferMenu.lines([shot("x1", .active), shot("x2", .queued)]).isEmpty)
    let lines = TransferMenu.lines([
        shot("x1", .active), item("r1", .receive, .queued), shot("x2", .queued), item("r2", .receive, .queued),
        item("s1", .send, .active),
    ])
    #expect(lines.map(\.item.id) == ["s1", "r1"])
    #expect(lines.map(\.waiting) == [0, 1])
}

@Test func sendableFilesSkipFoldersAndPackages() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-sendable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("Notes.rtfd"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
    try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("Folder"))
    let urls = ["a.txt", "Folder", "Notes.rtfd", "link"].map { dir.appendingPathComponent($0) }
    let split = SendableFiles.split(urls)
    #expect(split.files.map(\.lastPathComponent) == ["a.txt"])
    #expect(split.skipped == 3)
}
