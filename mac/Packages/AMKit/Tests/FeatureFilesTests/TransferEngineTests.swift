import AMProtocol
import ConnectionCore
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureFiles

// MARK: test doubles

/// Records every `BulkGrants` call, in order.
@MainActor
final class FakeBulk: BulkGrants {
    var port: UInt16? = 4242
    var calls: [String] = []
    var allowed: [Data?] = []
    var issued: [(role: AMBulkRole, context: String, token: Data)] = []
    var revoked: [String] = []
    var revokeAllCount = 0

    func allow(peerFingerprint: Data?) {
        calls.append("allow")
        allowed.append(peerFingerprint)
    }

    func issue(role: AMBulkRole, context: String) -> Data {
        calls.append("issue")
        let token = Data("token-\(issued.count)".utf8)
        issued.append((role, context, token))
        return token
    }

    func revoke(context: String) { revoked.append(context) }

    func revokeAll() {
        calls.append("revokeAll")
        revokeAllCount += 1
    }
}

/// One direction of an in-memory byte pipe.
private final class ByteQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var ended = false
    private var aborted = false
    private var waiter: CheckedContinuation<Data?, Error>?

    struct Closed: Error {}

    func push(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let w = waiter
        waiter = nil
        let head = w == nil ? nil : take(Int.max)
        lock.unlock()
        if let w { w.resume(returning: head) }
    }

    /// The writer is done: the reader gets the rest, then nil.
    func end() {
        lock.lock()
        ended = true
        let w = waiter
        waiter = nil
        let head = w == nil ? nil : (buffer.isEmpty ? nil : take(Int.max))
        lock.unlock()
        w?.resume(returning: head)
    }

    /// The reader closed its end: a pending read throws.
    func abort() {
        lock.lock()
        aborted = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: Closed())
    }

    func pop(_ maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            lock.lock()
            if aborted {
                lock.unlock()
                c.resume(throwing: Closed())
            } else if !buffer.isEmpty {
                let head = take(maximum)
                lock.unlock()
                c.resume(returning: head)
            } else if ended {
                lock.unlock()
                c.resume(returning: nil)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    /// Caller holds the lock.
    private func take(_ maximum: Int) -> Data {
        let head = Data(buffer.prefix(maximum))
        buffer = Data(buffer.dropFirst(head.count))
        return head
    }
}

/// One end of an in-memory bulk connection.
final class MemoryPipe: BulkPipe, @unchecked Sendable {
    private let inbox: ByteQueue
    private let outbox: ByteQueue
    private let lock = NSLock()
    private var closedFlag = false
    private var sent: UInt64 = 0

    fileprivate init(inbox: ByteQueue, outbox: ByteQueue) {
        self.inbox = inbox
        self.outbox = outbox
    }

    /// (Mac end, phone end).
    static func pair() -> (MemoryPipe, MemoryPipe) {
        let toMac = ByteQueue(), toPhone = ByteQueue()
        return (MemoryPipe(inbox: toMac, outbox: toPhone), MemoryPipe(inbox: toPhone, outbox: toMac))
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }
    var bytesSent: UInt64 { lock.lock(); defer { lock.unlock() }; return sent }

    func receive(maximum: Int) async throws -> Data? {
        try await inbox.pop(maximum)
    }

    func send(_ data: Data) async throws {
        let closed = lock.withLock {
            if !closedFlag { sent += UInt64(data.count) }
            return closedFlag
        }
        if closed { throw ByteQueue.Closed() }
        outbox.push(data)
    }

    func close() {
        lock.lock()
        let was = closedFlag
        closedFlag = true
        lock.unlock()
        guard !was else { return }
        inbox.abort()
        outbox.end()
    }
}

/// Every message the engine sent, in order.
@MainActor
final class SentLog {
    var all: [(type: MessageType, message: any SwiftProtobuf.Message)] = []
    var types: [MessageType] { all.map(\.type) }

    func of<M: SwiftProtobuf.Message>(_ type: MessageType, _: M.Type) -> [M] {
        all.filter { $0.type == type }.compactMap { $0.message as? M }
    }
}

private struct Waited: Error {}

/// Polls `condition` on the main actor until it holds, or fails after `timeout`.
@MainActor
func until(_ what: String = "condition", timeout: Duration = .seconds(5),
           _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("timed out waiting for \(what)")
            throw Waited()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Reads exactly `count` bytes from `pipe` (or fails the test after 5 s).
func readAll(_ pipe: MemoryPipe, _ count: Int) async throws -> Data {
    var out = Data()
    while out.count < count {
        let chunk = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await pipe.receive(maximum: 1 << 20) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                pipe.close()
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let chunk else { break }
        out.append(chunk)
    }
    return out
}

func randomBytes(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}

func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .files
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

let phoneHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

extension TransferTiming {
    static let fast = TransferTiming(acceptTimeout: .seconds(5), stallTimeout: .seconds(5),
                                     progressInterval: .zero, freeMargin: 64 << 20)
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
    private(set) var engine: TransferEngine!

    init(timing: TransferTiming = .fast) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        destination = .folder(dir)
        var n = 0
        engine = TransferEngine(
            bulk: bulk,
            send: { [weak self] type, message in self?.sent.all.append((type, message)) },
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
    try await phone.send(randomBytes(1000))
    let start = ContinuousClock.now
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

extension Data {
    init(hexString: String) {
        var out = Data()
        var it = hexString.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        self = out
    }
}
