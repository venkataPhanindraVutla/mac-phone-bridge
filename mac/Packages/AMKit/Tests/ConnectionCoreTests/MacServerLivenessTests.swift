import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

// MARK: helpers

/// The Mac lists `liveness.v1` in every test here; whether it is shared is up to the phone's hello.
private let livenessCaps: Set<String> = ["status.v1", "find.v1", Liveness.capability]

/// Connects the paired test phone, sends its hello and reads the Mac's. Returns the phone and
/// the id of the Mac's hello.
@MainActor
private func connectPhone(port: UInt16, capabilities: [String] = ["status.v1", "find.v1", "liveness.v1"])
    async throws -> (TestPhone, UInt64) {
    let phone = try await TestPhone.connect("phone", port: port)
    try await phone.sendHello(capabilities: capabilities)
    let hello = try #require(await phone.next())
    #expect(hello.type == MessageType.hello.rawValue)
    return (phone, hello.id)
}

@MainActor
private func knownPhoneStore() throws -> (InMemoryPairedPhoneStore, PairedPhone) {
    let phones = InMemoryPairedPhoneStore()
    let known = try pairedPhone("phone")
    try phones.save(known)
    return (phones, known)
}

/// A clock that moves only when the test calls `advance(by:)`.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    /// How many `sleep` calls are waiting.
    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    c.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    lock.unlock()
                }
            }
        } onCancel: {
            let s = lock.withLock { sleepers.removeValue(forKey: id) }
            s?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: d)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers.removeValue(forKey: key) }
            return Array(ready.values)
        }
        for s in due { s.continuation.resume() }
    }
}

// MARK: tests

/// SPEC 7 with `liveness.v1` shared: the Mac pings every interval and drops the phone at the
/// third consecutive interval with nothing received; without it, the 0.1 rules hold.
@MainActor
@Suite(.serialized) struct MacServerLivenessTests {
    @Test func macPingsLivenessPhone() async throws {
        let (phones, _) = try knownPhoneStore()
        let (server, port, _) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                      pingInterval: .milliseconds(100))
        defer { server.stop() }
        let (phone, helloID) = try await connectPhone(port: port)
        let ping = try #require(await phone.next(timeout: .seconds(1)))
        #expect(ping.type == MessageType.ping.rawValue)
        #expect(ping.channel == .system)
        #expect(ping.replyTo == 0)
        #expect(ping.id > helloID)
        #expect(try AMPing(serializedBytes: ping.payload) == AMPing())
    }

    @Test func answeringPhoneStaysConnected() async throws {
        let (phones, _) = try knownPhoneStore()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                        pingInterval: .milliseconds(100))
        defer { server.stop() }
        let (phone, _) = try await connectPhone(port: port)
        #expect(await eventually { server.state != .idle })
        let deadline = ContinuousClock.now + .milliseconds(1500)
        var pings = 0
        while ContinuousClock.now < deadline {
            if let e = await phone.next(timeout: .milliseconds(50)), e.type == MessageType.ping.rawValue {
                pings += 1
                try await phone.conn.send(.pong, AMPong(), channel: .system, replyTo: e.id)
            }
            #expect(server.state != .idle)
        }
        #expect(pings >= 5)
        #expect(server.state != .idle)
        #expect(!log.events.contains { if case .disconnected = $0 { true } else { false } })
    }

    @Test func silentLivenessPhoneIsDroppedAfterThreeMissedIntervals() async throws {
        let (phones, known) = try knownPhoneStore()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                        pingInterval: .milliseconds(100))
        defer { server.stop() }
        let (phone, _) = try await connectPhone(port: port)
        var pings = 0
        while let e = await phone.next(timeout: .seconds(2)) {
            if e.type == MessageType.ping.rawValue { pings += 1 }
        }
        #expect(await phone.ended(timeout: .seconds(2)))
        #expect(pings >= 3)
        #expect(await eventually(timeout: .seconds(2)) { log.contains(.disconnected(known)) })
        #expect(server.state == .idle)
    }

    @Test func livenessSessionIgnoresSilenceTimeout() async throws {
        let (phones, known) = try knownPhoneStore()
        let (server, port, log) = try await startServer(phones: phones, silenceTimeout: .milliseconds(150),
                                                        capabilities: livenessCaps,
                                                        pingInterval: .milliseconds(200))
        defer { server.stop() }
        _ = try await connectPhone(port: port)
        #expect(await eventually { server.state != .idle })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.state != .idle, "the 75 s-style silence rule must not apply to a liveness session")
        #expect(await eventually(timeout: .seconds(2)) { server.state == .idle })
        #expect(log.contains(.disconnected(known)))
    }

    @Test func legacyPhoneGetsNoPings() async throws {
        let (phones, _) = try knownPhoneStore()
        let (server, port, _) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                      pingInterval: .milliseconds(100))
        defer { server.stop() }
        let (phone, _) = try await connectPhone(port: port, capabilities: ["status.v1", "find.v1"])
        #expect(await eventually { server.activePhone?.shared == ["status.v1", "find.v1"] })
        #expect(await phone.next(timeout: .milliseconds(500)) == nil)
        #expect(server.state != .idle)
    }

    @Test func pongIsNotForwardedToFeatures() async throws {
        let (phones, _) = try knownPhoneStore()
        let (server, port, _) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                      pingInterval: .milliseconds(100))
        defer { server.stop() }
        var received: [AMEnvelope] = []
        server.onMessage = { received.append($0) }
        let (phone, _) = try await connectPhone(port: port)
        var pongs = 0
        while pongs < 3 {
            let e = try #require(await phone.next(timeout: .seconds(1)))
            guard e.type == MessageType.ping.rawValue else { continue }
            try await phone.conn.send(.pong, AMPong(), channel: .system, replyTo: e.id)
            pongs += 1
        }
        var status = AMStatusUpdate()
        status.batteryPercent = 40
        try await phone.conn.send(.statusUpdate, status, channel: .status)
        #expect(await eventually { !received.isEmpty })
        #expect(received.map(\.type) == [MessageType.statusUpdate.rawValue])
    }

    /// The default 30 s interval, on an injected clock: first ping 30 s after the hello, then a
    /// drop at the third consecutive silent tick (4th tick), with exactly 3 pings sent.
    @Test func livenessTimerFollowsInjectedClock() async throws {
        let (phones, known) = try knownPhoneStore()
        let clock = ManualClock()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                        livenessClock: clock)
        defer { server.stop() }
        let (phone, _) = try await connectPhone(port: port)
        #expect(await eventually { clock.pendingSleepers == 1 })

        clock.advance(by: .seconds(29))
        #expect(await phone.next(timeout: .milliseconds(200)) == nil, "no ping before 30 s")
        clock.advance(by: .seconds(1))
        #expect(try #require(await phone.next()).type == MessageType.ping.rawValue)

        for _ in 0..<2 {
            #expect(await eventually { clock.pendingSleepers == 1 })
            clock.advance(by: .seconds(30))
            #expect(try #require(await phone.next()).type == MessageType.ping.rawValue)
        }
        #expect(server.state != .idle)
        #expect(await eventually { clock.pendingSleepers == 1 })
        clock.advance(by: .seconds(30))
        #expect(await phone.next() == nil)
        #expect(await phone.ended())
        #expect(await eventually { log.contains(.disconnected(known)) })
        #expect(clock.pendingSleepers == 0, "the pinger stops with the session")
    }

    /// An envelope from the phone between ticks keeps it: with a pong after every ping, the
    /// injected clock can run far past the drop point.
    @Test func answeredPingsResetTheSilentCount() async throws {
        let (phones, _) = try knownPhoneStore()
        let clock = ManualClock()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                        livenessClock: clock)
        defer { server.stop() }
        let (phone, _) = try await connectPhone(port: port)
        var received: [AMEnvelope] = []
        server.onMessage = { received.append($0) }
        for i in 0..<8 {
            #expect(await eventually { clock.pendingSleepers == 1 })
            clock.advance(by: .seconds(30))
            let ping = try #require(await phone.next())
            #expect(ping.type == MessageType.ping.rawValue)
            if i.isMultiple(of: 2) {
                try await phone.conn.send(.pong, AMPong(), channel: .system, replyTo: ping.id)
            } else {
                // Any envelope counts, not only a pong.
                try await phone.conn.send(.statusUpdate, AMStatusUpdate(), channel: .status)
            }
            // A late reply only shifts the reset by one tick; the count never reaches 3.
            #expect(await eventually { received.count == (i + 1) / 2 })
        }
        #expect(server.state != .idle)
        #expect(!log.events.contains { if case .disconnected = $0 { true } else { false } })
    }

    // MARK: final fix wave (I2a, I3)

    /// I2(a): on wake a `liveness.v1` session stays and is pinged at once; the drop rule still applies.
    @Test func wakeKeepsLivenessSessionAndPingsAtOnce() async throws {
        let (phones, known) = try knownPhoneStore()
        let clock = ManualClock()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps,
                                                        livenessClock: clock)
        defer { server.stop() }
        var ended: [SessionEndReason] = []
        server.logSessionEnd = { ended.append($0) }
        let (phone, _) = try await connectPhone(port: port)
        #expect(await eventually { clock.pendingSleepers == 1 })
        clock.advance(by: .seconds(20)) // part of an interval has passed before the sleep

        server.handleWake()
        let ping = try #require(await phone.next(timeout: .seconds(1)), "a ping at once, not 30 s later")
        #expect(ping.type == MessageType.ping.rawValue)
        #expect(server.activePhone?.phone == known)
        #expect(await eventually(timeout: .seconds(5)) { server.port == port && server.isListening })
        #expect(!log.events.contains { if case .disconnected = $0 { true } else { false } })

        // The phone answers; the session goes on, and the pinger runs on its usual interval.
        try await phone.conn.send(.pong, AMPong(), channel: .system, replyTo: ping.id)
        #expect(await eventually { clock.pendingSleepers == 1 })
        clock.advance(by: .seconds(30))
        #expect(try #require(await phone.next()).type == MessageType.ping.rawValue)
        #expect(server.state != .idle)

        // A phone that stops answering is dropped by the drop rule, not by the wake: three silent
        // ticks (four if the pong above landed just after a tick).
        var ticks = 0
        while !log.contains(.disconnected(known)), ticks < 5 {
            #expect(await eventually { clock.pendingSleepers == 1 })
            clock.advance(by: .seconds(30))
            ticks += 1
            _ = await phone.next(timeout: .milliseconds(300))
        }
        #expect(await eventually { log.contains(.disconnected(known)) })
        #expect((3...4).contains(ticks))
        #expect(ended == [.liveness])
    }

    /// I2(a): a phone without `liveness.v1` is closed on wake, as in 0.1.
    @Test func wakeClosesLegacySession() async throws {
        let (phones, known) = try knownPhoneStore()
        let (server, port, log) = try await startServer(phones: phones, capabilities: livenessCaps)
        defer { server.stop() }
        var ended: [SessionEndReason] = []
        server.logSessionEnd = { ended.append($0) }
        let (phone, _) = try await connectPhone(port: port, capabilities: ["status.v1", "find.v1"])
        #expect(await eventually { server.state != .idle })
        server.handleWake()
        #expect(await phone.ended())
        #expect(log.contains(.disconnected(known)))
        #expect(ended == [.wake])
    }

    /// I3: each end of a phone session is logged with its reason.
    @Test func sessionEndReasonsAreLogged() async throws {
        let (phones, _) = try knownPhoneStore()
        let (server, port, _) = try await startServer(phones: phones, silenceTimeout: .milliseconds(300),
                                                      capabilities: livenessCaps)
        defer { server.stop() }
        var ended: [SessionEndReason] = []
        server.logSessionEnd = { ended.append($0) }

        // The 75 s rule (here 300 ms) for a phone without liveness.v1.
        _ = try await connectPhone(port: port, capabilities: ["status.v1", "find.v1"])
        #expect(await eventually(timeout: .seconds(3)) { ended == [.silence] })

        // The same phone connecting again replaces its old session.
        let (first, _) = try await connectPhone(port: port)
        #expect(await eventually { server.state != .idle })
        _ = try await connectPhone(port: port)
        #expect(await first.ended())
        #expect(await eventually { ended == [.silence, .replaced] })

        // A goodbye from the phone.
        let (third, _) = try await connectPhone(port: port)
        #expect(await eventually { ended == [.silence, .replaced, .replaced] })
        var bye = AMGoodbye()
        bye.reason = .shutdown
        try await third.conn.send(.goodbye, bye, channel: .system)
        #expect(await eventually { ended == [.silence, .replaced, .replaced, .goodbye] })

        // The phone closing its socket.
        let (fourth, _) = try await connectPhone(port: port)
        #expect(await eventually { server.state != .idle })
        fourth.conn.close()
        #expect(await eventually { ended.last == .eof })

        // The Mac app stopping.
        _ = try await connectPhone(port: port)
        #expect(await eventually { server.state != .idle })
        server.stop()
        #expect(ended.last == .stop)
        #expect(ended.count == 6)
    }
}
