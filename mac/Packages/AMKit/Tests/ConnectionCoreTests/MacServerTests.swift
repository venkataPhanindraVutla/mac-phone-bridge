import AMProtocol
import Foundation
import Network
import Testing
@testable import ConnectionCore

// MARK: helpers

@MainActor
final class EventLog {
    var events: [MacServerEvent] = []
    func contains(_ e: MacServerEvent) -> Bool { events.contains(e) }
}

/// A Swift stand-in for the phone: a TLS client plus its inbox.
struct TestPhone {
    let identity: TLSIdentity
    let conn: ControlConnection
    let inbox: Inbox

    static func connect(_ name: String, port: UInt16) async throws -> TestPhone {
        let identity = try testIdentity(name)
        let conn = try await connectClient(port: port, identity: identity, pin: try vectorFingerprint("mac"))
        return TestPhone(identity: identity, conn: conn, inbox: Inbox(conn.envelopes))
    }

    func next(timeout: Duration = .seconds(3)) async -> AMEnvelope? { await inbox.next(timeout: timeout) }

    /// The next message, which must be `system.error`; returns its code.
    func nextErrorCode() async throws -> AMErrorCode {
        let e = try #require(await next())
        #expect(e.type == MessageType.error.rawValue)
        #expect(e.channel == .system)
        return try AMError(serializedBytes: e.payload).code
    }

    func sendHello(version: UInt32 = 1, capabilities: [String] = ["status.v1", "find.v1"]) async throws {
        var hello = AMHello()
        hello.protocolVersion = version
        hello.appVersion = "test"
        hello.capabilities = capabilities
        hello.setupLevel = .basic
        hello.deviceName = "Pixel"
        hello.deviceModel = "Pixel 9"
        try await conn.send(.hello, hello, channel: .system)
    }

    func sendPairRequest(_ uri: PairingURI, secret: Data? = nil) async throws {
        var req = AMPairRequest()
        req.protocolVersion = 1
        req.secretProof = PairingCrypto.secretProof(
            secret: secret ?? uri.secret, macFingerprint: uri.macFingerprint,
            phoneFingerprint: identity.fingerprint)
        req.deviceName = "Pixel"
        req.deviceModel = "Pixel 9"
        try await conn.send(.pairRequest, req, channel: .pairing)
    }

    func sendConfirm(_ accepted: Bool) async throws {
        var c = AMPairConfirm()
        c.accepted = accepted
        try await conn.send(.pairConfirm, c, channel: .pairing)
    }

    func ended(timeout: Duration = .seconds(3)) async -> Bool { await inbox.waitForEnd(timeout: timeout) }
}

func pairedPhone(_ name: String) throws -> PairedPhone {
    let id = try testIdentity(name)
    return PairedPhone(id: id.deviceID, name: "Pixel", model: "Pixel 9",
                       certificateDER: id.certificateDER, pairedAt: Date(timeIntervalSince1970: 1))
}

@MainActor
func startServer(phones: any PairedPhoneStore = InMemoryPairedPhoneStore(),
                 secrets: any SecretStore = InMemorySecretStore(),
                 silenceTimeout: Duration = .seconds(75),
                 pairingLifetime: TimeInterval = 300,
                 confirmationTimeout: Duration = .seconds(60)) async throws -> (MacServer, UInt16, EventLog) {
    let server = MacServer(
        identity: P12IdentityProvider(url: identityURL("mac"), password: "test"),
        phones: phones, secrets: secrets, macName: "Test Mac", appVersion: "0.1-test",
        capabilities: ["status.v1", "find.v1"], advertise: false,
        silenceTimeout: silenceTimeout, pairingLifetime: pairingLifetime,
        confirmationTimeout: confirmationTimeout)
    let log = EventLog()
    server.onEvent = { log.events.append($0) }
    try server.start()
    #expect(await eventually { server.port != nil })
    return (server, try #require(server.port), log)
}

/// Runs the full pairing sequence as `phone` and returns the PairComplete it received.
@MainActor
func pair(_ phone: TestPhone, server: MacServer, uri: PairingURI) async throws -> AMPairComplete {
    try await phone.sendPairRequest(uri)
    let verified = try #require(await phone.next())
    #expect(verified.type == MessageType.pairVerified.rawValue)
    let code = PairingCrypto.confirmationCode(macFingerprint: uri.macFingerprint,
                                              phoneFingerprint: phone.identity.fingerprint)
    #expect(await eventually { server.state == .pairing(uri: uri, code: code) })
    try await phone.sendConfirm(true)
    server.confirmPairing(true)
    let confirm = try #require(await phone.next())
    #expect(confirm.type == MessageType.pairConfirm.rawValue)
    #expect(try AMPairConfirm(serializedBytes: confirm.payload).accepted)
    let complete = try #require(await phone.next())
    #expect(complete.type == MessageType.pairComplete.rawValue)
    return try AMPairComplete(serializedBytes: complete.payload)
}

// MARK: tests

@MainActor
@Suite struct MacServerTests {
    @Test func pairThenHelloConnects() async throws {
        let phones = InMemoryPairedPhoneStore()
        let secrets = InMemorySecretStore()
        let (server, port, log) = try await startServer(phones: phones, secrets: secrets)
        defer { server.stop() }
        let uri = server.beginPairing()
        #expect(uri.port == port)
        #expect(uri.macFingerprint == (try vectorFingerprint("mac")))
        #expect(!uri.hosts.isEmpty)
        #expect(uri.macName == "Test Mac")
        #expect(server.state == .pairing(uri: uri, code: nil))

        let phone = try await TestPhone.connect("phone", port: port)
        let complete = try await pair(phone, server: server, uri: uri)
        #expect(complete.discoveryKey == (try secrets.discoveryKey()))
        #expect(complete.macName == "Test Mac")
        let saved = try #require(try phones.all().first)
        #expect(saved.id == phone.identity.deviceID)
        #expect(saved.certificateDER == phone.identity.certificateDER)
        #expect(saved.name == "Pixel")
        #expect(log.contains(.paired(saved)))

        try await phone.sendHello(capabilities: ["status.v1", "find.v1", "future.v9"])
        let hello = try #require(await phone.next())
        #expect(hello.type == MessageType.hello.rawValue)
        let macHello = try AMHello(serializedBytes: hello.payload)
        #expect(macHello.protocolVersion == 1)
        #expect(Set(macHello.capabilities) == ["status.v1", "find.v1"])
        #expect(await eventually { server.state == .connected(saved, shared: ["status.v1", "find.v1"]) })
        #expect(log.contains(.connected(saved, shared: ["status.v1", "find.v1"])))
    }

    @Test func pairedPhoneReconnectsWithoutWindow() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        #expect(try #require(await phone.next()).type == MessageType.hello.rawValue)
        #expect(await eventually { server.state == .connected(known, shared: ["status.v1", "find.v1"]) })
    }

    @Test func strangerRejectedWhenNoWindowOpen() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        do {
            let stranger = try await TestPhone.connect("stranger", port: port)
            try? await stranger.sendHello()
            #expect(await stranger.next() == nil)
            #expect(await stranger.ended())
        } catch {
            // Refused during the TLS handshake.
        }
        #expect(await eventually { log.contains(.rejected(.notPairedCertificate)) })
        #expect(server.state == .idle)
    }

    @Test func secondPairedPhoneGetsBusy() async throws {
        let phones = InMemoryPairedPhoneStore()
        let first = try pairedPhone("phone")
        try phones.save(first)
        try phones.save(try pairedPhone("stranger"))
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        let a = try await TestPhone.connect("phone", port: port)
        try await a.sendHello()
        _ = await a.next()
        #expect(await eventually { server.state == .connected(first, shared: ["status.v1", "find.v1"]) })

        let b = try await TestPhone.connect("stranger", port: port)
        try await b.sendHello()
        #expect(try await b.nextErrorCode() == .busy)
        #expect(await b.ended())
        #expect(log.contains(.rejected(.busy)))
        #expect(server.state == .connected(first, shared: ["status.v1", "find.v1"]))
    }

    @Test func samePhoneReconnectReplacesStaleSession() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let old = try await TestPhone.connect("phone", port: port)
        try await old.sendHello()
        _ = await old.next()
        let fresh = try await TestPhone.connect("phone", port: port)
        try await fresh.sendHello()
        #expect(try #require(await fresh.next()).type == MessageType.hello.rawValue)
        #expect(await old.ended())
        #expect(server.state == .connected(known, shared: ["status.v1", "find.v1"]))
    }

    @Test func unknownCertNonPairingFirstMessageGetsNotPaired() async throws {
        let (server, port, log) = try await startServer()
        defer { server.stop() }
        _ = server.beginPairing()
        let stranger = try await TestPhone.connect("stranger", port: port)
        try await stranger.sendHello()
        #expect(try await stranger.nextErrorCode() == .notPaired)
        #expect(await stranger.ended())
        #expect(log.contains(.rejected(.notPairedCertificate)))
    }

    @Test func reusedPairingRequestGetsExpired() async throws {
        let (server, port, log) = try await startServer()
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        _ = try await pair(phone, server: server, uri: uri)
        #expect(await eventually { server.state == .idle })

        // Ruling R2: scanning the same QR again, even from the now-paired phone.
        let again = try await TestPhone.connect("phone", port: port)
        try await again.sendPairRequest(uri)
        #expect(try await again.nextErrorCode() == .pairingExpired)
        #expect(await again.ended())
        #expect(log.contains(.rejected(.pairingExpired)))
    }

    @Test func pairingRequestWithoutWindowFromPairedPhoneGetsExpired() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        let stale = PairingURI(macFingerprint: try vectorFingerprint("mac"), secret: Data(repeating: 1, count: 32),
                               hosts: ["127.0.0.1"], port: port, macName: "Test Mac")
        try await phone.sendPairRequest(stale)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
    }

    @Test func expiredWindowGetsExpired() async throws {
        let (server, port, _) = try await startServer(pairingLifetime: 0.05)
        defer { server.stop() }
        let uri = server.beginPairing()
        try await Task.sleep(for: .milliseconds(150))
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
    }

    @Test func badProofGetsBadPairingSecret() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri, secret: Data(repeating: 7, count: 32))
        #expect(try await phone.nextErrorCode() == .badPairingSecret)
        #expect(await phone.ended())
        #expect(server.state == .pairing(uri: uri, code: nil))
    }

    @Test func phoneDeclineCancelsPairing() async throws {
        let phones = InMemoryPairedPhoneStore()
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        _ = await phone.next()
        try await phone.sendConfirm(false)
        #expect(await phone.ended())
        #expect(await eventually { server.state == .idle })
        #expect(log.contains(.rejected(.pairingCancelled)))
        #expect(try phones.all().isEmpty)
    }

    @Test func macDeclineSendsConfirmFalse() async throws {
        let phones = InMemoryPairedPhoneStore()
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        _ = await phone.next()
        #expect(await eventually { if case .pairing(_, .some) = server.state { true } else { false } })
        server.confirmPairing(false)
        let confirm = try #require(await phone.next())
        #expect(confirm.type == MessageType.pairConfirm.rawValue)
        #expect(try AMPairConfirm(serializedBytes: confirm.payload).accepted == false)
        #expect(await phone.ended())
        #expect(server.state == .idle)
        #expect(try phones.all().isEmpty)
    }

    @Test func confirmationTimesOut() async throws {
        let (server, port, log) = try await startServer(confirmationTimeout: .milliseconds(100))
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        _ = await phone.next()
        #expect(await phone.ended())
        #expect(await eventually { log.contains(.rejected(.pairingTimedOut)) })
        #expect(server.state == .idle)
    }

    @Test func protocolMismatchHello() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello(version: 2)
        #expect(try await phone.nextErrorCode() == .protocolMismatch)
        #expect(await phone.ended())
        #expect(await eventually { server.state == .incompatible(phoneName: "Pixel") })
    }

    @Test func pingGetsPongAndMessagesReachOnMessage() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        var received: [AMEnvelope] = []
        server.onMessage = { received.append($0) }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()

        let pingID = try await phone.conn.send(.ping, AMPing(), channel: .system)
        let pong = try #require(await phone.next())
        #expect(pong.type == MessageType.pong.rawValue)
        #expect(pong.replyTo == pingID)

        var status = AMStatusUpdate()
        status.batteryPercent = 55
        status.charging = true
        status.signalLevel = 3
        status.network = .wifi
        try await phone.conn.send(.statusUpdate, status, channel: .status)
        #expect(await eventually { received.contains { $0.type == MessageType.statusUpdate.rawValue } })
        let env = try #require(received.first { $0.type == MessageType.statusUpdate.rawValue })
        #expect(try AMStatusUpdate(serializedBytes: env.payload) == status)

        try await server.send(.findRing, AMRingRequest(), channel: .find)
        let ring = try #require(await phone.next())
        #expect(ring.type == MessageType.findRing.rawValue)
        #expect(ring.channel == .find)
    }

    @Test func sendWithoutPhoneThrows() async throws {
        let (server, _, _) = try await startServer()
        defer { server.stop() }
        await #expect(throws: MacServerError.notConnected) {
            try await server.send(.findRing, AMRingRequest(), channel: .find)
        }
    }

    @Test func silenceTimeoutDropsPhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, log) = try await startServer(phones: phones, silenceTimeout: .milliseconds(200))
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.state != .idle })
        #expect(await phone.ended(timeout: .seconds(2)))
        #expect(await eventually { server.state == .idle })
        #expect(log.contains(.disconnected(known)))
    }

    @Test func goodbyeUnpairedRemovesPhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        var bye = AMGoodbye()
        bye.reason = .unpaired
        try await phone.conn.send(.goodbye, bye, channel: .system)
        #expect(await eventually { (try? phones.all().isEmpty) == true })
        #expect(await eventually { server.state == .idle })
        #expect(log.contains(.unpaired(known)))
    }

    @Test func forgetSendsGoodbyeAndRemovesPhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.state != .idle })
        await server.forget(phoneID: known.id)
        let bye = try #require(await phone.next())
        #expect(bye.type == MessageType.goodbye.rawValue)
        #expect(try AMGoodbye(serializedBytes: bye.payload).reason == .unpaired)
        #expect(await phone.ended())
        #expect(try phones.all().isEmpty)
        #expect(server.state == .idle)

        // Forgotten means no longer trusted at the TLS layer either.
        do {
            let again = try await TestPhone.connect("phone", port: port)
            try? await again.sendHello()
            #expect(await again.next() == nil)
        } catch {}
    }

    @Test func handleWakeClosesAndRelistensOnSamePort() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.state != .idle })

        server.handleWake()
        #expect(await phone.ended())
        #expect(await eventually(timeout: .seconds(5)) { server.port == port && server.isListening })
        let back = try await TestPhone.connect("phone", port: port)
        try await back.sendHello()
        #expect(try #require(await back.next()).type == MessageType.hello.rawValue)
        #expect(await eventually { server.state == .connected(known, shared: ["status.v1", "find.v1"]) })
    }
}

// MARK: review fixes (round 1)

@MainActor
@Suite struct MacServerFixTests {
    @Test func refusedStrangerConnectionIsCancelled() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        var accepted: [NWConnection] = []
        server.onAcceptForTesting = { accepted.append($0) }
        if let stranger = try? await TestPhone.connect("stranger", port: port) {
            try? await stranger.sendHello()
            _ = await stranger.ended()
        }
        #expect(await eventually { log.contains(.rejected(.notPairedCertificate)) })
        #expect(await eventually { accepted.count == 1 && accepted.allSatisfy { $0.state == .cancelled } })
    }

    @Test func oldQRWhileNewerWindowOpenGetsExpired() async throws {
        let (server, port, log) = try await startServer()
        defer { server.stop() }
        let a = server.beginPairing()
        let b = server.beginPairing()
        #expect(a.secret != b.secret)
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(a)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
        #expect(log.contains(.rejected(.pairingExpired)))
        // The old QR did not use up an attempt of the new window: B still pairs.
        let fresh = try await TestPhone.connect("phone", port: port)
        _ = try await pair(fresh, server: server, uri: b)
    }

    @Test func replacingWindowMidConfirmationSendsPairingRejected() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        #expect(try #require(await phone.next()).type == MessageType.pairVerified.rawValue)
        _ = server.beginPairing()
        #expect(try await phone.nextErrorCode() == .pairingRejected)
        #expect(await phone.ended())
    }

    @Test func stopMidConfirmationSendsPairingRejected() async throws {
        let (server, port, _) = try await startServer()
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendPairRequest(uri)
        #expect(try #require(await phone.next()).type == MessageType.pairVerified.rawValue)
        server.stop()
        #expect(try await phone.nextErrorCode() == .pairingRejected)
        #expect(await phone.ended())
    }

    @Test func pairingRequestWhileConnectedGetsExpired() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        var received: [AMEnvelope] = []
        server.onMessage = { received.append($0) }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        let stale = PairingURI(macFingerprint: try vectorFingerprint("mac"), secret: Data(repeating: 1, count: 32),
                               hosts: ["127.0.0.1"], port: port, macName: "Test Mac")
        try await phone.sendPairRequest(stale)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
        #expect(await phone.ended())
        #expect(received.isEmpty)
    }

    @Test func pairingRequestAfterPairCompleteGetsExpired() async throws {
        let (server, port, _) = try await startServer()
        defer { server.stop() }
        let uri = server.beginPairing()
        let phone = try await TestPhone.connect("phone", port: port)
        _ = try await pair(phone, server: server, uri: uri)
        // Same connection, before hello (awaitingHello).
        try await phone.sendPairRequest(uri)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
        #expect(await phone.ended())
    }

    @Test func goodbyeUnpairedClosesEverySessionOfThatPhone() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let idle = try await TestPhone.connect("phone", port: port) // never says hello
        let main = try await TestPhone.connect("phone", port: port)
        try await main.sendHello()
        _ = await main.next()
        var bye = AMGoodbye()
        bye.reason = .unpaired
        try await main.conn.send(.goodbye, bye, channel: .system)
        #expect(await main.ended())
        #expect(await idle.ended())
        #expect(try phones.all().isEmpty)
    }

    @Test func forgetClosesEverySessionAndRemovesFirst() async throws {
        let phones = InMemoryPairedPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, _) = try await startServer(phones: phones)
        defer { server.stop() }
        let idle = try await TestPhone.connect("phone", port: port)
        let main = try await TestPhone.connect("phone", port: port)
        try await main.sendHello()
        _ = await main.next()
        #expect(await eventually { server.state != .idle })
        await server.forget(phoneID: known.id)
        // Removal is synchronous with forget: nothing awaited while still trusted.
        #expect(try phones.all().isEmpty)
        #expect(try AMGoodbye(serializedBytes: try #require(await main.next()).payload).reason == .unpaired)
        #expect(await main.ended())
        #expect(await idle.ended())
        #expect(server.state == .idle)
    }
}

@Test func bonjourInstanceNameAndTXT() {
    let name = BonjourAdvertiser.instanceName
    #expect(name.count == 11)
    #expect(name.hasPrefix("am-"))
    #expect(name.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) })
    #expect(BonjourAdvertiser.instanceName == name) // once per launch

    let key = Data(repeating: 9, count: 32)
    let txt = BonjourAdvertiser.txt(discoveryKey: key, unixSeconds: 1_800_000_000)
    #expect(txt == ["v": "1", "r": PairingCrypto.rotatingID(discoveryKey: key, unixSeconds: 1_800_000_000)])
}

@Test func bonjourRepublishesAtEpochBoundary() {
    #expect(BonjourAdvertiser.secondsUntilNextEpoch(unixSeconds: 900) == 900)
    #expect(BonjourAdvertiser.secondsUntilNextEpoch(unixSeconds: 1799.5) == 0.5)
    #expect(BonjourAdvertiser.secondsUntilNextEpoch(unixSeconds: 1000) == 800)
}

@Test func pairingHostsAreNonLoopbackIPv4ThenLocalName() {
    let hosts = PairingHosts.current()
    #expect(!hosts.isEmpty)
    #expect(!hosts.contains("127.0.0.1"))
    let ordered = PairingHosts.order(
        interfaces: [("lo0", "127.0.0.1"), ("utun3", "10.8.0.2"), ("en0", "192.168.0.121"), ("bridge0", "192.168.64.1"), ("en7", "10.0.0.5")],
        localHostName: "Adas-MacBook")
    #expect(ordered == ["192.168.0.121", "10.0.0.5", "10.8.0.2", "192.168.64.1", "Adas-MacBook.local"])
}
