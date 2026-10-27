import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

private func hello(version: UInt32 = 1, caps: [String]) -> AMHello {
    var h = AMHello()
    h.protocolVersion = version
    h.capabilities = caps
    return h
}

@Test func handshakeIntersectsCapabilities() {
    let r = Handshake.evaluate(local: hello(caps: ["status.v1", "find.v1"]), remote: hello(caps: ["status.v1"]))
    #expect(r == .ok(shared: ["status.v1"]))
}

@Test func handshakeRejectsOtherProtocolVersion() {
    let r = Handshake.evaluate(local: hello(caps: ["status.v1"]), remote: hello(version: 2, caps: ["status.v1"]))
    #expect(r == .incompatible(remoteVersion: 2))
}

@Test func handshakeWithNoOverlapIsOkAndEmpty() {
    let r = Handshake.evaluate(local: hello(caps: ["a"]), remote: hello(caps: ["b"]))
    #expect(r == .ok(shared: []))
}
