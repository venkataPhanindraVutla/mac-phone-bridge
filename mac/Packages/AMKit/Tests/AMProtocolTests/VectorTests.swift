import Foundation
import Testing
@testable import AMProtocol

// MARK: - Vector loading

private let vectorsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol/vectors")

private func load<T: Decodable>(_ name: String, as: T.Type = T.self) -> T {
    do {
        let data = try Data(contentsOf: vectorsDir.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        fatalError("cannot load vector \(name) from \(vectorsDir.path): \(error)")
    }
}

private func data(hex: String) -> Data {
    precondition(hex.count % 2 == 0)
    var out = Data()
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        out.append(UInt8(hex[idx..<next], radix: 16)!)
        idx = next
    }
    return out
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private struct FramingFile: Decodable {
    struct Env: Decodable {
        let channel: Int
        let id: UInt64
        let replyTo: UInt64
        let type: String
        let payloadHex: String
        enum CodingKeys: String, CodingKey {
            case channel, id, type
            case replyTo = "reply_to"
            case payloadHex = "payload_hex"
        }
    }
    struct Valid: Decodable {
        let name: String
        let envelope: Env
        let frameHex: String
        enum CodingKeys: String, CodingKey { case name, envelope; case frameHex = "frame_hex" }
    }
    struct Invalid: Decodable {
        let name: String
        let frameHex: String
        let error: String
        enum CodingKeys: String, CodingKey { case name, error; case frameHex = "frame_hex" }
    }
    let maxFrameBytes: Int
    let vectors: [Valid]
    let invalid: [Invalid]
    enum CodingKeys: String, CodingKey {
        case vectors, invalid
        case maxFrameBytes = "max_frame_bytes"
    }
}

private func envelope(_ e: FramingFile.Env) -> AMEnvelope {
    var env = AMEnvelope()
    env.channel = AMChannel(rawValue: e.channel) ?? .unspecified
    env.id = e.id
    env.replyTo = e.replyTo
    env.type = e.type
    env.payload = data(hex: e.payloadHex)
    return env
}

private struct CryptoFile: Decodable {
    struct FP: Decodable {
        let name: String
        let certDerHex: String
        let fpHex: String
        enum CodingKeys: String, CodingKey { case name; case certDerHex = "cert_der_hex"; case fpHex = "fp_hex" }
    }
    struct Proof: Decodable {
        let secretHex: String, macFpHex: String, phoneFpHex: String, proofHex: String
        enum CodingKeys: String, CodingKey {
            case secretHex = "secret_hex", macFpHex = "mac_fp_hex"
            case phoneFpHex = "phone_fp_hex", proofHex = "proof_hex"
        }
    }
    struct Code: Decodable {
        let macFpHex: String, phoneFpHex: String, code: String
        enum CodingKeys: String, CodingKey { case macFpHex = "mac_fp_hex", phoneFpHex = "phone_fp_hex", code }
    }
    struct RID: Decodable {
        let keyHex: String, unixSeconds: Int64, epoch: Int64, rid: String
        enum CodingKeys: String, CodingKey { case keyHex = "key_hex", unixSeconds = "unix_seconds", epoch, rid }
    }
    let fingerprints: [FP]
    let proofs: [Proof]
    let codes: [Code]
    let rotatingIds: [RID]
    enum CodingKeys: String, CodingKey {
        case fingerprints, proofs, codes
        case rotatingIds = "rotating_ids"
    }
}

private struct URIFile: Decodable {
    struct Fields: Decodable {
        let version: Int
        let fpHex: String
        let secretHex: String
        let hosts: [String]
        let port: Int
        let macName: String
        enum CodingKeys: String, CodingKey {
            case version, hosts, port
            case fpHex = "fp_hex", secretHex = "secret_hex", macName = "mac_name"
        }
    }
    struct Valid: Decodable { let uri: String; let fields: Fields }
    struct Invalid: Decodable { let name: String; let uri: String; let error: String }
    let valid: [Valid]
    let invalid: [Invalid]
}

// MARK: - Framing

@Test func framingVectors() throws {
    let file: FramingFile = load("framing.json")
    #expect(file.maxFrameBytes == Frame.maxBytes)
    #expect(!file.vectors.isEmpty)
    for v in file.vectors {
        let env = envelope(v.envelope)
        #expect(try Frame.encode(env).hex == v.frameHex, "encode \(v.name)")
        var dec = FrameDecoder()
        dec.append(data(hex: v.frameHex))
        let out = try dec.next()
        #expect(out == env, "decode \(v.name)")
        #expect(try dec.next() == nil)
    }
}

@Test func decoderRejectsInvalidFrames() {
    let file: FramingFile = load("framing.json")
    #expect(!file.invalid.isEmpty)
    for v in file.invalid {
        var dec = FrameDecoder()
        dec.append(data(hex: v.frameHex))
        switch v.error {
        case "emptyFrame":
            #expect(throws: ProtocolError.emptyFrame, "\(v.name)") { try dec.next() }
        case "frameTooLarge":
            do {
                _ = try dec.next()
                Issue.record("\(v.name): expected frameTooLarge")
            } catch let ProtocolError.frameTooLarge(n) {
                #expect(n > Frame.maxBytes)
            } catch {
                Issue.record("\(v.name): wrong error \(error)")
            }
        default:
            Issue.record("unknown expected error \(v.error)")
        }
    }
}

@Test func frameSizeBoundary() throws {
    // Exactly max is valid (header only; body not yet arrived -> nil), max+1 is too large.
    var ok = FrameDecoder()
    ok.append(Data([0x00, 0x10, 0x00, 0x00]))
    #expect(try ok.next() == nil)
    var big = FrameDecoder()
    big.append(Data([0x00, 0x10, 0x00, 0x01]))
    #expect(throws: ProtocolError.frameTooLarge(1_048_577)) { try big.next() }

    var env = AMEnvelope()
    env.channel = .find
    env.payload = Data(count: Frame.maxBytes) // envelope larger than the limit
    #expect(throws: ProtocolError.self) { try Frame.encode(env) }
}

@Test func decoderHandlesSplitAndCoalescedFrames() throws {
    let file: FramingFile = load("framing.json")
    let a = file.vectors[0], b = file.vectors[2]
    let wire = data(hex: a.frameHex) + data(hex: b.frameHex)
    let expected = [envelope(a.envelope), envelope(b.envelope)]

    var split = FrameDecoder()
    var got: [AMEnvelope] = []
    for byte in wire {
        split.append(Data([byte]))
        while let e = try split.next() { got.append(e) }
    }
    #expect(got == expected)

    var joined = FrameDecoder()
    joined.append(wire)
    var got2: [AMEnvelope] = []
    while let e = try joined.next() { got2.append(e) }
    #expect(got2 == expected)
}

@Test func decoderRejectsGarbageEnvelope() {
    var dec = FrameDecoder()
    // length 2, body 0xFF 0xFF is not a valid protobuf message
    dec.append(Data([0, 0, 0, 2, 0xFF, 0xFF]))
    #expect(throws: ProtocolError.malformed) { try dec.next() }
}

@Test func messageTypeRawValues() {
    #expect(MessageType.hello.rawValue == "system.hello")
    #expect(MessageType.findState.rawValue == "find.state")
    #expect(MessageType.allCases.count == 13)
}

@Test func envelopeInitSerializesPayload() throws {
    let ring = AMRingRequest()
    let env = try AMEnvelope(channel: .find, id: 6, type: .findRing, payload: ring)
    #expect(env.type == "find.ring")
    #expect(env.channel == .find)
    #expect(env.payload.isEmpty)
}

// MARK: - Crypto

@Test func cryptoVectors() {
    let file: CryptoFile = load("crypto.json")
    #expect(Set(file.fingerprints.map(\.name)) == ["mac", "phone", "stranger"])
    for f in file.fingerprints {
        #expect(PairingCrypto.fingerprint(certificateDER: data(hex: f.certDerHex)).hex == f.fpHex, "fp \(f.name)")
    }
    for p in file.proofs {
        let got = PairingCrypto.secretProof(
            secret: data(hex: p.secretHex),
            macFingerprint: data(hex: p.macFpHex),
            phoneFingerprint: data(hex: p.phoneFpHex))
        #expect(got.hex == p.proofHex)
    }
    #expect(file.codes.contains { $0.code.hasPrefix("0") })
    for c in file.codes {
        #expect(PairingCrypto.confirmationCode(
            macFingerprint: data(hex: c.macFpHex), phoneFingerprint: data(hex: c.phoneFpHex)) == c.code)
    }
    for r in file.rotatingIds {
        let key = data(hex: r.keyHex)
        #expect(PairingCrypto.rotatingID(discoveryKey: key, unixSeconds: r.unixSeconds) == r.rid)
        #expect(r.epoch == r.unixSeconds / 900)
        #expect(PairingCrypto.matchesRotatingID(r.rid, discoveryKey: key, unixSeconds: r.unixSeconds))
    }
}

@Test func rotatingIDAcceptsAdjacentEpochsOnly() {
    let file: CryptoFile = load("crypto.json")
    let key = data(hex: file.rotatingIds[0].keyHex)
    let now: Int64 = 1_800_000_000
    let rid = PairingCrypto.rotatingID(discoveryKey: key, unixSeconds: now)
    #expect(PairingCrypto.matchesRotatingID(rid, discoveryKey: key, unixSeconds: now))
    #expect(PairingCrypto.matchesRotatingID(rid, discoveryKey: key, unixSeconds: now + 900))
    #expect(PairingCrypto.matchesRotatingID(rid, discoveryKey: key, unixSeconds: now - 900))
    #expect(!PairingCrypto.matchesRotatingID(rid, discoveryKey: key, unixSeconds: now + 1800))
    #expect(!PairingCrypto.matchesRotatingID(rid, discoveryKey: key, unixSeconds: now - 1800))
    #expect(!PairingCrypto.matchesRotatingID("0000000000000000", discoveryKey: key, unixSeconds: now))
}

@Test func randomBytesAreRandom() {
    #expect(PairingCrypto.randomBytes(32).count == 32)
    #expect(PairingCrypto.randomBytes(32) != PairingCrypto.randomBytes(32))
    #expect(PairingCrypto.randomBytes(0).isEmpty)
}

// MARK: - Pairing URI

@Test func pairingURIVectors() throws {
    let file: URIFile = load("pairing_uri.json")
    #expect(!file.valid.isEmpty && !file.invalid.isEmpty)
    for v in file.valid {
        let parsed = try PairingURI.parse(v.uri)
        #expect(parsed.version == v.fields.version)
        #expect(parsed.macFingerprint.hex == v.fields.fpHex)
        #expect(parsed.secret.hex == v.fields.secretHex)
        #expect(parsed.hosts == v.fields.hosts)
        #expect(Int(parsed.port) == v.fields.port)
        #expect(parsed.macName == v.fields.macName)
        // Round trip through our own serialization.
        #expect(try PairingURI.parse(parsed.string) == parsed)
    }
    for v in file.invalid {
        do {
            _ = try PairingURI.parse(v.uri)
            Issue.record("\(v.name): expected \(v.error)")
        } catch {
            switch (error, v.error) {
            case (.malformed, "malformed"): break
            case (.unsupportedVersion, "unsupportedVersion"): break
            default: Issue.record("\(v.name): got \(error), expected \(v.error)")
            }
        }
    }
}

@Test func pairingURIStringMatchesFirstValidVector() throws {
    let file: URIFile = load("pairing_uri.json")
    let first = file.valid[0]
    #expect(try PairingURI.parse(first.uri).string == first.uri)
}
