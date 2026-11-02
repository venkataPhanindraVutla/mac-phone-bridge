import AMProtocol
import AMTestSupport
import ConnectionCore
import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import FeatureFiles

// The engine over the real BulkServer, BulkLink and TLS 1.3 on loopback, with a hand-driven
// phone: what am-mac-sim --files runs, without the phone simulator.

private let identities = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol/testdata/identities")

private func identity(_ name: String) throws -> TLSIdentity {
    try P12IdentityProvider(url: identities.appendingPathComponent("\(name).p12"), password: "test").identity()
}

/// Resumes a continuation once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    /// True when this call resumed it (the first one).
    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        let c = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
        return c != nil
    }
}

private struct ClientError: Error {}

/// A phone-side bulk connection: hello, then raw bytes.
private final class PhoneBulk: @unchecked Sendable {
    let nw: NWConnection

    init(port: UInt16) throws {
        let pin = try identity("mac").fingerprint
        let params = TLSParameters.client(identity: try identity("phone"), acceptPeer: { $0 == pin })
        nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func open(token: Data, role: AMBulkRole) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            nw.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed, .waiting, .cancelled: once.resume(.failure(ClientError()))
                default: break
                }
            }
            nw.start(queue: DispatchQueue(label: "test.phone-bulk"))
            // A handshake that neither finishes nor fails is cancelled: the test fails, not hangs.
            let nw = nw
            Task {
                try? await Task.sleep(for: .seconds(30))
                if once.resume(.failure(ClientError())) { nw.cancel() }
            }
        }
        var hello = AMBulkHello()
        hello.token = token
        hello.role = role
        try await send(try Frame.encode(AMEnvelope(channel: .files, id: 1, type: .bulkHello, payload: hello)))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nw.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func read(_ count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk: Data? = try await withCheckedThrowingContinuation { c in
                nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                    if let data, !data.isEmpty { c.resume(returning: data) } else if let error {
                        c.resume(throwing: error)
                    } else { c.resume(returning: done ? nil : Data()) }
                }
            }
            guard let chunk else { break }
            out.append(chunk)
        }
        return out
    }

    func close() { nw.cancel() }
}

@MainActor @Test func loopbackBulkServerCarriesBothDirections() async throws {
    let server = BulkServer(identity: P12IdentityProvider(url: identities.appendingPathComponent("mac.p12"),
                                                          password: "test"))
    let r = Rig(timing: TransferTiming(progressInterval: .milliseconds(50)))
    defer { r.cleanUp(); server.stop() }
    // The rig's fake bulk stands in for routing only; the real server issues the tokens.
    let engine = TransferEngine(
        bulk: server,
        send: { [weak r] type, message in r?.sent.all.append((type, message)) },
        destination: { [dir = r.dir] _ in .folder(dir) },
        freeBytes: { _ in nil })
    server.onLink = { pipe, grant in engine.link(pipe, grant: grant) }
    try server.start()
    try await until("bulk port") { server.port != nil }
    let port = try #require(server.port)

    await engine.connected(phoneID: try identity("phone").deviceID, phoneName: "Pixel", shared: ["files.v1"])
    try await until("endpoint") { r.sent.types == [.filesEndpoint] }
    #expect(r.sent.of(.filesEndpoint, AMBulkEndpoint.self).first?.port == UInt32(port))

    // Phone to Mac.
    let bytes = randomBytes(3 * 1024 * 1024 + 11)
    var offer = AMTransferOffer()
    offer.transferID = "p1"; offer.name = "clip.mov"; offer.size = UInt64(bytes.count); offer.kind = .file
    await engine.message(envelope(.filesOffer, offer))
    try await until("accept") { !r.sent.of(.filesAccept, AMTransferAccept.self).isEmpty }
    let token = try #require(r.sent.of(.filesAccept, AMTransferAccept.self).first?.token)
    #expect(token.count == 32)
    let up = try PhoneBulk(port: port)
    try await up.open(token: token, role: .phoneSends)
    try await up.send(bytes)
    var complete = AMTransferComplete(); complete.transferID = "p1"; complete.sha256 = sha(bytes)
    await engine.message(envelope(.filesComplete, complete))
    let saved = r.dir.appendingPathComponent("clip.mov")
    try await until("received") { engine.transfers.first { $0.id == "p1" }?.state == .done(saved) }
    #expect(try Data(contentsOf: saved) == bytes)
    up.close()

    // Mac to phone: the same file back.
    let id = try #require(engine.send(files: [saved]).first)
    try await until("offer") { r.sent.of(.filesOffer, AMTransferOffer.self).count == 1 }
    let sentOffer = try #require(r.sent.of(.filesOffer, AMTransferOffer.self).first)
    var accept = AMTransferAccept(); accept.transferID = id
    await engine.message(envelope(.filesAccept, accept))
    let down = try PhoneBulk(port: port)
    try await down.open(token: sentOffer.token, role: .phoneReceives)
    #expect(try await down.read(bytes.count) == bytes)
    try await until("complete") { !r.sent.of(.filesComplete, AMTransferComplete.self).isEmpty }
    #expect(r.sent.of(.filesComplete, AMTransferComplete.self).first?.sha256 == sha(bytes))
    var received = AMTransferReceived(); received.transferID = id
    await engine.message(envelope(.filesReceived, received))
    #expect(engine.transfers.first { $0.id == id }?.state == .done(nil))
    down.close()

    // A disconnect closes the door: the phone is no longer allowed.
    engine.disconnected()
    #expect(engine.transfers.allSatisfy { $0.isFinal })
}
