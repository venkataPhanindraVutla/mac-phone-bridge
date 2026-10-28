import Foundation
import Network

/// A bulk connection after its `bulk.hello`: raw bytes both ways, no framing (SPEC section 13).
public protocol BulkPipe: AnyObject, Sendable {
    /// Up to `maximum` bytes, as soon as any are available; nil at EOF.
    func receive(maximum: Int) async throws -> Data?
    /// Returns once the bytes have been handed to TLS.
    func send(_ data: Data) async throws
    func close()
}

/// The `BulkPipe` over an accepted NWConnection. Bytes that arrived in the same read as the
/// hello are returned first.
public final class BulkLink: BulkPipe, @unchecked Sendable {
    /// Read and write chunk size for bulk transfers (256 KiB).
    public static let bufferBytes = 262_144

    private let connection: NWConnection
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var leftover: Data
    /// Guarded by `lock`: the peer has finished sending.
    private var ended = false

    /// Takes over `connection`, which must be ready. `onEnd` is called (possibly more than
    /// once) when the connection fails or is cancelled.
    init(connection: NWConnection, leftover: Data, onEnd: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.leftover = leftover
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onEnd()
            default: break
            }
        }
        // It may have ended before the handler above was in place.
        switch connection.state {
        case .failed, .cancelled: onEnd()
        default: break
        }
    }

    deinit { connection.cancel() }

    public func receive(maximum: Int) async throws -> Data? {
        precondition(maximum > 0, "maximum must be positive")
        if let head = takeLeftover(maximum) { return head }
        while true {
            if isEnded { return nil }
            if let data = try await receiveOnce(maximum), !data.isEmpty { return data }
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    public func close() {
        connection.cancel()
    }

    // MARK: private

    private var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    private func markEnded() {
        lock.lock(); defer { lock.unlock() }
        ended = true
    }

    private func takeLeftover(_ maximum: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !leftover.isEmpty else { return nil }
        let head = Data(leftover.prefix(maximum))
        leftover = Data(leftover.dropFirst(head.count))
        return head
    }

    /// One read: data, nil at EOF, or empty when nothing arrived (read again).
    private func receiveOnce(_ maximum: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [self] data, _, isComplete, error in
                if isComplete { markEnded() }
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: error)
                } else {
                    c.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }
}
