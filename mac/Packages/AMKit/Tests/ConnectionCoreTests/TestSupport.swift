import AMProtocol
@_exported import AMTestSupport
import Foundation
import Network
@testable import ConnectionCore

/// Repository root, found from this file's location.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ConnectionCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // AMKit
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // mac
    .deletingLastPathComponent() // repo

func identityURL(_ name: String) -> URL {
    repoRoot.appendingPathComponent("protocol/testdata/identities/\(name).p12")
}

/// Loads one of the committed test identities (password "test").
func testIdentity(_ name: String) throws -> TLSIdentity {
    try P12IdentityProvider(url: identityURL(name), password: "test").identity()
}

/// The fingerprint `crypto.json` lists for the named test certificate.
func vectorFingerprint(_ name: String) throws -> Data {
    struct File: Decodable {
        struct FP: Decodable { let name: String; let fp_hex: String }
        let fingerprints: [FP]
    }
    let data = try Data(contentsOf: repoRoot.appendingPathComponent("protocol/vectors/crypto.json"))
    let file = try JSONDecoder().decode(File.self, from: data)
    guard let hex = file.fingerprints.first(where: { $0.name == name })?.fp_hex else {
        throw TestError("no fingerprint vector named \(name)")
    }
    return Data(hexString: hex)
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// `Data(hexString:)` and `eventually` are in AMTestSupport.
extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Opens a TLS client connection to 127.0.0.1:`port` as `identity`, pinning `pin`.
func connectClient(port: UInt16, identity: TLSIdentity, pin: Data,
                   timeout: Duration = .seconds(3)) async throws -> ControlConnection {
    let params = TLSParameters.client(identity: identity, acceptPeer: { $0 == pin })
    let nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
    return try await ControlConnection.open(nw, timeout: timeout)
}

/// Collects a connection's incoming envelopes so a test can wait for them one by one.
actor Inbox {
    private var items: [AMEnvelope] = []
    private(set) var ended = false
    private(set) var endError: (any Error)?

    init(_ stream: AsyncThrowingStream<AMEnvelope, Error>) {
        Task { await self.drain(stream) }
    }

    private func drain(_ stream: AsyncThrowingStream<AMEnvelope, Error>) async {
        do {
            for try await e in stream { items.append(e) }
        } catch {
            endError = error
        }
        ended = true
    }

    /// The next envelope, or nil when the stream ended or `timeout` passed first.
    func next(timeout: Duration = .seconds(3)) async -> AMEnvelope? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !items.isEmpty { return items.removeFirst() }
            if ended { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// True once the stream has ended (EOF, error or close) within `timeout`.
    func waitForEnd(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if ended { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ended
    }
}
