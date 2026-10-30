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
    struct BLE: Decodable {
        let keyHex: String, phoneFpHex: String, unixSeconds: Int64, epoch: Int64, bleIdHex: String
        enum CodingKeys: String, CodingKey {
            case keyHex = "key_hex", phoneFpHex = "phone_fp_hex", unixSeconds = "unix_seconds"
            case epoch, bleIdHex = "ble_id_hex"
        }
    }
    struct Artwork: Decodable {
        let jpegHex: String, key: String
        enum CodingKeys: String, CodingKey { case jpegHex = "jpeg_hex", key }
    }
    let fingerprints: [FP]
    let proofs: [Proof]
    let codes: [Code]
    let rotatingIds: [RID]
    let bleIds: [BLE]
    let artworkKeys: [Artwork]
    enum CodingKeys: String, CodingKey {
        case fingerprints, proofs, codes
        case rotatingIds = "rotating_ids"
        case bleIds = "ble_ids"
        case artworkKeys = "artwork_keys"
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

@Test func notifyPostedVectorDecodesToPhoneNotification() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "notify_posted_minimal" })
    let env = envelope(v.envelope)
    #expect(env.channel == .notify)
    #expect(env.type == MessageType.notifyPosted.rawValue)
    let n = try AMPhoneNotification(serializedBytes: env.payload)
    #expect(n.key == "0|com.whatsapp|1|null|10123")
    #expect(n.package == "com.whatsapp")
    #expect(n.title == "Ana")
    #expect(n.text == "hi \u{1F44B}")
    #expect(n.alert)
    #expect(n.actions.isEmpty)
    #expect(try n.serializedData() == env.payload)
}

@Test func filesOfferVectorDecodesToTransferOffer() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "files_offer_minimal" })
    let env = envelope(v.envelope)
    #expect(env.channel == .files)
    #expect(env.type == MessageType.filesOffer.rawValue)
    let o = try AMTransferOffer(serializedBytes: env.payload)
    #expect(o.transferID == "t1")
    #expect(o.name == "photo.jpg")
    #expect(o.size == 5_000_000_000)
    #expect(o.mime == "image/jpeg")
    #expect(o.kind == .file)
    #expect(o.token.isEmpty)
    #expect(try o.serializedData() == env.payload)
}

@Test func bulkHelloVectorDecodesToBulkHello() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "bulk_hello" })
    let env = envelope(v.envelope)
    #expect(env.channel == .files)
    #expect(env.id == 1)
    #expect(env.type == MessageType.bulkHello.rawValue)
    let h = try AMBulkHello(serializedBytes: env.payload)
    #expect(h.token.count == 32)
    #expect(h.role == .phoneSends)
    #expect(try h.serializedData() == env.payload)
}

@Test func mediaStateVectorDecodesToMediaState() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "media_state_minimal" })
    let env = envelope(v.envelope)
    #expect(env.channel == .media)
    #expect(env.id == 1)
    #expect(env.type == MessageType.mediaState.rawValue)
    let m = try AMMediaState(serializedBytes: env.payload)
    #expect(m.active)
    #expect(m.sessionKey == "s1")
    #expect(m.title == "Song")
    #expect(m.durationMs == 5_000_000_000)
    #expect(m.playing)
    #expect(m.speed == 1.0)
    #expect(m.canPause)
    #expect(!m.canPlay)
    #expect(!m.hasVolume)
    #expect(m.artworkKey.isEmpty)
    #expect(try m.serializedData() == env.payload)
}

@Test func pingFromMacVectorDecodes() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "ping_from_mac" })
    let env = envelope(v.envelope)
    #expect(env.channel == .system)
    #expect(env.id == 4)
    #expect(env.replyTo == 0)
    #expect(env.type == MessageType.ping.rawValue)
    #expect(env.payload.isEmpty)
}

@Test func statusBackgroundRestrictedVectorDecodes() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "status_update_background_restricted" })
    let env = envelope(v.envelope)
    #expect(env.channel == .status)
    #expect(env.id == 6)
    #expect(env.type == MessageType.statusUpdate.rawValue)
    let s = try AMStatusUpdate(serializedBytes: env.payload)
    #expect(s.backgroundRestricted)
    #expect(s.batteryPercent == 40)
    #expect(s.signalLevel == 2)
    #expect(s.network == .wifi)
    #expect(try s.serializedData() == env.payload)
}

@Test func inputMoveVectorDecodesFloats() throws {
    let file: FramingFile = load("framing.json")
    let v = try #require(file.vectors.first { $0.name == "input_move" })
    let env = envelope(v.envelope)
    #expect(env.channel == .input)
    #expect(env.id == 7)
    #expect(env.type == MessageType.inputMove.rawValue)
    let m = try AMInputMove(serializedBytes: env.payload)
    #expect(m.dx == 1.5)
    #expect(m.dy == -2.25)
    #expect(try m.serializedData() == env.payload)
}

private struct FilenamesFile: Decodable {
    struct Sanitize: Decodable { let `in`: String; let out: String }
    struct Unique: Decodable { let name: String; let taken: [String]; let out: String }
    let sanitize: [Sanitize]
    let unique: [Unique]
}

@Test func filenameVectorsLoadAndHoldInvariants() throws {
    let file: FilenamesFile = load("filenames.json")
    let byIn = Dictionary(uniqueKeysWithValues: file.sanitize.map { ($0.in, $0.out) })
    #expect(byIn["../../etc/passwd"] == "passwd")
    #expect(byIn[""] == "file")
    #expect(byIn["tab\tname\u{7}.txt"] == "tabname.txt")
    #expect(byIn["\u{202E}gnp.exe"] == "gnp.exe")
    #expect(byIn[String(repeating: "a", count: 296) + ".jpg"] == String(repeating: "a", count: 251) + ".jpg")
    #expect(byIn[String(repeating: "é", count: 150) + ".pdf"] == String(repeating: "é", count: 125) + ".pdf")
    for c in file.sanitize {
        #expect(!c.out.isEmpty && c.out.utf8.count <= 255, "\(c.in)")
        #expect(!c.out.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "\(c.in)")
        #expect(!c.out.contains("/") && !c.out.contains("\\"), "\(c.in)")
    }
    let photo = try #require(file.unique.first { $0.taken == ["photo.jpg", "photo (1).jpg"] })
    #expect(photo.out == "photo (2).jpg")
    #expect(file.unique.contains { $0.name.utf8.count == 255 && $0.out.utf8.count <= 255 && $0.out != $0.name })
    func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
    for u in file.unique { #expect(!u.taken.map(key).contains(key(u.out)), "\(u.name)") }
    let byName = Dictionary(grouping: file.unique, by: \.name)
    #expect(byName["Photo.JPG"]?.first?.out == "Photo (1).JPG")
    #expect(byName["É.pdf"]?.first?.out == "É (1).pdf")
    #expect(byName["e\u{301}.txt"]?.first?.out == "e\u{301} (1).txt")
    #expect(file.unique.contains { $0.name == "Photo.jpg" && $0.out == "Photo (2).jpg" })
    #expect(file.sanitize.contains { $0.in == String(repeating: "a", count: 254) + " x" && !$0.out.hasSuffix(" ") })
}

@Test func messageTypeRawValues() {
    #expect(MessageType.hello.rawValue == "system.hello")
    #expect(MessageType.findState.rawValue == "find.state")
    #expect(MessageType.allCases.count == 76)
    let expected: [MessageType: String] = [
        .notifyPosted: "notify.posted", .notifyRemoved: "notify.removed",
        .notifySnapshot: "notify.snapshot", .notifyDismiss: "notify.dismiss",
        .notifyInvoke: "notify.invoke", .notifyResult: "notify.result",
        .notifyFilter: "notify.filter", .notifyIconRequest: "notify.icon_request",
        .notifyIcon: "notify.icon", .notifyAvailability: "notify.availability",
        .contactsSync: "contacts.sync", .contactsBatch: "contacts.batch",
        .contactsAvailability: "contacts.availability",
        .callsState: "calls.state", .callsCommand: "calls.command",
        .callsResult: "calls.result", .callsMissed: "calls.missed",
        .callsAvailability: "calls.availability",
        .clipboardText: "clipboard.text",
        .clipboardAvailability: "clipboard.availability",
        .shareLink: "share.link",
        .shareText: "share.text",
        .filesEndpoint: "files.endpoint",
        .filesOffer: "files.offer",
        .filesAccept: "files.accept",
        .filesReject: "files.reject",
        .filesProgress: "files.progress",
        .filesComplete: "files.complete",
        .filesReceived: "files.received",
        .filesCancel: "files.cancel",
        .filesFailed: "files.failed",
        .bulkHello: "bulk.hello",
        .screenshotsAvailability: "screenshots.availability",
        .photosList: "photos.list",
        .photosItems: "photos.items",
        .photosThumbs: "photos.thumbs",
        .photosFetch: "photos.fetch",
        .photosAvailability: "photos.availability",
        .browseRootsRequest: "browse.roots_request",
        .browseRoots: "browse.roots",
        .browseList: "browse.list",
        .browseListing: "browse.listing",
        .browseStat: "browse.stat",
        .browseMkdir: "browse.mkdir",
        .browseDelete: "browse.delete",
        .browseRead: "browse.read",
        .browseRename: "browse.rename",
        .browseResult: "browse.result",
        .browseAvailability: "browse.availability",
        .mediaState: "media.state", .mediaArtwork: "media.artwork",
        .mediaCommand: "media.command", .mediaAvailability: "media.availability",
        .dndState: "dnd.state", .dndAvailability: "dnd.availability",
        .proximityAvailability: "proximity.availability",
        .inputMove: "input.move", .inputButton: "input.button", .inputClick: "input.click",
        .inputScroll: "input.scroll", .inputKey: "input.key", .inputLaser: "input.laser",
        .inputAvailability: "input.availability",
    ]
    for (type, raw) in expected { #expect(type.rawValue == raw) }
    #expect(AMChannel.notify.rawValue == 5)
    #expect(AMChannel.contacts.rawValue == 6)
    #expect(AMChannel.calls.rawValue == 7)
    #expect(AMChannel.clipboard.rawValue == 8)
    #expect(AMChannel.share.rawValue == 9)
    #expect(AMChannel.files.rawValue == 10)
    #expect(AMChannel.screenshots.rawValue == 11)
    #expect(AMChannel.photos.rawValue == 12)
    #expect(AMChannel.browse.rawValue == 13)
    #expect(AMChannel.media.rawValue == 14)
    #expect(AMChannel.dnd.rawValue == 15)
    #expect(AMChannel.proximity.rawValue == 16)
    #expect(AMChannel.input.rawValue == 17)
    #expect(AMAvailabilityReason.partialAccess.rawValue == 3)
    #expect(AMAvailabilityReason.unavailable.rawValue == 4)
    #expect(AMAvailabilityReason.needsSetup.rawValue == 5)
    #expect(Set(MessageType.allCases.map(\.rawValue)).count == MessageType.allCases.count)
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

@Test func bleIdVectors() {
    let file: CryptoFile = load("crypto.json")
    #expect(PairingCrypto.bleServiceUUID == "3d30288c-0f47-4016-a6ba-44506f920431")
    #expect(file.bleIds.count == 12)
    #expect(Set(file.bleIds.map(\.epoch)).count == 4)
    for b in file.bleIds {
        #expect(PairingCrypto.epoch(unixSeconds: b.unixSeconds) == b.epoch)
        let id = PairingCrypto.bleID(
            discoveryKey: data(hex: b.keyHex), phoneFingerprint: data(hex: b.phoneFpHex), epoch: b.epoch)
        #expect(id.count == 8)
        #expect(id.hex == b.bleIdHex, "unix \(b.unixSeconds)")
    }
    #expect(PairingCrypto.epoch(unixSeconds: 899) == 0)
    #expect(PairingCrypto.epoch(unixSeconds: 900) == 1)
    #expect(PairingCrypto.epoch(unixSeconds: -1) == -1)
}

@Test func bleIdDiffersPerPhone() {
    let file: CryptoFile = load("crypto.json")
    let phones = Array(Set(file.bleIds.map(\.phoneFpHex))).sorted()
    #expect(phones.count == 2)
    let key = data(hex: file.bleIds[0].keyHex)
    let a = PairingCrypto.bleID(discoveryKey: key, phoneFingerprint: data(hex: phones[0]), epoch: 5)
    let b = PairingCrypto.bleID(discoveryKey: key, phoneFingerprint: data(hex: phones[1]), epoch: 5)
    #expect(a != b)
    #expect(a != PairingCrypto.bleID(discoveryKey: key, phoneFingerprint: data(hex: phones[0]), epoch: 6))
}

@Test func artworkKeyVectors() {
    let file: CryptoFile = load("crypto.json")
    #expect(file.artworkKeys.count == 6)
    #expect(Set(file.artworkKeys.map(\.jpegHex.count)).isSuperset(of: [110, 112, 128, 130]))
    for a in file.artworkKeys {
        #expect(ArtworkKey.of(data(hex: a.jpegHex)) == a.key)
    }
    #expect(ArtworkKey.of(Data()) == "")
    #expect(ArtworkKey.of(Data("jpeg".utf8)).count == 16)
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
