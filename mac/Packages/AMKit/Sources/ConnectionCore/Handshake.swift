import AMProtocol

public enum HandshakeResult: Equatable, Sendable {
    case ok(shared: Set<String>)
    case incompatible(remoteVersion: UInt32)
}

public enum Handshake {
    public static let protocolVersion: UInt32 = 1

    /// Protocol versions must be equal; otherwise the shared capabilities are the intersection.
    public static func evaluate(local: AMHello, remote: AMHello) -> HandshakeResult {
        guard remote.protocolVersion == protocolVersion, local.protocolVersion == protocolVersion else {
            return .incompatible(remoteVersion: remote.protocolVersion)
        }
        return .ok(shared: Set(local.capabilities).intersection(remote.capabilities))
    }
}
