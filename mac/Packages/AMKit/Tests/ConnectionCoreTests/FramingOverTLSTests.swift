import AMProtocol
import Foundation
import Network
import Testing
@testable import ConnectionCore

/// A bare TLS listener on 127.0.0.1 that hands each accepted connection to `onConnection`.
final class LoopbackListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.listener")

    init(identity: TLSIdentity, acceptPeer: @escaping @Sendable (Data) -> Bool,
         onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: TLSParameters.server(identity: identity, acceptPeer: acceptPeer))
        listener.newConnectionHandler = onConnection
    }

    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let p = listener.port?.rawValue, p != 0 { return p }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestError("listener did not become ready")
    }

    func stop() { listener.cancel() }
}

/// Holds the server-side ControlConnection once it is open.
actor ServerSide {
    var connection: ControlConnection?
    var openFailures = 0
    func set(_ c: ControlConnection) { connection = c }
    func failed() { openFailures += 1 }
}

@Test func framesRoundTripOverLoopbackTLS() async throws {
    let mac = try testIdentity("mac")
    let phone = try testIdentity("phone")
    let phoneFP = phone.fingerprint
    let server = ServerSide()
    let listener = try LoopbackListener(identity: mac, acceptPeer: { $0 == phoneFP }) { nw in
        Task {
            do { await server.set(try await ControlConnection.open(nw)) } catch { await server.failed() }
        }
    }
    let port = try await listener.start()
    defer { listener.stop() }

    let client = try await connectClient(port: port, identity: phone, pin: mac.fingerprint)
    defer { client.close() }
    #expect(client.peerFingerprint == mac.fingerprint)
    #expect(client.tlsVersion == .TLSv13)

    var serverConn: ControlConnection?
    for _ in 0..<300 where serverConn == nil {
        serverConn = await server.connection
        if serverConn == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let conn = try #require(serverConn)
    #expect(conn.peerFingerprint == phoneFP)
    #expect(conn.peerCertificateDER == phone.certificateDER)
    let inbox = Inbox(conn.envelopes)

    // The largest message that still fits one frame: its envelope is exactly Frame.maxBytes.
    var big = AMPairComplete()
    big.discoveryKey = PairingCrypto.randomBytes(Frame.maxBytes - 32)
    var probe = try AMEnvelope(channel: .pairing, id: 3, type: .pairComplete, payload: big)
    while try probe.serializedData().count < Frame.maxBytes {
        big.discoveryKey.append(0x5A)
        probe = try AMEnvelope(channel: .pairing, id: 3, type: .pairComplete, payload: big)
    }
    while try probe.serializedData().count > Frame.maxBytes {
        big.discoveryKey.removeLast()
        probe = try AMEnvelope(channel: .pairing, id: 3, type: .pairComplete, payload: big)
    }
    #expect(try probe.serializedData().count == Frame.maxBytes)

    var hello = AMHello()
    hello.protocolVersion = 1
    hello.capabilities = ["status.v1", "find.v1"]
    var status = AMStatusUpdate()
    status.batteryPercent = 55
    status.signalLevel = -1

    let id1 = try await client.send(.hello, hello, channel: .system)
    let id2 = try await client.send(.statusUpdate, status, channel: .status, replyTo: 1)
    let id3 = try await client.send(.pairComplete, big, channel: .pairing)
    #expect([id1, id2, id3] == [1, 2, 3])

    let expected = [
        try AMEnvelope(channel: .system, id: 1, type: .hello, payload: hello),
        try AMEnvelope(channel: .status, id: 2, replyTo: 1, type: .statusUpdate, payload: status),
        try AMEnvelope(channel: .pairing, id: 3, type: .pairComplete, payload: big),
    ]
    for e in expected {
        let got = await inbox.next(timeout: .seconds(5))
        #expect(got == e)
    }
}

@Test func serverRejectsUnpinnedClient() async throws {
    let mac = try testIdentity("mac")
    let stranger = try testIdentity("stranger")
    let phoneFP = try testIdentity("phone").fingerprint
    let server = ServerSide()
    let listener = try LoopbackListener(identity: mac, acceptPeer: { $0 == phoneFP }) { nw in
        Task {
            do { await server.set(try await ControlConnection.open(nw)) } catch { await server.failed() }
        }
    }
    let port = try await listener.start()
    defer { listener.stop() }

    let start = ContinuousClock.now
    // TLS 1.3: the client may see "ready" before the server has judged its certificate,
    // so a rejection shows up either as a failed open or as the stream ending at once.
    do {
        let client = try await connectClient(port: port, identity: stranger, pin: mac.fingerprint)
        let inbox = Inbox(client.envelopes)
        _ = try? await client.send(.ping, AMPing(), channel: .system)
        #expect(await inbox.waitForEnd(timeout: .seconds(3)))
        client.close()
    } catch {
        // Rejected during the handshake.
    }
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(await server.connection == nil)
}

@Test func clientRejectsWrongServerFingerprint() async throws {
    let mac = try testIdentity("mac")
    let phone = try testIdentity("phone")
    let listener = try LoopbackListener(identity: mac, acceptPeer: { _ in true }) { nw in
        Task { _ = try? await ControlConnection.open(nw) }
    }
    let port = try await listener.start()
    defer { listener.stop() }
    let wrongPin = try vectorFingerprint("stranger")
    await #expect(throws: (any Error).self) {
        _ = try await connectClient(port: port, identity: phone, pin: wrongPin)
    }
}

@Test func serverRefusesTLS12Client() async throws {
    let mac = try testIdentity("mac")
    let phone = try testIdentity("phone")
    let server = ServerSide()
    let listener = try LoopbackListener(identity: mac, acceptPeer: { _ in true }) { nw in
        Task {
            do { await server.set(try await ControlConnection.open(nw)) } catch { await server.failed() }
        }
    }
    let port = try await listener.start()
    defer { listener.stop() }

    // A client capped at TLS 1.2 that otherwise trusts anything.
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_set_local_identity(sec, sec_identity_create(phone.secIdentity)!)
    sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, .global())
    let nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                          using: NWParameters(tls: tls, tcp: .init()))
    await #expect(throws: (any Error).self) {
        _ = try await ControlConnection.open(nw, timeout: .seconds(3))
    }
    #expect(await server.connection == nil)
}

/// Keeps the server-side NWConnections a listener handed out.
final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [NWConnection] = []
    func add(_ c: NWConnection) { lock.lock(); list.append(c); lock.unlock() }
    var all: [NWConnection] { lock.lock(); defer { lock.unlock() }; return list }
}

@Test func refusedHandshakeCancelsServerConnection() async throws {
    let mac = try testIdentity("mac")
    let stranger = try testIdentity("stranger")
    let phoneFP = try testIdentity("phone").fingerprint
    let accepted = AcceptedConnections()
    let listener = try LoopbackListener(identity: mac, acceptPeer: { $0 == phoneFP }) { nw in
        accepted.add(nw)
        Task { _ = try? await ControlConnection.open(nw) }
    }
    let port = try await listener.start()
    defer { listener.stop() }

    if let client = try? await connectClient(port: port, identity: stranger, pin: mac.fingerprint) {
        _ = try? await client.send(.ping, AMPing(), channel: .system)
        _ = await Inbox(client.envelopes).waitForEnd()
        client.close()
    }
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline,
          accepted.all.isEmpty || accepted.all.contains(where: { $0.state != .cancelled }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(accepted.all.count == 1)
    #expect(accepted.all.allSatisfy { $0.state == .cancelled })
}
