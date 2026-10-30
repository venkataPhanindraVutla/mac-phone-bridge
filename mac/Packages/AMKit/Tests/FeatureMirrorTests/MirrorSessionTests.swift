import AMTestSupport
import ConnectionCore
import Foundation
import Testing
@testable import FeatureMirror

/// A link whose sends never complete until it is closed (a stalled phone).
final class StalledPipe: BulkPipe, @unchecked Sendable {
    private let lock = NSLock()
    private var closedFlag = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var isClosed: Bool { lock.withLock { closedFlag } }

    func receive(maximum: Int) async throws -> Data? {
        try await park()
        return nil
    }

    func send(_ data: Data) async throws { try await park() }

    func close() {
        let parked: [CheckedContinuation<Void, Error>] = lock.withLock {
            closedFlag = true
            defer { waiters = [] }
            return waiters
        }
        for w in parked { w.resume(throwing: CancellationError()) }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let closed: Bool = lock.withLock {
                if !closedFlag { waiters.append(c) }
                return closedFlag
            }
            if closed { c.resume(throwing: CancellationError()) }
        }
    }
}

@Suite struct MirrorSessionTests {
    /// R45: what was queued before close() is written, then the control link closes; video closes at once.
    @Test func closeDeliversQueuedControlBytesThenCloses() async throws {
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in })
        let (videoMac, _) = MemoryPipe.pair()
        let (controlMac, controlPhone) = MemoryPipe.pair()
        session.attach(videoMac, role: .mirrorVideo)
        session.attach(controlMac, role: .mirrorControl)
        let up = ScrcpyControl.touch(action: 1, x: 1, y: 2, width: 320, height: 640, pressure: 0)
        session.sendControl(up)
        session.close()
        #expect(videoMac.isClosed)
        // Nothing queued after close() goes out.
        session.sendControl(Data([0xEE]))
        let bytes = try await readAll(controlPhone, 1 << 20)
        #expect(bytes == up)
        #expect(controlMac.isClosed)
    }

    /// A control link that cannot take the bytes is closed at the drain deadline, 200 ms; close()
    /// itself returns at once.
    @Test func stalledControlLinkClosesAtTheDeadline() async throws {
        let fake = FakeResetClock()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in }, clock: fake.clock)
        let stalled = StalledPipe()
        session.attach(stalled, role: .mirrorControl)
        session.sendControl(Data([2]))
        session.close()
        #expect(!stalled.isClosed)
        #expect(fake.scheduled == 1)
        fake.advance(by: .milliseconds(199))
        #expect(!stalled.isClosed)
        fake.advance(by: .milliseconds(1))
        #expect(stalled.isClosed)
    }

    /// With nothing queued the control link closes as soon as the writer sees the end, not at the deadline.
    @Test func idleControlLinkClosesWithoutWaitingForTheDeadline() async throws {
        let fake = FakeResetClock()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in }, clock: fake.clock)
        let (controlMac, _) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        session.close()
        try await until("closed") { controlMac.isClosed }
        #expect(fake.elapsed == .zero)
    }

    /// A link attached after close() is closed at once.
    @Test func linkAfterCloseIsClosed() {
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in })
        session.close()
        let (controlMac, _) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        #expect(controlMac.isClosed)
    }
}
