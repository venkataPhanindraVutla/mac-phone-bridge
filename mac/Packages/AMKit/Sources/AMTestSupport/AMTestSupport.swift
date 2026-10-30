import AMProtocol
import ConnectionCore
import CryptoKit
import Foundation
import SwiftProtobuf

// Test doubles and helpers shared by the test targets. Never linked into the app: no product
// exports this target, and only test targets depend on it.

/// Records every `BulkGrants` call, in order.
@MainActor
public final class FakeBulk: BulkGrants {
    public var port: UInt16? = 4242
    public var calls: [String] = []
    public var allowed: [Data?] = []
    public var issued: [(role: AMBulkRole, context: String, token: Data)] = []
    public var revoked: [String] = []
    public var revokeAllCount = 0

    public init() {}

    public func allow(peerFingerprint: Data?) {
        calls.append("allow")
        allowed.append(peerFingerprint)
    }

    public func issue(role: AMBulkRole, context: String) -> Data {
        calls.append("issue")
        let token = Data("token-\(issued.count)".utf8)
        issued.append((role, context, token))
        return token
    }

    public func revoke(context: String) { revoked.append(context) }

    public func revokeAll() {
        calls.append("revokeAll")
        revokeAllCount += 1
    }
}

/// One direction of an in-memory byte pipe.
final class ByteQueue: @unchecked Sendable {
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
public final class MemoryPipe: BulkPipe, @unchecked Sendable {
    private let inbox: ByteQueue
    private let outbox: ByteQueue
    private let lock = NSLock()
    private var closedFlag = false
    private var sent: UInt64 = 0

    init(inbox: ByteQueue, outbox: ByteQueue) {
        self.inbox = inbox
        self.outbox = outbox
    }

    /// (Mac end, phone end).
    public static func pair() -> (MemoryPipe, MemoryPipe) {
        let toMac = ByteQueue(), toPhone = ByteQueue()
        return (MemoryPipe(inbox: toMac, outbox: toPhone), MemoryPipe(inbox: toPhone, outbox: toMac))
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }
    public var bytesSent: UInt64 { lock.lock(); defer { lock.unlock() }; return sent }

    public func receive(maximum: Int) async throws -> Data? {
        try await inbox.pop(maximum)
    }

    public func send(_ data: Data) async throws {
        let closed = lock.withLock {
            if !closedFlag { sent += UInt64(data.count) }
            return closedFlag
        }
        if closed { throw ByteQueue.Closed() }
        outbox.push(data)
    }

    public func close() {
        lock.lock()
        let was = closedFlag
        closedFlag = true
        lock.unlock()
        guard !was else { return }
        inbox.abort()
        outbox.end()
    }
}

/// Every message sent, in order.
@MainActor
public final class SentLog {
    public var all: [(type: MessageType, message: any SwiftProtobuf.Message)] = []
    public var types: [MessageType] { all.map(\.type) }

    public init() {}

    public func of<M: SwiftProtobuf.Message>(_ type: MessageType, _: M.Type) -> [M] {
        all.filter { $0.type == type }.compactMap { $0.message as? M }
    }
}

/// A wait that ran out; the test fails with this error.
public struct TimedOut: Error, CustomStringConvertible {
    public let description: String
}

/// Polls `condition` on the main actor until it holds, or throws `TimedOut` after `timeout`.
@MainActor
public func until(_ what: String = "condition", timeout: Duration = .seconds(5),
                  _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { throw TimedOut(description: "timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes; whether it held.
@MainActor
public func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Reads exactly `count` bytes from `pipe` (or stops after 5 s without a byte).
public func readAll(_ pipe: MemoryPipe, _ count: Int) async throws -> Data {
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

public func envelope<M: SwiftProtobuf.Message>(_ channel: AMChannel, _ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = channel
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

public func randomBytes(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}

public func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

/// A phone ID (its certificate fingerprint, hex).
public let phoneHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

extension Data {
    public init(hexString: String) {
        var out = Data()
        var it = hexString.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        self = out
    }
}

/// A `UserDefaults` suite of its own, removed by `remove()`.
public final class TemporaryDefaults: @unchecked Sendable {
    public let name = "am-tests-\(UUID().uuidString)"
    public let defaults: UserDefaults

    public init() {
        defaults = UserDefaults(suiteName: name)!
    }

    public func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}
