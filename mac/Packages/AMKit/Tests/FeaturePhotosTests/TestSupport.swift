import AMProtocol
import ConnectionCore
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing

// Test doubles, as in FeatureFilesTests (test targets cannot share sources).

/// Records every `BulkGrants` call.
@MainActor
final class FakeBulk: BulkGrants {
    var port: UInt16? = 4242
    var allowed: [Data?] = []
    var issued: [(role: AMBulkRole, context: String, token: Data)] = []
    var revoked: [String] = []
    var revokeAllCount = 0

    func allow(peerFingerprint: Data?) { allowed.append(peerFingerprint) }

    func issue(role: AMBulkRole, context: String) -> Data {
        let token = Data("token-\(issued.count)".utf8)
        issued.append((role, context, token))
        return token
    }

    func revoke(context: String) { revoked.append(context) }
    func revokeAll() { revokeAllCount += 1 }
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

/// Every message sent, in order.
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

func envelope<M: SwiftProtobuf.Message>(_ channel: AMChannel, _ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = channel
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

let phoneHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

/// `id | length | bytes` records as the phone writes them (SPEC section 18).
func record(_ id: Int64, _ jpeg: Data) -> Data {
    var d = Data()
    withUnsafeBytes(of: UInt64(bitPattern: id).bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(jpeg.count).bigEndian) { d.append(contentsOf: $0) }
    d.append(jpeg)
    return d
}

let endRecord = record(0, Data())
