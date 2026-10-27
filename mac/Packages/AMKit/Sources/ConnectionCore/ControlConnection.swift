import AMProtocol
import Foundation
import Network
import Security
import SwiftProtobuf

public enum ConnectionError: Error, Equatable, Sendable {
    /// The connection failed or was cancelled before it became ready.
    case notReady(String)
    /// TLS completed but no peer certificate was available.
    case noPeerCertificate
    case closed
}

/// One framed, TLS-protected connection (SPEC sections 2 and 3). Owns its NWConnection.
/// Outgoing envelope IDs count up from 1. Incoming envelopes arrive on `envelopes`, which
/// finishes on EOF, on a transport error, on a framing error (the connection is then closed
/// without a reply, as SPEC section 8 requires) or on `close()`.
public actor ControlConnection {
    public nonisolated let peerFingerprint: Data
    public nonisolated let peerCertificateDER: Data
    /// The TLS version both sides agreed on (always 1.3 with `TLSParameters`).
    public nonisolated let tlsVersion: tls_protocol_version_t?
    public nonisolated let envelopes: AsyncThrowingStream<AMEnvelope, Error>

    private nonisolated let connection: NWConnection
    private nonisolated let continuation: AsyncThrowingStream<AMEnvelope, Error>.Continuation
    private var nextID: UInt64 = 1

    /// Starts `connection`, waits until TLS is up, reads the peer's certificate and begins
    /// reading frames. `timeout` bounds the wait for "ready".
    public static func open(_ connection: NWConnection, timeout: Duration? = nil) async throws -> ControlConnection {
        let queue = DispatchQueue(label: "io.github.anmirror.connection")
        let gate = ReadyGate()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            gate.set(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(.success(()))
                case let .failed(error):
                    gate.resume(.failure(ConnectionError.notReady(String(describing: error))))
                case let .waiting(error):
                    // Not reachable right now: give up instead of waiting for a better path.
                    gate.resume(.failure(ConnectionError.notReady(String(describing: error))))
                    connection.cancel()
                case .cancelled:
                    gate.resume(.failure(ConnectionError.notReady("cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            if let timeout {
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) {
                    if gate.resume(.failure(ConnectionError.notReady("timed out"))) { connection.cancel() }
                }
            }
        }
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let der = peerCertificate(metadata)
        else {
            connection.cancel()
            throw ConnectionError.noPeerCertificate
        }
        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
        return ControlConnection(connection: connection, peerCertificateDER: der, tlsVersion: version)
    }

    private init(connection: NWConnection, peerCertificateDER: Data, tlsVersion: tls_protocol_version_t) {
        self.connection = connection
        self.peerCertificateDER = peerCertificateDER
        self.tlsVersion = tlsVersion
        self.peerFingerprint = PairingCrypto.fingerprint(certificateDER: peerCertificateDER)
        let (stream, continuation) = AsyncThrowingStream<AMEnvelope, Error>.makeStream()
        self.envelopes = stream
        self.continuation = continuation
        connection.stateUpdateHandler = { state in
            switch state {
            case let .failed(error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish()
            default: break
            }
        }
        FrameReader(connection: connection, continuation: continuation).receiveNext()
    }

    /// Sends one message and returns the envelope ID it was given.
    @discardableResult
    public func send(_ type: MessageType, _ message: some SwiftProtobuf.Message & Sendable,
                     channel: AMChannel, replyTo: UInt64 = 0) async throws -> UInt64 {
        let id = nextID
        nextID += 1
        let envelope = try AMEnvelope(channel: channel, id: id, replyTo: replyTo, type: type, payload: message)
        let frame = try Frame.encode(envelope)
        let connection = self.connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
        return id
    }

    /// Closes at once. Pending outgoing data may be lost.
    public nonisolated func close() {
        continuation.finish()
        connection.cancel()
    }

    /// Ends the stream after everything already sent has been handed to TLS: used to close
    /// right after a `system.error` so the peer still reads it.
    public nonisolated func closeAfterFlush() {
        continuation.finish()
        let connection = self.connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        // Do not linger if the peer never reads.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    private static func peerCertificate(_ metadata: NWProtocolTLS.Metadata) -> Data? {
        let box = LeafBox()
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { cert in
            if box.der == nil {
                box.der = SecCertificateCopyData(sec_certificate_copy_ref(cert).takeRetainedValue()) as Data
            }
        }
        return box.der
    }
}

/// Resumes a continuation exactly once.
private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        continuation = c
    }

    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard !done, let c = continuation else { lock.unlock(); return false }
        done = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
        return true
    }
}

private final class LeafBox: @unchecked Sendable {
    var der: Data?
}

/// Reads frames off the connection. Only touched from the connection's serial queue.
private final class FrameReader: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: AsyncThrowingStream<AMEnvelope, Error>.Continuation
    private var decoder = FrameDecoder()

    init(connection: NWConnection, continuation: AsyncThrowingStream<AMEnvelope, Error>.Continuation) {
        self.connection = connection
        self.continuation = continuation
    }

    func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                decoder.append(data)
                do {
                    while let envelope = try decoder.next() { continuation.yield(envelope) }
                } catch {
                    continuation.finish(throwing: error)
                    connection.cancel()
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
                connection.cancel()
                return
            }
            if isComplete {
                continuation.finish()
                connection.cancel()
                return
            }
            receiveNext()
        }
    }
}
