import AMProtocol
import Foundation
import Network
import Testing
@testable import ConnectionCore

/// A store whose `remove` can be made to fail.
final class RemoveFailingPhoneStore: PairedPhoneStore, @unchecked Sendable {
    private let inner = InMemoryPairedPhoneStore()
    nonisolated(unsafe) var failRemove = false

    func all() throws -> [PairedPhone] { try inner.all() }
    func save(_ phone: PairedPhone) throws { try inner.save(phone) }
    func remove(id: String) throws {
        if failRemove { throw IdentityError.keychain(-25308) }
        try inner.remove(id: id)
    }
}

private struct NoListener: Error {}

@MainActor
@Suite struct MacServerHardeningTests {
    /// 0.1-F-a: the window closed between the TLS handshake and the attach.
    @Test func windowClosingAfterTLSGivesPairingExpired() async throws {
        let (server, port, log) = try await startServer()
        defer { server.stop() }
        _ = server.beginPairing()
        server.beforeAttachForTesting = { server.confirmPairing(false) }   // closes the window
        let phone = try await TestPhone.connect("phone", port: port)
        #expect(try await phone.nextErrorCode() == .pairingExpired)
        #expect(await phone.ended())
        #expect(await eventually { log.contains(.rejected(.notPairedCertificate)) })
    }

    /// 0.1-T5-c: a listener that cannot be started again after wake is reported.
    @Test func wakeThatCannotListenEmitsListenerFailed() async throws {
        let (server, _, log) = try await startServer()
        defer { server.stop() }
        server.makeListener = { _, _ in throw NoListener() }
        server.handleWake()
        #expect(log.events.contains { if case .listenerFailed = $0 { true } else { false } })
    }

    @Test func listenerRetryThatCannotStartEmitsListenerFailed() async throws {
        let (server, _, log) = try await startServer()
        defer { server.stop() }
        server.makeListener = { _, _ in throw NoListener() }
        server.simulateListenerFailureForTesting()
        #expect(await eventually { log.events.contains { if case .listenerFailed = $0 { true } else { false } } })
    }

    /// 0.1-FR-b: a start on any port does not go on retrying the stale one.
    @Test func startOnAnyPortForgetsTheOldPort() async throws {
        let (server, _, _) = try await startServer()
        server.stop()
        #expect(server.port != nil)
        server.makeListener = { _, _ in throw NoListener() }
        #expect(throws: NoListener.self) { try server.start(port: 0) }
        #expect(server.port == nil)
    }

    /// 0.1-T5-m: a failed remove leaves the phone trusted and connected, and says so.
    @Test func forgetThatCannotRemoveChangesNothing() async throws {
        let phones = RemoveFailingPhoneStore()
        let known = try pairedPhone("phone")
        try phones.save(known)
        let (server, port, log) = try await startServer(phones: phones)
        defer { server.stop() }
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.activePhone != nil })

        phones.failRemove = true
        let done = await server.forget(phoneID: known.id)
        #expect(!done)
        #expect(try phones.all().count == 1)
        #expect(server.activePhone != nil)
        #expect(!log.contains(.unpaired(known)))
        #expect(await phone.next(timeout: .milliseconds(300)) == nil, "no goodbye")

        phones.failRemove = false
        #expect(await server.forget(phoneID: known.id))
        #expect(try phones.all().isEmpty)
        #expect(log.contains(.unpaired(known)))
    }

    /// 0.1-F-d: the app can wait until the goodbye has been handed to the network.
    @Test func stopCanBeWaitedOnUntilTheGoodbyeIsFlushed() async throws {
        let phones = InMemoryPairedPhoneStore()
        try phones.save(try pairedPhone("phone"))
        let (server, port, _) = try await startServer(phones: phones)
        let phone = try await TestPhone.connect("phone", port: port)
        try await phone.sendHello()
        _ = await phone.next()
        #expect(await eventually { server.activePhone != nil })
        server.stop()
        #expect(server.pendingFlushes == 1)
        await server.waitForFlush(timeout: .seconds(30))
        #expect(server.pendingFlushes == 0)
        let bye = try #require(await phone.next())
        #expect(bye.type == MessageType.goodbye.rawValue)
    }

    @Test func waitForFlushWithNothingPendingReturnsAtOnce() async throws {
        let (server, _, _) = try await startServer()
        defer { server.stop() }
        await server.waitForFlush(timeout: .seconds(3))
    }
}
