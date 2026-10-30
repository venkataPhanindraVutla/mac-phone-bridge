import Foundation
import Testing
@testable import FeatureFocus

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func nothingAppliedIsUser() {
    var guard_ = EchoGuard()
    #expect(guard_.classify(true, at: t0) == .user)
}

@Test func withinWindowIsSuppressed() {
    var early = EchoGuard()
    early.applied(true, at: t0)
    #expect(early.classify(true, at: t0.addingTimeInterval(3)) == .suppress)
    var edge = EchoGuard()
    edge.applied(true, at: t0)
    #expect(edge.classify(true, at: t0.addingTimeInterval(9.999)) == .suppress)
}

@Test func lateMatchIsSync() {
    var guard_ = EchoGuard()
    guard_.applied(true, at: t0)
    #expect(guard_.classify(true, at: t0.addingTimeInterval(10)) == .sync)
    // Consumed: the next match is the user's own.
    #expect(guard_.classify(true, at: t0.addingTimeInterval(50)) == .user)
}

@Test func otherTransitionClearsApplied() {
    var guard_ = EchoGuard()
    guard_.applied(true, at: t0)
    #expect(guard_.classify(false, at: t0.addingTimeInterval(2)) == .user)
    #expect(guard_.classify(true, at: t0.addingTimeInterval(4)) == .user)
}

@Test func theLatestApplyCounts() {
    var guard_ = EchoGuard()
    guard_.applied(true, at: t0)
    guard_.applied(false, at: t0.addingTimeInterval(1))
    #expect(guard_.classify(false, at: t0.addingTimeInterval(2)) == .suppress)
}

@Test func theWindowIsConfigurable() {
    var guard_ = EchoGuard(window: 1)
    guard_.applied(true, at: t0)
    #expect(guard_.classify(true, at: t0.addingTimeInterval(1)) == .sync)
}

/// Ruling R28: off then on after an applied "on" is the user's own, even past the window.
@Test func userOffThenOnAfterApplyIsUser() {
    var guard_ = EchoGuard()
    guard_.applied(true, at: t0)
    #expect(guard_.classify(false, at: t0.addingTimeInterval(20)) == .user)
    #expect(guard_.classify(true, at: t0.addingTimeInterval(25)) == .user)
}
