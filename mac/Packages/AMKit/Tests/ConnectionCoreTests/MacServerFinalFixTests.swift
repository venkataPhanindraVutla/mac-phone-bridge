import AMProtocol
import Foundation
import Network
import Testing
@testable import ConnectionCore

/// Counts `all()` calls, to show the server does not read the store per message.
final class CountingPhoneStore: PairedPhoneStore, @unchecked Sendable {
    private let inner = InMemoryPairedPhoneStore()
    private let lock = NSLock()
    private var reads = 0

    var allCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func all() throws -> [PairedPhone] {
        lock.lock(); reads += 1; lock.unlock()
        return try inner.all()
    }

    func save(_ phone: PairedPhone) throws { try inner.save(phone) }
    func remove(id: String) throws { try inner.remove(id: id) }
}

/// Connects as `name`; true when the server turned the certificate away (TLS refusal, or a
/// connection that ends without any message).
@MainActor
func refusedAtTLS(_ name: String, port: UInt16) async -> Bool {
    guard let phone = try? await TestPhone.connect(name, port: port) else { return true }
    try? await phone.sendHello()
    return await phone.next(timeout: .seconds(2)) == nil
}

// MARK: final review fixes (R37)

@MainActor
@Suite struct MacServerFinalFixTests {
    /// R37 #1: opening a pairing window must not make the connected phone look disconnected.
    @Test func pairingWindowWhileConnectedKeepsActivePhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        let expected = ActivePhone(phone: known, shared: ["status.v1", "find.v1"])
        #expect(await eventually { server.activePhone == expected })

        let uri = server.beginPairing()
        #expect(server.state == .pairing(uri: uri, code: nil))
        #expect(server.activePhone == expected)

        server.confirmPairing(false) // close the window
        #expect(server.state == .connected(known, shared: ["status.v1", "find.v1"]))
        #expect(server.activePhone == expected)
    }

    @Test func activePhoneClearsOnDisconnect() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        #expect(server.activePhone == nil)
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.activePhone != nil })
        _ = server.beginPairing()
        phone.conn.close()
        #expect(await eventually { server.activePhone == nil })
    }

    /// R37 #5: quitting the Mac app says goodbye SHUTDOWN, so the phone reconnects calmly.
    @Test func stopSendsShutdownGoodbyeToConnectedPhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.activePhone != nil })
        server.stop()
        let bye = try #require(await phone.next())
        #expect(bye.type == MessageType.goodbye.rawValue)
        #expect(bye.channel == .system)
        #expect(try AMGoodbye(serializedBytes: bye.payload).reason == .shutdown)
        #expect(await phone.ended())
        #expect(server.activePhone == nil)
        #expect(try phones.all().count == 1, "SHUTDOWN does not unpair")
    }

    /// R37 #7: no keychain read per incoming message.
    @Test func pairedListIsCachedNotReadPerMessage() async throws {
        let phones = CountingPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.activePhone != nil })
        let before = phones.allCalls
        for _ in 0..<5 {
            try await phone.conn.send(.ping, AMPing(), channel: .system)
            #expect(try #require(await phone.next()).type == MessageType.pong.rawValue)
        }
        #expect(phones.allCalls == before)
    }

    @Test func cacheFollowsPairingAndForget() async throws {
        let phones = InMemoryPairedPhoneStore()
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let uri = server.beginPairing()
        let first = try await TestPhone.connect("phone", port: port)
        _ = try await pair(first, server: server, uri: uri)
        first.conn.close()
        #expect(await eventually { server.state == .idle })
        // A new connection after pairing is trusted (the cached list saw the save).
        let back = try await TestPhone.connect("phone", port: port)
        try await back.sendHello()
        #expect(try #require(await back.next()).type == MessageType.hello.rawValue)
        let saved = try #require(try phones.all().first)
        await server.forget(phoneID: saved.id)
        #expect(await back.ended())
        // ... and not after forget.
        #expect(await refusedAtTLS("phone", port: port))
    }

    /// R37 M2: the TLS gate for unknown certificates closes when the 5-minute secret expires.
    @Test func unknownCertRefusedAfterSecretExpires() async throws {
        // The secret's age is read from `clock`, so only the test ages it: on a busy runner the
        // expiry task (and the second pairing below) may run late without the secret running out.
        let clock = TestClock()
        let (server, port, log) = try await startServer(pairingLifetime: 0.3, now: { clock.now })
        defer { server.stop() }
        let uri = server.beginPairing()
        #expect(!server.pairingSecretSpent)
        clock.advance(1)
        // The expiry task closes the gate by itself. Its timer starts when the task first runs on
        // the main actor, which a busy main actor can put off: wait for it, not a fixed time.
        #expect(await eventually(timeout: .seconds(30)) { server.pairingSecretSpent })
        #expect(await refusedAtTLS("stranger", port: port))
        #expect(await eventually { log.contains(.rejected(.notPairedCertificate)) })
        // R11: the window itself stays until the user closes or replaces it.
        #expect(server.state == .pairing(uri: uri, code: nil))
        // A new window opens the gate again.
        let fresh = server.beginPairing()
        #expect(!server.pairingSecretSpent)
        let phone = try await TestPhone.connect("phone", port: port)
        _ = try await pair(phone, server: server, uri: fresh)
    }

    /// R37 M2: ... and when bad proofs burn it.
    @Test func unknownCertRefusedAfterSecretBurned() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        let uri = server.beginPairing()
        for _ in 0..<MacPairingFlow.maxBadAttempts {
            let phone = try await TestPhone.connect("phone", port: port)
            try await phone.sendPairRequest(uri, secret: Data(repeating: 7, count: 32))
            #expect(try await phone.nextErrorCode() == .badPairingSecret)
            #expect(await phone.ended())
        }
        #expect(await eventually { server.pairingSecretSpent })
        #expect(await refusedAtTLS("phone", port: port))
        #expect(server.state == .pairing(uri: uri, code: nil))
    }

    /// A paired phone that sends an old pairing request still gets PAIRING_EXPIRED (R2).
    @Test func pairedPhoneWithExpiredWindowGetsExpired() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones, pairingLifetime: 0.05)
        defer { server.stop() }
        let uri = server.beginPairing()
        try await Task.sleep(for: .milliseconds(150))
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
    }
}

// MARK: Bonjour instance name (R37 M1)

@MainActor
@Test func bonjourInstanceNameRotatesEachEpochAndOnWake() {
    var now = Date(timeIntervalSince1970: 1_800_000_000) // an epoch boundary
    let advertiser = BonjourAdvertiser(discoveryKey: Data(repeating: 9, count: 32), clock: { now })
    func valid(_ name: String) -> Bool {
        name.count == 11 && name.hasPrefix("am-") && name.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }
    let first = advertiser.currentInstanceName()
    #expect(valid(first))
    now += 600 // same epoch
    #expect(advertiser.currentInstanceName() == first)
    now += 300 // next epoch
    let second = advertiser.currentInstanceName()
    #expect(valid(second))
    #expect(second != first)
    advertiser.rotateInstanceName() // wake
    let third = advertiser.currentInstanceName()
    #expect(valid(third))
    #expect(third != second)
}
