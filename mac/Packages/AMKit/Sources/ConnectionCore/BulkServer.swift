import AMProtocol
import Foundation
import Network

/// What feature code needs from the bulk listener: its port, who may connect, and tokens.
@MainActor
public protocol BulkGrants: AnyObject {
    var port: UInt16? { get }
    /// The connected phone; nil refuses everyone.
    func allow(peerFingerprint: Data?)
    func issue(role: AMBulkRole, context: String) -> Data
    func revoke(context: String)
    func revokeAll()
}

/// The Mac's second TLS 1.3 listener, for bulk connections (SPEC section 13). It accepts only
/// the certificate passed to `allow`. Each connection must send `bulk.hello` within
/// `helloTimeout` with a token that redeems for its role; it is then handed to `onLink`.
/// Anything else closes the connection without a reply.
@MainActor
public final class BulkServer: BulkGrants {
    public private(set) var port: UInt16?
    /// Gets every connection whose hello redeemed. With no handler, the link is closed.
    public var onLink: ((any BulkPipe, BulkGrant) -> Void)?

    private let identityProvider: any IdentityProvider
    private let tokens: BulkTokens
    private let helloTimeout: Duration

    private var identity: TLSIdentity?
    /// Read on the TLS verify queue; holds at most the one allowed phone.
    private let policy = PeerPolicy()
    private var allowed: Data?
    private var listener: NWListener?
    private var listenerGeneration = 0
    private var restartAttempts = 0
    private var nextConnectionID: UInt64 = 0
    /// Accepted connections still waiting for their hello.
    private var pending: [UInt64: PendingHello] = [:]
    /// Links handed out and not yet ended.
    private var links: [UInt64: BulkLink] = [:]

    private static let listenerQueue = DispatchQueue(label: "io.github.anmirror.bulk-listener")
    private static let maxRestartAttempts = 40

    public init(identity: any IdentityProvider, tokens: BulkTokens = BulkTokens(),
                helloTimeout: Duration = .seconds(10)) {
        self.identityProvider = identity
        self.tokens = tokens
        self.helloTimeout = helloTimeout
    }

    // MARK: lifecycle

    /// Loads the identity and listens on an ephemeral port; `port` is set once it is ready.
    public func start() throws {
        guard listener == nil else { return }
        identity = try identityProvider.identity()
        restartAttempts = 0
        try startListener()
    }

    /// Closes every connection and the listener.
    public func stop() {
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        port = nil
        closeConnections()
    }

    /// After wake from sleep: closes every connection and listens again (the port may change).
    public func handleWake() {
        closeConnections()
        guard identity != nil else { return }
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        port = nil
        restartAttempts = 0
        try? startListener()
    }

    // MARK: BulkGrants

    /// Changing the allowed phone (or refusing everyone) also closes every open connection.
    public func allow(peerFingerprint: Data?) {
        guard peerFingerprint != allowed else { return }
        allowed = peerFingerprint
        policy.update(paired: peerFingerprint.map { [$0] } ?? [], pairingOpen: false)
        closeConnections()
    }

    public func issue(role: AMBulkRole, context: String) -> Data {
        tokens.issue(role: role, context: context)
    }

    public func revoke(context: String) {
        tokens.revoke(context: context)
    }

    public func revokeAll() {
        tokens.revokeAll()
    }

    // MARK: listener

    private func startListener() throws {
        guard let identity else { return }
        let policy = self.policy
        let params = TLSParameters.server(identity: identity) { policy.accepts($0) }
        let l = try NWListener(using: params)
        listenerGeneration += 1
        let generation = listenerGeneration
        l.stateUpdateHandler = { [weak self, weak l] state in
            let report: ListenerReport
            switch state {
            case .ready: report = .ready(l?.port?.rawValue ?? 0)
            case .failed: report = .failed
            default: return
            }
            Task { @MainActor in self?.listenerChanged(report, generation: generation) }
        }
        l.newConnectionHandler = { [weak self] nw in
            Task { @MainActor in
                if let self { self.accept(nw, generation: generation) } else { nw.cancel() }
            }
        }
        listener = l
        l.start(queue: Self.listenerQueue)
    }

    private enum ListenerReport: Sendable {
        case ready(UInt16)
        case failed
    }

    private func listenerChanged(_ report: ListenerReport, generation: Int) {
        guard generation == listenerGeneration else { return }
        switch report {
        case let .ready(p):
            port = p
            restartAttempts = 0
        case .failed:
            listener?.cancel()
            listener = nil
            port = nil
            guard restartAttempts < Self.maxRestartAttempts else { return }
            restartAttempts += 1
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.listener == nil, self.identity != nil else { return }
                try? self.startListener()
            }
        }
    }

    // MARK: connections

    private func accept(_ nw: NWConnection, generation: Int) {
        guard generation == listenerGeneration, listener != nil else {
            nw.cancel()
            return
        }
        nextConnectionID += 1
        let id = nextConnectionID
        let timeout = helloTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.dropPending(id)
        }
        let reader = HelloReader(connection: nw)
        pending[id] = PendingHello(connection: nw, reader: reader, timer: timer)
        reader.start { [weak self] result in
            Task { @MainActor in self?.helloRead(id, result) }
        }
    }

    private func dropPending(_ id: UInt64) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timer.cancel()
        p.connection.cancel()
    }

    private func helloRead(_ id: UInt64, _ result: Result<HelloReader.Hello, Error>) {
        // Gone already: timed out, or closed by allow/wake/stop.
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timer.cancel()
        guard case let .success(read) = result,
              read.envelope.type == MessageType.bulkHello.rawValue,
              read.envelope.channel == .files,
              let hello = try? AMBulkHello(serializedBytes: read.envelope.payload),
              let grant = tokens.redeem(hello.token, role: hello.role)
        else {
            p.connection.cancel()
            return
        }
        let link = BulkLink(connection: p.connection, leftover: read.leftover) { [weak self] in
            Task { @MainActor in self?.links[id] = nil }
        }
        links[id] = link
        if let onLink { onLink(link, grant) } else { link.close() }
    }

    private func closeConnections() {
        for p in pending.values {
            p.timer.cancel()
            p.connection.cancel()
        }
        pending.removeAll()
        for l in links.values { l.close() }
        links.removeAll()
    }
}

private struct PendingHello {
    let connection: NWConnection
    /// Held here so it lives until the hello is read (the connection keeps it only weakly).
    let reader: HelloReader
    let timer: Task<Void, Never>
}

/// Starts an accepted connection and reads frames until the first envelope. Everything
/// after `start` runs on the connection's own serial queue.
private final class HelloReader: @unchecked Sendable {
    struct Hello: Sendable {
        let envelope: AMEnvelope
        /// Bytes that followed the hello frame in the same reads.
        let leftover: Data
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.github.anmirror.bulk-connection")
    private var decoder = FrameDecoder()
    private var received = Data()
    private var completion: (@Sendable (Result<Hello, Error>) -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    func start(_ completion: @escaping @Sendable (Result<Hello, Error>) -> Void) {
        self.completion = completion
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.readMore()
            case let .failed(error), let .waiting(error): self?.finish(.failure(error))
            case .cancelled: self?.finish(.failure(ConnectionError.closed))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                received.append(data)
                decoder.append(data)
                do {
                    if let envelope = try decoder.next() {
                        let consumed = 4 + (Int(received[0]) << 24 | Int(received[1]) << 16
                            | Int(received[2]) << 8 | Int(received[3]))
                        finish(.success(Hello(envelope: envelope,
                                              leftover: received.subdata(in: consumed..<received.count))))
                        return
                    }
                } catch {
                    finish(.failure(error))
                    return
                }
            }
            if let error {
                finish(.failure(error))
            } else if isComplete {
                finish(.failure(ConnectionError.closed))
            } else {
                readMore()
            }
        }
    }

    /// Reports once; later state changes are ignored.
    private func finish(_ result: Result<Hello, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}
