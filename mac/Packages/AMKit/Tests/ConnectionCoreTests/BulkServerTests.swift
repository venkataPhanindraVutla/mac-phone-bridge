import AMProtocol
import CryptoKit
import Foundation
import Network
import Testing
@testable import ConnectionCore

// MARK: helpers

/// Every link `BulkServer` delivered, in order.
@MainActor
final class LinkLog {
    var links: [(pipe: any BulkPipe, grant: BulkGrant)] = []
    var grants: [BulkGrant] { links.map(\.grant) }
}

/// Resumes a continuation once, from whichever callback gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }

    /// True when this call resumed it (the first one).
    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
        return c != nil
    }
}

/// Resumes a `Bool` continuation once; later calls do nothing.
private final class OnceBool: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ c: CheckedContinuation<Bool, Never>) { continuation = c }

    /// True when this call resumed it (the first one).
    @discardableResult
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

/// A phone-side bulk connection driven by hand: raw bytes, no framing beyond the hello.
final class RawBulkClient: @unchecked Sendable {
    let nw: NWConnection

    private init(_ nw: NWConnection) { self.nw = nw }

    /// Connects to 127.0.0.1:`port` as the named test identity, pinning the Mac. A handshake that
    /// neither finishes nor fails within `timeout` is cancelled, so the test fails instead of hanging.
    static func connect(port: UInt16, identity name: String = "phone",
                        timeout: Duration = .seconds(30)) async throws -> RawBulkClient {
        let identity = try testIdentity(name)
        let pin = try vectorFingerprint("mac")
        let params = TLSParameters.client(identity: identity, acceptPeer: { $0 == pin })
        let nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            nw.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case let .failed(e), let .waiting(e): once.resume(.failure(e))
                case .cancelled: once.resume(.failure(TestError("cancelled")))
                default: break
                }
            }
            nw.start(queue: DispatchQueue(label: "test.bulk-client"))
            Task {
                try? await Task.sleep(for: timeout)
                if once.resume(.failure(TestError("connect timed out"))) { nw.cancel() }
            }
        }
        return RawBulkClient(nw)
    }

    static func helloFrame(token: Data, role: AMBulkRole) throws -> Data {
        var hello = AMBulkHello()
        hello.token = token
        hello.role = role
        return try Frame.encode(AMEnvelope(channel: .files, id: 1, type: .bulkHello, payload: hello))
    }

    /// Sends `data`; a send Network.framework never completes is given up after 30 s (the
    /// connection is cancelled), so the test fails instead of hanging.
    func send(_ data: Data) async throws {
        let nw = nw
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            nw.send(content: data, completion: .contentProcessed { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            })
            Task {
                try? await Task.sleep(for: .seconds(30))
                if once.resume(.failure(TestError("send timed out"))) { nw.cancel() }
            }
        }
    }

    func hello(token: Data, role: AMBulkRole, then extra: Data = Data()) async throws {
        try await send(try Self.helloFrame(token: token, role: role) + extra)
    }

    /// The next bytes, or nil at EOF / on an error.
    func receive() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty { c.resume(returning: data) } else if error != nil || isComplete {
                    c.resume(returning: nil)
                } else { c.resume(returning: Data()) }
            }
        }
    }

    /// True once the server has closed the connection, within `timeout` (generous: it only
    /// bounds a close that is not coming). The answer does not wait for the read under way: once
    /// the time is up the connection is cancelled and false comes back, whether or not
    /// Network.framework ever completes that read.
    func closedByServer(timeout: Duration = .seconds(30)) async -> Bool {
        let nw = nw
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let answer = OnceBool(c)
            let reader = Task {
                while !Task.isCancelled {
                    guard let d = await self.receive() else {
                        answer.resume(true)
                        return
                    }
                    if d.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if answer.resume(false) {
                    reader.cancel()
                    nw.cancel()
                }
            }
        }
    }

    func close() { nw.cancel() }
}

@MainActor
// The hello timeout is far off unless a test sets it: a slow runner must not end a connection
// that a test still holds open.
func startBulk(tokens: BulkTokens = BulkTokens(), helloTimeout: Duration = .seconds(60),
               allow: String? = "phone") async throws -> (BulkServer, UInt16, LinkLog) {
    let server = BulkServer(identity: P12IdentityProvider(url: identityURL("mac"), password: "test"),
                            tokens: tokens, helloTimeout: helloTimeout)
    let log = LinkLog()
    server.onLink = { pipe, grant in log.links.append((pipe, grant)) }
    try server.start()
    server.allow(peerFingerprint: try allow.map { try testIdentity($0).fingerprint })
    #expect(await eventually { server.port != nil })
    return (server, try #require(server.port), log)
}

/// Reads from `pipe` until `count` bytes arrived, EOF, or `timeout` (the pipe is then closed,
/// so a missing byte fails the test instead of hanging it).
func readExactly(_ pipe: any BulkPipe, _ count: Int, timeout: Duration = .seconds(30)) async throws -> Data {
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { pipe.close() }
    }
    defer { watchdog.cancel() }
    var out = Data()
    while out.count < count {
        guard let chunk = try await pipe.receive(maximum: BulkLink.bufferBytes) else { break }
        out.append(chunk)
    }
    return out
}

// MARK: tests

@Suite(.serialized) @MainActor struct BulkServerTests {
    @Test func validTokenDeliversLinkWithGrant() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        defer { client.close() }
        try await client.hello(token: token, role: .phoneSends)

        #expect(await eventually { log.links.count == 1 })
        #expect(log.grants == [BulkGrant(role: .phoneSends, context: "t1")])
    }

    @Test func unknownTokenCloses() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        _ = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: PairingCrypto.randomBytes(32), role: .phoneSends)

        #expect(await client.closedByServer())
        #expect(log.links.isEmpty)
    }

    @Test func expiredTokenCloses() async throws {
        let clock = TestClock()
        let (server, port, log) = try await startBulk(tokens: BulkTokens(now: { clock.now }))
        defer { server.stop() }
        let token = server.issue(role: .phoneReceives, context: "t1")
        clock.advance(61)

        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: token, role: .phoneReceives)

        #expect(await client.closedByServer())
        #expect(log.links.isEmpty)
    }

    @Test func tokenIsSingleUse() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .thumbnails, context: "p1")

        let first = try await RawBulkClient.connect(port: port)
        defer { first.close() }
        try await first.hello(token: token, role: .thumbnails)
        #expect(await eventually { log.links.count == 1 })

        let second = try await RawBulkClient.connect(port: port)
        try await second.hello(token: token, role: .thumbnails)
        #expect(await second.closedByServer())
        #expect(log.links.count == 1)
    }

    @Test func roleMismatchCloses() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: token, role: .phoneReceives)

        #expect(await client.closedByServer())
        #expect(log.links.isEmpty)
    }

    @Test func strangerCertificateIsRefused() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        // TLS 1.3: the client may finish its side before the server judges its certificate,
        // so the refusal shows up either as a failed connect or as an immediate close.
        if let client = try? await RawBulkClient.connect(port: port, identity: "stranger") {
            try? await client.hello(token: token, role: .phoneSends)
            #expect(await client.closedByServer())
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.links.isEmpty)
    }

    @Test func allowNilRefusesThePhone() async throws {
        let (server, port, log) = try await startBulk(allow: nil)
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        if let client = try? await RawBulkClient.connect(port: port) {
            try? await client.hello(token: token, role: .phoneSends)
            #expect(await client.closedByServer())
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.links.isEmpty)
    }

    @Test func noHelloWithinTimeoutCloses() async throws {
        let (server, port, log) = try await startBulk(helloTimeout: .milliseconds(300))
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        // Half a hello frame: the server must not wait past the timeout for the rest.
        let frame = try RawBulkClient.helloFrame(token: token, role: .phoneSends)
        try await client.send(frame.prefix(10))

        #expect(await client.closedByServer())
        #expect(log.links.isEmpty)
    }

    @Test func revokeAllRejectsOutstandingTokens() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let sends = server.issue(role: .phoneSends, context: "t1")
        let receives = server.issue(role: .phoneReceives, context: "t2")
        server.revokeAll()

        for (token, role) in [(sends, AMBulkRole.phoneSends), (receives, .phoneReceives)] {
            let client = try await RawBulkClient.connect(port: port)
            try await client.hello(token: token, role: role)
            #expect(await client.closedByServer())
        }
        #expect(log.links.isEmpty)
    }

    @Test func bytesAfterHelloReachThePipe() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        defer { client.close() }
        // The first bytes ride in the same write as the hello; more follow.
        let head = Data("first bytes".utf8)
        let rest = PairingCrypto.randomBytes(3 * BulkLink.bufferBytes + 123)
        try await client.hello(token: token, role: .phoneSends, then: head)
        try await client.send(rest)

        #expect(await eventually { log.links.count == 1 })
        let pipe = try #require(log.links.first?.pipe)
        let got = try await readExactly(pipe, head.count + rest.count)
        #expect(got.count == head.count + rest.count)
        #expect(SHA256.hash(data: got) == SHA256.hash(data: head + rest))

        // And the other way: the Mac writes raw bytes to the phone.
        try await pipe.send(Data("to phone".utf8))
        #expect(await client.receive() == Data("to phone".utf8))
    }

    @Test func pipeReportsEndOfStream() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")

        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: token, role: .phoneSends, then: Data("abc".utf8))
        #expect(await eventually { log.links.count == 1 })
        let pipe = try #require(log.links.first?.pipe)
        #expect(try await readExactly(pipe, 3) == Data("abc".utf8))
        client.close()
        // EOF (nil) or a transport error both end the stream; it must not hang.
        let ended: Bool
        do { ended = try await pipe.receive(maximum: 1024) == nil } catch { ended = true }
        #expect(ended)
    }

    @Test func changingAllowRevokesOutstandingTokens() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")
        let phone = try testIdentity("phone").fingerprint
        server.allow(peerFingerprint: nil)
        server.allow(peerFingerprint: phone)

        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: token, role: .phoneSends)
        #expect(await client.closedByServer())
        #expect(log.links.isEmpty)
    }

    @Test func ninthPendingConnectionIsRefused() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        // Eight connections that finished TLS and sent no hello yet: the cap.
        var waiting: [RawBulkClient] = []
        for _ in 0..<8 { waiting.append(try await RawBulkClient.connect(port: port)) }

        let token = server.issue(role: .phoneSends, context: "t9")
        if let ninth = try? await RawBulkClient.connect(port: port) {
            try? await ninth.hello(token: token, role: .phoneSends)
            #expect(await ninth.closedByServer())
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.links.isEmpty)

        // Once the waiting ones go away, connections are accepted again.
        for c in waiting { c.close() }
        // The server frees the slots as it sees the closes: try again until one is taken.
        let deadline = ContinuousClock.now + .seconds(30)
        var attempt = 0
        while log.links.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            attempt += 1
            guard let c = try? await RawBulkClient.connect(port: port) else { continue }
            defer { c.close() }
            try await c.hello(token: server.issue(role: .phoneSends, context: "again\(attempt)"), role: .phoneSends)
            _ = await eventually(timeout: .milliseconds(500)) { !log.links.isEmpty }
        }
        #expect(!log.links.isEmpty)
    }

    @Test func listenerRetryAfterFailureRestoresThePort() async throws {
        let (server, _, _) = try await startBulk()
        defer { server.stop() }
        server.simulateListenerFailureForTesting()
        #expect(server.port == nil)
        // The retry fires after 250 ms; a loaded machine can take far longer to listen again.
        #expect(await eventually { server.port != nil })
    }

    @Test func stopDuringListenerRetryStaysStopped() async throws {
        let (server, _, _) = try await startBulk()
        server.simulateListenerFailureForTesting()
        server.stop()
        // The retry fires after 250 ms; give it time to (wrongly) come back.
        try await Task.sleep(for: .milliseconds(600))
        #expect(server.port == nil)
    }

    @Test func wakeClosesLinksAndListensAgain() async throws {
        let (server, port, log) = try await startBulk()
        defer { server.stop() }
        let token = server.issue(role: .phoneSends, context: "t1")
        let client = try await RawBulkClient.connect(port: port)
        try await client.hello(token: token, role: .phoneSends)
        #expect(await eventually { log.links.count == 1 })

        server.handleWake()
        #expect(await client.closedByServer())
        #expect(await eventually { server.port != nil })

        let again = try await RawBulkClient.connect(port: try #require(server.port))
        defer { again.close() }
        try await again.hello(token: server.issue(role: .phoneSends, context: "t2"), role: .phoneSends)
        #expect(await eventually { log.links.count == 2 })
        #expect(log.grants.last == BulkGrant(role: .phoneSends, context: "t2"))
    }
}

@MainActor @Test func portChangesAreReported() async throws {
    let server = BulkServer(identity: P12IdentityProvider(url: identityURL("mac"), password: "test"))
    var reported: [UInt16?] = []
    server.onPortChange = { reported.append($0) }
    try server.start()
    defer { server.stop() }
    #expect(await eventually { server.port != nil })
    #expect(reported == [server.port])

    server.handleWake()
    #expect(reported.count == 2)
    #expect(reported.last == .some(nil))
    #expect(await eventually { server.port != nil })
    #expect(reported.count == 3)
    #expect(reported.last == server.port)
}
