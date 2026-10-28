import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

/// A settable clock the tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

@Suite struct BulkTokensTests {
    @Test func issuedTokensAre32RandomBytes() {
        let tokens = BulkTokens()
        let a = tokens.issue(role: .phoneSends, context: "t1")
        let b = tokens.issue(role: .phoneSends, context: "t1")
        #expect(a.count == 32)
        #expect(b.count == 32)
        #expect(a != b)
    }

    @Test func redeemReturnsGrantOnce() {
        let tokens = BulkTokens()
        let token = tokens.issue(role: .phoneReceives, context: "t7")
        #expect(tokens.redeem(token, role: .phoneReceives) == BulkGrant(role: .phoneReceives, context: "t7"))
        #expect(tokens.redeem(token, role: .phoneReceives) == nil)
    }

    @Test func unknownTokenIsRejected() {
        let tokens = BulkTokens()
        _ = tokens.issue(role: .phoneSends, context: "t1")
        #expect(tokens.redeem(Data(repeating: 7, count: 32), role: .phoneSends) == nil)
        #expect(tokens.redeem(Data(), role: .phoneSends) == nil)
    }

    @Test func tokenExpiresAfterLifetime() {
        let clock = TestClock()
        let tokens = BulkTokens(now: { clock.now })
        let early = tokens.issue(role: .thumbnails, context: "p1")
        let late = tokens.issue(role: .thumbnails, context: "p2")
        clock.advance(59)
        #expect(tokens.redeem(early, role: .thumbnails) != nil)
        clock.advance(2)
        #expect(tokens.redeem(late, role: .thumbnails) == nil)
    }

    @Test func roleMismatchIsRejectedAndBurnsTheToken() {
        let tokens = BulkTokens()
        let token = tokens.issue(role: .phoneSends, context: "t1")
        #expect(tokens.redeem(token, role: .phoneReceives) == nil)
        #expect(tokens.redeem(token, role: .phoneSends) == nil)
    }

    @Test func revokeContextRemovesOnlyItsTokens() {
        let tokens = BulkTokens()
        let a1 = tokens.issue(role: .phoneSends, context: "a")
        let a2 = tokens.issue(role: .phoneReceives, context: "a")
        let b = tokens.issue(role: .phoneSends, context: "b")
        tokens.revoke(context: "a")
        #expect(tokens.redeem(a1, role: .phoneSends) == nil)
        #expect(tokens.redeem(a2, role: .phoneReceives) == nil)
        #expect(tokens.redeem(b, role: .phoneSends) == BulkGrant(role: .phoneSends, context: "b"))
    }

    @Test func revokeAllRemovesEveryToken() {
        let tokens = BulkTokens()
        let a = tokens.issue(role: .phoneSends, context: "a")
        let b = tokens.issue(role: .thumbnails, context: "b")
        tokens.revokeAll()
        #expect(tokens.redeem(a, role: .phoneSends) == nil)
        #expect(tokens.redeem(b, role: .thumbnails) == nil)
    }

    @Test func injectedRandomIsUsed() {
        var n: UInt8 = 0
        let tokens = BulkTokens(random: {
            n += 1
            return Data(repeating: n, count: 32)
        })
        #expect(tokens.issue(role: .phoneSends, context: "x") == Data(repeating: 1, count: 32))
        #expect(tokens.issue(role: .phoneSends, context: "y") == Data(repeating: 2, count: 32))
    }
}
