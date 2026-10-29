import AMProtocol
import ConnectionCore
import CryptoKit
import Foundation
import Observation
import os
import SwiftProtobuf
import UniformTypeIdentifiers

/// Time limits and the free-space margin for transfers (Global Constraints, SPEC sections 13 and 16).
public struct TransferTiming: Sendable {
    /// How long a sent offer waits for `files.accept`.
    public var acceptTimeout: Duration
    /// A transfer that moves no bytes for this long fails `TIMED_OUT`. It also bounds the wait
    /// for the bulk connection after an accept, and for the answer after the last byte.
    public var stallTimeout: Duration
    /// The receiver sends `files.progress` at most this often.
    public var progressInterval: Duration
    /// An offer is rejected `NO_SPACE` when its size plus this exceeds the free space.
    public var freeMargin: Int64

    public init(acceptTimeout: Duration = .seconds(30), stallTimeout: Duration = .seconds(30),
                progressInterval: Duration = .milliseconds(500), freeMargin: Int64 = 64 << 20) {
        self.acceptTimeout = acceptTimeout
        self.stallTimeout = stallTimeout
        self.progressInterval = progressInterval
        self.freeMargin = freeMargin
    }
}

/// File transfers with the phone, both ways (SPEC sections 13 and 16). One transfer runs at a
/// time per direction; the bytes go over bulk connections, read and written off the main actor.
/// Every transfer uses its own bulk connection, an empty file too (it carries no bytes).
/// Transfers live for one session only: nothing is queued while no phone is connected, and
/// nothing queued in one session reaches the next.
@MainActor
@Observable
public final class TransferEngine: SessionFeature {
    public let messagePrefixes = ["files."]

    /// Active and queued transfers first, in arrival order, then the last 20 finished, newest first.
    public private(set) var transfers: [TransferItem] = []

    /// Called once for every transfer that ends (done, failed or cancelled), with where a
    /// received file was saved. Check `item.state`. `item.name` is the sanitized name; the
    /// offer is as it went over the wire, so a phone offer's `name` is the phone's raw name and
    /// must not be used as a path. Never called before `send(files:)` has returned the item's ID.
    @ObservationIgnored public var onFinished: (@MainActor (TransferItem, AMTransferOffer, URL?) -> Void)?

    nonisolated static let chunkBytes = BulkLink.bufferBytes
    static let keptFinished = 20
    /// Any of these makes the Mac announce its bulk port.
    static let bulkCapabilities: Set<String> = ["files.v1", "screenshots.v1", "photos.v1", "browse.v1"]
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "transfer")

    @ObservationIgnored private let bulk: any BulkGrants
    @ObservationIgnored private let destination: @MainActor (AMTransferOffer) -> IncomingDestination
    @ObservationIgnored private let freeBytes: (URL) -> Int64?
    @ObservationIgnored private let timing: TransferTiming
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private let outbox: AsyncStream<Outgoing>.Continuation

    @ObservationIgnored private var isConnected = false
    /// The phone in session, while connected.
    @ObservationIgnored private var phoneID: String?
    /// The phone shares `files.v1`: only then does the Mac offer files.
    @ObservationIgnored private var filesShared = false
    /// Moves on with every connect and disconnect; messages queued in an older session are dropped.
    @ObservationIgnored private let session = SessionCounter()
    /// Transfers that have not ended, in arrival order.
    @ObservationIgnored private var jobs: [Job] = []
    /// Newest first, at most `keptFinished`.
    @ObservationIgnored private var finished: [TransferItem] = []
    /// Requests (photos, browse) whose answer is an offer carrying their ID.
    @ObservationIgnored private var expected: [UInt64: Expectation] = [:]
    @ObservationIgnored private var lastRequestID: UInt64 = 0

    public init(bulk: any BulkGrants,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                destination: @escaping @MainActor (AMTransferOffer) -> IncomingDestination,
                freeBytes: @escaping (URL) -> Int64? = FreeSpace.available,
                timing: TransferTiming = .init(), newID: @escaping () -> String = { UUID().uuidString }) {
        self.bulk = bulk
        self.destination = destination
        self.freeBytes = freeBytes
        self.timing = timing
        self.newID = newID
        // One sender, so messages leave in the order they were queued.
        let (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        outbox = continuation
        let session = self.session
        Task {
            for await o in stream where o.session == session.value { await send(o.type, o.message) }
        }
    }

    deinit { outbox.finish() }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        session.value += 1
        isConnected = true
        self.phoneID = phoneID
        filesShared = shared.contains("files.v1")
        // Before any token: changing the allowed phone revokes every outstanding one.
        bulk.allow(peerFingerprint: Self.bytes(hex: phoneID))
        if !shared.isDisjoint(with: Self.bulkCapabilities), let port = bulk.port {
            var endpoint = AMBulkEndpoint()
            endpoint.port = UInt32(port)
            post(.filesEndpoint, endpoint)
        }
        pump()
    }

    /// Every transfer that has not ended fails `INTERRUPTED`; nothing is sent.
    public func disconnected() {
        session.value += 1
        isConnected = false
        phoneID = nil
        filesShared = false
        bulk.revokeAll()
        bulk.allow(peerFingerprint: nil)
        for job in jobs { finish(job, .failed(.interrupted), notice: .none) }
        let waiting = expected
        expected = [:]
        for e in waiting.values { e.completion(.failure(.transfer(.interrupted))) }
    }

    public func message(_ envelope: AMEnvelope) async {
        let p = envelope.payload
        switch MessageType(rawValue: envelope.type) {
        case .filesOffer: if let m = try? AMTransferOffer(serializedBytes: p) { offered(m) }
        case .filesAccept: if let m = try? AMTransferAccept(serializedBytes: p) { accepted(m) }
        case .filesReject: if let m = try? AMTransferReject(serializedBytes: p) { rejected(m) }
        case .filesProgress: if let m = try? AMTransferProgress(serializedBytes: p) { progressed(m) }
        case .filesComplete: if let m = try? AMTransferComplete(serializedBytes: p) { completed(m) }
        case .filesReceived: if let m = try? AMTransferReceived(serializedBytes: p) { receivedByPhone(m) }
        case .filesCancel: if let m = try? AMTransferCancel(serializedBytes: p) { cancelledByPhone(m) }
        case .filesFailed: if let m = try? AMTransferFailed(serializedBytes: p) { failedOnPhone(m) }
        default: break
        }
    }

    /// Nothing is kept per phone. Forgetting the phone in session ends whatever it still has
    /// queued or under way.
    public func forget(phoneID: String) async {
        guard phoneID == self.phoneID || self.phoneID == nil else { return }
        for job in jobs { finish(job, .failed(.interrupted), notice: .none) }
    }

    // MARK: API

    /// Queues `files` for the phone in session, into `target` (a browse root) when given, else
    /// its Downloads. With no phone connected, or one that does not share `files.v1`, each file
    /// fails `INTERRUPTED` at once; a folder or an unreadable file fails `IO` at once. Returns
    /// the transfer IDs.
    @discardableResult
    public func send(files: [URL], target: AMBrowseTarget? = nil) -> [String] {
        var ids: [String] = []
        for url in files {
            var id = newID()
            // IDs stay unique among live transfers, so a phone message names one transfer only.
            while jobs.contains(where: { $0.item.id == id }) { id = newID() }
            ids.append(id)
            var offer = AMTransferOffer()
            offer.transferID = id
            offer.name = FileNameSanitizer.sanitize(url.lastPathComponent)
            offer.kind = .file
            if let target { offer.target = target }
            guard isConnected, filesShared else {
                let item = TransferItem(id: id, direction: .send, name: offer.name, size: 0, kind: .file,
                                        state: .failed(.interrupted))
                Self.log.info("\(id, privacy: .public) not sent: no phone takes files")
                record(item, offer: offer, url: nil, deferred: true)
                continue
            }
            guard let source = Self.source(url) else {
                let item = TransferItem(id: id, direction: .send, name: offer.name, size: 0, kind: .file,
                                        state: .failed(.io))
                Self.log.info("\(id, privacy: .public) not sent: IO")
                record(item, offer: offer, url: nil, deferred: true)
                continue
            }
            offer.size = source.size
            offer.mime = source.mime
            offer.modifiedMs = source.modifiedMs
            let item = TransferItem(id: id, direction: .send, name: offer.name, size: source.size, kind: .file,
                                    state: .queued)
            jobs.append(Job(item: item, offer: offer, source: url))
        }
        publish()
        pump()
        return ids
    }

    /// A new ID for a Mac request (photos, browse), shared by every feature.
    public func nextRequestID() -> UInt64 {
        lastRequestID += 1
        return lastRequestID
    }

    /// The phone answers request `requestID` with an offer carrying it: that file goes to
    /// `destination`, and `completion` gets the result. Any other request ID is denied.
    public func expect(requestID: UInt64, destination: IncomingDestination,
                       completion: @escaping @MainActor (Result<URL, TransferFailure>) -> Void) {
        expected[requestID] = Expectation(destination: destination, completion: completion)
    }

    /// The request was answered with a failure (`browse.result`, `files.failed`) instead of an offer.
    public func failRequest(_ requestID: UInt64, _ failure: TransferFailure) {
        expected.removeValue(forKey: requestID)?.completion(.failure(failure))
    }

    /// Stops a transfer; the phone is told unless it never heard of it.
    public func cancel(_ id: String) {
        guard let job = jobs.first(where: { $0.item.id == id }) else { return }
        let offered = job.item.direction == .receive || job.item.state != .queued
        finish(job, .cancelled, notice: offered ? .cancel : .none)
    }

    /// A bulk connection whose token redeemed: `PHONE_RECEIVES` carries a Mac send,
    /// `PHONE_SENDS` a Mac receive. Anything that matches no waiting transfer is closed.
    public func link(_ pipe: any BulkPipe, grant: BulkGrant) {
        let direction: TransferItem.Direction
        switch grant.role {
        case .phoneReceives: direction = .send
        case .phoneSends: direction = .receive
        default:
            pipe.close()
            return
        }
        guard let job = live(grant.context, direction), job.pipe == nil, job.item.state == .waiting else {
            pipe.close()
            return
        }
        if direction == .send {
            job.pipe = pipe
            startSending(job)
        } else {
            startReceiving(job, pipe)
        }
    }

    // MARK: Mac sends

    private func pump() {
        guard isConnected else { return }
        pumpSends()
        pumpReceives()
    }

    private func pumpSends() {
        guard !jobs.contains(where: { $0.item.direction == .send && $0.item.state != .queued }),
              let job = jobs.first(where: { $0.item.direction == .send })
        else { return }
        job.offer.token = bulk.issue(role: .phoneReceives, context: job.item.id)
        job.item.state = .waiting
        job.limit = timing.acceptTimeout
        watch(job)
        post(.filesOffer, job.offer)
        publish()
    }

    private func accepted(_ a: AMTransferAccept) {
        guard let job = live(a.transferID, .send), job.item.state == .waiting, !job.accepted else { return }
        job.accepted = true
        job.limit = timing.stallTimeout
        job.meter.touch()
        startSending(job)
    }

    /// Streams the file once the offer is accepted and its bulk connection is in, in either order.
    private func startSending(_ job: Job) {
        guard job.accepted, let pipe = job.pipe, job.worker == nil, let source = job.source else { return }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source)
        } catch {
            finish(job, .failed(.io), notice: .failed(.io))
            return
        }
        job.item.state = .active
        job.started = .now
        job.meter.touch()
        publish()
        let size = job.item.size, meter = job.meter
        job.worker = Task.detached { [weak self] in
            let result: Result<Data, Stop>
            do {
                result = .success(try await Self.write(handle, size: size, to: pipe, meter: meter))
            } catch {
                result = .failure(error as? Stop ?? .interrupted)
            }
            await self?.sent(job, result)
        }
    }

    private func sent(_ job: Job, _ result: Result<Data, Stop>) {
        guard isLive(job) else { return }
        switch result {
        case let .success(hash):
            job.completeSent = true
            job.meter.touch()
            var c = AMTransferComplete()
            c.transferID = job.item.id
            c.sha256 = hash
            post(.filesComplete, c)
        case let .failure(stop):
            finish(job, .failed(stop.error), notice: .failed(stop.error))
        }
    }

    private func rejected(_ r: AMTransferReject) {
        guard let job = live(r.transferID, .send), job.item.state == .waiting else { return }
        finish(job, .failed(r.reason), notice: .none)
    }

    private func progressed(_ p: AMTransferProgress) {
        guard let job = live(p.transferID, .send) else { return }
        job.item.done = min(p.bytesDone, job.item.size)
        publish()
    }

    private func receivedByPhone(_ r: AMTransferReceived) {
        guard let job = live(r.transferID, .send), job.completeSent else { return }
        finish(job, .done(nil), notice: .none)
    }

    // MARK: Mac receives

    private func offered(_ o: AMTransferOffer) {
        // An ID already in use (a repeated offer, or one of the Mac's own) is refused; the live
        // transfer is left alone and gets no second entry.
        guard !jobs.contains(where: { $0.item.id == o.transferID }) else {
            var r = AMTransferReject()
            r.transferID = o.transferID
            r.reason = .denied
            post(.filesReject, r)
            return
        }
        let item = TransferItem(id: o.transferID, direction: .receive, name: FileNameSanitizer.sanitize(o.name),
                                size: o.size, kind: o.kind, state: .queued)
        let job = Job(item: item, offer: o, source: nil)
        jobs.append(job)
        if o.requestID != 0 {
            guard let e = expected.removeValue(forKey: o.requestID) else {
                finish(job, .failed(.denied), notice: .reject(.denied))
                return
            }
            job.destination = e.destination
            job.completion = e.completion
        } else {
            job.destination = destination(o)
        }
        if case let .refuse(reason) = job.destination {
            finish(job, .failed(reason), notice: .reject(reason))
            return
        }
        publish()
        pump()
    }

    private func pumpReceives() {
        guard !jobs.contains(where: { $0.item.direction == .receive && $0.item.state != .queued }),
              let job = jobs.first(where: { $0.item.direction == .receive }),
              let folder = job.folder
        else { return }
        if let free = freeBytes(folder) {
            let (need, overflow) = job.item.size.addingReportingOverflow(UInt64(max(timing.freeMargin, 0)))
            if overflow || need > UInt64(max(free, 0)) {
                finish(job, .failed(.noSpace), notice: .reject(.noSpace))
                return
            }
        }
        var a = AMTransferAccept()
        a.transferID = job.item.id
        a.token = bulk.issue(role: .phoneSends, context: job.item.id)
        job.item.state = .waiting
        job.limit = timing.stallTimeout
        watch(job)
        post(.filesAccept, a)
        publish()
    }

    private func startReceiving(_ job: Job, _ pipe: any BulkPipe) {
        job.pipe = pipe
        // Created here, on the main actor, so a failure can never leave one behind.
        guard let folder = job.folder else { return }
        let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part)
        else {
            try? FileManager.default.removeItem(at: part)
            finish(job, .failed(.io), notice: .failed(.io))
            return
        }
        job.part = part
        job.item.state = .active
        job.started = .now
        job.meter.touch()
        publish()
        let size = job.item.size, meter = job.meter, interval = timing.progressInterval
        let report: @Sendable (UInt64) async -> Void = { [weak self] done in await self?.receiving(job, done: done) }
        job.worker = Task.detached { [weak self] in
            let result: Result<Data, Stop>
            do {
                result = .success(try await Self.read(pipe, size: size, into: handle, meter: meter,
                                                      interval: interval, progress: report))
            } catch {
                result = .failure(error as? Stop ?? .interrupted)
            }
            await self?.bytesIn(job, result)
            guard case .success = result else { return }
            // Bytes past `size` fail the transfer; EOF, or the link closing when it ends, do not.
            if let extra = try? await pipe.receive(maximum: 1), !extra.isEmpty {
                await self?.bytesIn(job, .failure(.extraBytes))
            }
        }
    }

    private func receiving(_ job: Job, done: UInt64) {
        guard isLive(job) else { return }
        job.item.done = done
        var p = AMTransferProgress()
        p.transferID = job.item.id
        p.bytesDone = done
        post(.filesProgress, p)
        publish()
    }

    private func bytesIn(_ job: Job, _ result: Result<Data, Stop>) {
        guard isLive(job) else { return }
        switch result {
        case let .success(hash):
            job.bytesHash = hash
            job.item.done = job.item.size
            job.meter.touch()
            publish()
            finishReceiveIfReady(job)
        case let .failure(stop):
            finish(job, .failed(stop.error), notice: .failed(stop.error))
        }
    }

    private func completed(_ c: AMTransferComplete) {
        guard let job = live(c.transferID, .receive), job.item.state != .queued else { return }
        job.expectedHash = c.sha256
        finishReceiveIfReady(job)
    }

    /// Once every byte is in and `files.complete` has arrived, in either order.
    private func finishReceiveIfReady(_ job: Job) {
        guard let got = job.bytesHash, let want = job.expectedHash else { return }
        guard got == want else {
            finish(job, .failed(.hashMismatch), notice: .failed(.hashMismatch))
            return
        }
        let url: URL
        do {
            url = try place(job)
        } catch {
            finish(job, .failed(.io), notice: .failed(.io))
            return
        }
        job.part = nil
        var r = AMTransferReceived()
        r.transferID = job.item.id
        post(.filesReceived, r)
        finish(job, .done(url), notice: .none)
    }

    /// Moves the part file to its final name; never over an existing file in a folder.
    private func place(_ job: Job) throws -> URL {
        let fm = FileManager.default
        guard let part = job.part else { throw Stop.io }
        switch job.destination {
        case let .folder(folder):
            let taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map(FileNameSanitizer.key))
            let name = FileNameSanitizer.unique(job.item.name) {
                taken.contains(FileNameSanitizer.key($0)) || fm.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            let url = folder.appendingPathComponent(name)
            try fm.moveItem(at: part, to: url)
            return url
        case let .file(url):
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: url)
            }
            return url
        case .refuse, nil:
            throw Stop.io
        }
    }

    // MARK: either direction

    private func cancelledByPhone(_ c: AMTransferCancel) {
        guard let job = jobs.first(where: { $0.item.id == c.transferID }) else { return }
        finish(job, .cancelled, notice: .none)
    }

    // Live transfer IDs are unique across both directions (see `send(files:)` and `offered`),
    // so a cancel or failure, which names no direction, matches at most one transfer.

    private func failedOnPhone(_ f: AMTransferFailed) {
        let reason: AMTransferError = f.reason == .unspecified ? .io : f.reason
        if !f.transferID.isEmpty, let job = jobs.first(where: { $0.item.id == f.transferID }) {
            finish(job, .failed(reason), notice: .none)
        } else if f.requestID != 0 {
            failRequest(f.requestID, .transfer(reason))
        }
    }

    /// Fails a transfer that moved no bytes for its limit.
    private func watch(_ job: Job) {
        job.watchdog?.cancel()
        job.meter.touch()
        let tick = max(min(min(timing.acceptTimeout, timing.stallTimeout) / 5, .seconds(1)), .milliseconds(5))
        job.watchdog = Task { [weak self, weak job] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, let job, self.isLive(job) else { return }
                if job.meter.idle >= job.limit {
                    self.finish(job, .failed(.timedOut), notice: .failed(.timedOut))
                    return
                }
            }
        }
    }

    private enum Notice {
        case none, cancel
        case failed(AMTransferError)
        case reject(AMTransferError)
    }

    /// Ends `job`: closes its link, deletes its part file, revokes its token, tells the phone
    /// as `notice` says, answers its request, and starts the next transfer.
    private func finish(_ job: Job, _ state: TransferItem.State, notice: Notice) {
        guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
        jobs.remove(at: index)
        job.watchdog?.cancel()
        job.worker?.cancel()
        job.pipe?.close()
        bulk.revoke(context: job.item.id)
        if let part = job.part { try? FileManager.default.removeItem(at: part) }
        job.item.state = state

        let id = job.item.id
        switch notice {
        case .none:
            break
        case .cancel:
            var c = AMTransferCancel()
            c.transferID = id
            post(.filesCancel, c)
        case let .failed(reason):
            var f = AMTransferFailed()
            f.transferID = id
            f.reason = reason
            post(.filesFailed, f)
        case let .reject(reason):
            var r = AMTransferReject()
            r.transferID = id
            r.reason = reason
            post(.filesReject, r)
        }

        var url: URL?
        switch state {
        case let .done(saved):
            url = saved
            job.item.done = job.item.size
            logThroughput(job)
            if let saved { job.completion?(.success(saved)) }
        case let .failed(reason):
            Self.log.info("\(id, privacy: .public) failed: \(reason.rawValue, privacy: .public)")
            job.completion?(.failure(.transfer(reason)))
        case .cancelled:
            Self.log.info("\(id, privacy: .public) cancelled")
            job.completion?(.failure(.transfer(.cancelled)))
        case .queued, .waiting, .active:
            break
        }
        record(job.item, offer: job.offer, url: url)
        pump()
    }

    // MARK: helpers

    /// Adds a finished item and calls `onFinished`, on the next main-actor turn when `deferred`
    /// (inside `send(files:)`, whose caller must get the ID first).
    private func record(_ item: TransferItem, offer: AMTransferOffer, url: URL?, deferred: Bool = false) {
        finished.insert(item, at: 0)
        if finished.count > Self.keptFinished { finished.removeLast(finished.count - Self.keptFinished) }
        publish()
        if deferred {
            Task { [weak self] in self?.onFinished?(item, offer, url) }
        } else {
            onFinished?(item, offer, url)
        }
    }

    private func publish() {
        transfers = jobs.map(\.item) + finished
    }

    private func live(_ id: String, _ direction: TransferItem.Direction) -> Job? {
        jobs.first { $0.item.id == id && $0.item.direction == direction }
    }

    private func isLive(_ job: Job) -> Bool { jobs.contains { $0 === job } }

    private func post(_ type: MessageType, _ message: any SwiftProtobuf.Message & Sendable) {
        outbox.yield(Outgoing(session: session.value, type: type, message: message))
    }

    /// `<id> <bytes> B in <ms> ms = <MB/s> MB/s`: no names, no content.
    private func logThroughput(_ job: Job) {
        let elapsed = ContinuousClock.now - (job.started ?? .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let mbps = ms > 0 ? Double(job.item.size) / 1e6 / (ms / 1000) : 0
        let id = job.item.id, bytes = job.item.size, rate = String(format: "%.1f", mbps)
        Self.log.info("\(id, privacy: .public) \(bytes, privacy: .public) B in \(Int(ms.rounded()), privacy: .public) ms = \(rate, privacy: .public) MB/s")
    }

    private struct Source {
        let size: UInt64
        let mime: String
        let modifiedMs: Int64
    }

    /// Size, type and date of a readable regular file; nil for a folder or anything unreadable.
    private static func source(_ url: URL) -> Source? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                                    .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: resolved.path)
        else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let modified = values.contentModificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
        return Source(size: UInt64(size), mime: mime, modifiedMs: modified)
    }

    nonisolated static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private nonisolated static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: byte loops (off the main actor)

    /// Writes exactly `size` bytes of `handle` to `pipe` in 256 KiB chunks; returns their SHA-256.
    private nonisolated static func write(_ handle: FileHandle, size: UInt64, to pipe: any BulkPipe,
                                          meter: Meter) async throws -> Data {
        defer { try? handle.close() }
        var hasher = SHA256()
        var left = size
        while left > 0 {
            try Task.checkCancellation()
            let want = Int(min(UInt64(chunkBytes), left))
            let chunk: Data
            do {
                // The file got shorter since it was offered: that is an IO failure.
                guard let read = try handle.read(upToCount: want), !read.isEmpty else { throw Stop.io }
                chunk = read
            } catch {
                throw Stop.io
            }
            hasher.update(data: chunk)
            do { try await pipe.send(chunk) } catch { throw Stop.interrupted }
            left -= UInt64(chunk.count)
            meter.touch()
        }
        return Data(hasher.finalize())
    }

    /// Reads exactly `size` bytes from `pipe` into `handle`, reporting progress at most every
    /// `interval`; returns their SHA-256.
    private nonisolated static func read(_ pipe: any BulkPipe, size: UInt64, into handle: FileHandle,
                                         meter: Meter, interval: Duration,
                                         progress: @escaping @Sendable (UInt64) async -> Void) async throws -> Data {
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: UInt64 = 0
        var lastReport: ContinuousClock.Instant?
        while done < size {
            try Task.checkCancellation()
            let received: Data?
            do { received = try await pipe.receive(maximum: chunkBytes) } catch { throw Stop.interrupted }
            guard let chunk = received else { throw Stop.interrupted }
            if UInt64(chunk.count) > size - done { throw Stop.extraBytes }
            do { try handle.write(contentsOf: chunk) } catch { throw Stop.io }
            hasher.update(data: chunk)
            done += UInt64(chunk.count)
            meter.touch()
            let now = ContinuousClock.now
            if lastReport.map({ now - $0 >= interval }) ?? true {
                lastReport = now
                await progress(done)
            }
        }
        return Data(hasher.finalize())
    }
}

// MARK: private types

/// Why a byte loop stopped.
private enum Stop: Error {
    /// The file could not be read or written.
    case io
    /// The link ended or failed before every byte moved.
    case interrupted
    /// The sender wrote more than the offered size.
    case extraBytes

    var error: AMTransferError {
        switch self {
        case .io: .io
        case .interrupted: .interrupted
        case .extraBytes: .hashMismatch
        }
    }
}

private struct Outgoing: Sendable {
    let session: UInt64
    let type: MessageType
    let message: any SwiftProtobuf.Message & Sendable
}

private struct Expectation {
    let destination: IncomingDestination
    let completion: @MainActor (Result<URL, TransferFailure>) -> Void
}

@MainActor
private final class SessionCounter {
    var value: UInt64 = 0
}

/// When bytes last moved; written by the byte loops, read by the watchdog.
private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() { lock.withLock { last = .now } }
    var idle: Duration { lock.withLock { ContinuousClock.now - last } }
}

/// One transfer that has not ended.
@MainActor
private final class Job {
    var item: TransferItem
    var offer: AMTransferOffer
    /// The file a Mac send reads.
    let source: URL?
    var accepted = false
    var completeSent = false
    var destination: IncomingDestination?
    var completion: (@MainActor (Result<URL, TransferFailure>) -> Void)?
    var part: URL?
    /// SHA-256 of the bytes received, once all are in.
    var bytesHash: Data?
    /// From `files.complete`.
    var expectedHash: Data?
    var pipe: (any BulkPipe)?
    var worker: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    /// How long the watchdog lets the transfer go without moving bytes.
    var limit: Duration = .seconds(30)
    let meter = Meter()
    var started: ContinuousClock.Instant?

    init(item: TransferItem, offer: AMTransferOffer, source: URL?) {
        self.item = item
        self.offer = offer
        self.source = source
    }

    /// The folder a received file is written in.
    var folder: URL? {
        switch destination {
        case let .folder(url): url
        case let .file(url): url.deletingLastPathComponent()
        case .refuse, nil: nil
        }
    }
}
