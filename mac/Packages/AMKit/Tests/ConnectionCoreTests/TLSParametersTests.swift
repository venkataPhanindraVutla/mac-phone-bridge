import Network
import Testing
@testable import ConnectionCore

/// SPEC 1: TCP keepalive (idle 60 s, interval 10 s, 3 probes) on control and bulk sockets.
@Suite struct TLSParametersTests {
    @Test func serverAndClientEnableTcpKeepalive() throws {
        let identity = try testIdentity("mac")
        let server = TLSParameters.server(identity: identity) { _ in true }
        let client = TLSParameters.client(identity: identity) { _ in true }
        for params in [server, client] {
            let tcp = try #require(params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
            #expect(tcp.enableKeepalive == true)
            #expect(tcp.keepaliveIdle == 60)
            #expect(tcp.keepaliveInterval == 10)
            #expect(tcp.keepaliveCount == 3)
            #expect(tcp.noDelay == true)
        }
    }
}
