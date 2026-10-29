import Foundation
import Testing
@testable import FileProviderShared

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@Test func cancelReachesTheCallItsTokenNames() {
    let tokens = CancelTokens()
    let a = Flag(), b = Flag()
    tokens.begin("a") { a.hit() }
    tokens.begin("b") { b.hit() }
    tokens.cancel("a")
    #expect(a.count == 1)
    #expect(b.count == 0)
    tokens.cancel("a")
    #expect(a.count == 1, "once")
    tokens.end("b")
    tokens.cancel("b")
    #expect(b.count == 0, "ended: nothing to cancel")
    #expect(tokens.activeCount == 0)
}

@Test func cancelBeforeTheCallStartsCancelsItAtOnce() {
    let tokens = CancelTokens()
    tokens.cancel("early")
    let f = Flag()
    tokens.begin("early") { f.hit() }
    #expect(f.count == 1)
    #expect(tokens.activeCount == 0)
    // Early cancels are remembered for a while only.
    for i in 0..<(CancelTokens.rememberedEarly + 10) { tokens.cancel("x\(i)") }
    let g = Flag()
    tokens.begin("x0") { g.hit() }
    #expect(g.count == 0, "forgotten")
}

@Test func cancelBoxCancelsWhatIsSetLater() {
    let box = CancelBox()
    box.cancel()
    let f = Flag()
    box.set { f.hit() }
    #expect(f.count == 1)
    let other = CancelBox()
    let g = Flag()
    other.set { g.hit() }
    #expect(g.count == 0)
    other.cancel()
    other.cancel()
    #expect(g.count == 1)
}

private final class Conn {}

@Test func connectionSlotRetiresABusyConnectionOnlyWhenItsCallsEnd() {
    let slot = ConnectionSlot<Conn>()
    #expect(slot.begin() == nil)
    let first = Conn()
    #expect(slot.replace(with: first) == nil)
    let held = slot.begin()
    #expect(held === first)
    #expect(slot.hasLive)
    // A new endpoint while a call is out: the old one stays until that call ends.
    let second = Conn()
    #expect(slot.replace(with: second) == nil)
    #expect(slot.begin() === second)
    #expect(slot.end(first) === first, "its last call ended: invalidate it now")
    #expect(slot.end(second) == nil, "current: stays")
    // Idle old connection: invalidated at once.
    let third = Conn()
    #expect(slot.replace(with: third) === second)
    // Invalidated by the system: gone.
    slot.dropped(third)
    #expect(slot.begin() == nil)
    #expect(!slot.hasLive)
}

@Test func peersArePinnedOnlyWithATeam() {
    let req = CodeRequirement.peer(identifier: CodeRequirement.fileProviderID, team: "ABCDE12345")
    #expect(req == #"anchor apple generic and identifier "io.github.anmirror.mac.fileprovider" and certificate leaf[subject.OU] = "ABCDE12345""#)
    #expect(CodeRequirement.peer(identifier: CodeRequirement.appID, team: nil) == nil, "ad hoc or unsigned")
    #expect(CodeRequirement.peer(identifier: CodeRequirement.appID, team: "") == nil)
    #expect(CodeRequirement.peer(identifier: CodeRequirement.appID, team: #"X" or "1"#) == nil, "not a team ID")
}

@Test func endpointNotesArePerDomain() {
    #expect(FullBuild.endpointNote(for: "aa11") == "io.github.anmirror.mac.fileprovider.endpoint.aa11")
    #expect(FullBuild.endpointNote(for: "aa11") != FullBuild.endpointNote(for: "bb22"))
}
