// am-mac-sim: a command-line Mac for interop tests. It runs the real MacServer with a
// PKCS#12 identity and file-backed stores, and prints one machine-readable line per event.
//
// Output lines (stdout, flushed per line):
//   ID <mac-id>
//   URI <pairing-uri>
//   PORT <n>
//   EVENT code <6 digits>
//   EVENT paired <phone-id>
//   EVENT connected <phone-id> shared=<a,b>
//   EVENT status battery=<n> charging=<true|false> signal=<n> network=<kind> restricted=<true|false>
//   EVENT ring-state ringing=<true|false> silent=<true|false>
//   EVENT notify-posted key=<key> title=<title> text=<text> alert=<true|false>
//   EVENT files-received bytes=<n> sha256=<hex> mbps=<x>   (--files: a file from the phone, phone to Mac rate)
//   EVENT files-sent bytes=<n> mbps=<x>                     (--files: that file sent back, Mac to phone rate)
//   EVENT files-failed <transfer-id> <reason>               (--files)
//   EVENT media-roundtrip ms=<n>                            (--media-toggle: a TOGGLE to the next media.state)
//   EVENT mirror-frames decoded=<n> size=<w>x<h>            (--mirror; parsed=<n> when nothing could be decoded)
//   EVENT mirror-ended <reason>                             (--mirror: the session ended first; exit 1)
//   EVENT rejected <reason>
//   EVENT disconnected <phone-id>
//   EVENT unpaired <phone-id>
// stdin commands (optional): confirm, decline, pair, ring, stop, forget <phone-id>, quit.
// With --files <dir> it also runs the bulk listener and the transfer engine: files from the phone
// are saved into <dir>, and each one received is sent straight back.
// With --media-toggle it advertises media.v1 and runs the media model with no Now Playing: on the
// first active media.state it sends TOGGLE, prints the round trip, then sends a second TOGGLE.
// With --liveness it advertises liveness.v1 (SPEC 7): when the phone lists it too, the Mac pings
// every 30 s (or --ping-interval-ms) and drops the phone at the third consecutive silent interval.
// --silence-ms <n> replaces the 75 s silence rule for phones without liveness.v1 (sim speed).
// With --mirror it advertises mirror.v1 and runs the mirror model (VideoToolbox decode, headless,
// into a counting sink): on the phone's first enabled mirror.availability it starts a session
// (High, H.264, audio off); after the first frame it sends one touch DOWN and UP at the centre;
// after 60 decoded frames, or 2 s without a frame, it prints mirror-frames, stops and exits 0.

import AMProtocol
import ConnectionCore
import CoreVideo
import CryptoKit
import FeatureFiles
import FeatureMedia
import FeatureMirror
import Foundation
import SwiftProtobuf

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage: am-mac-sim --identity <p12> --state-dir <dir> [--port <n|0>] [--password <pw>]
                      [--name <mac name>] [--auto-confirm] [--ring-after-connect] [--echo-notify] [--no-bonjour]
                      [--files <dir>] [--media-toggle] [--liveness] [--ping-interval-ms <n>] [--silence-ms <n>]
                      [--mirror]
    """

struct Options {
    var identity: String?
    var password = "test"
    var port: UInt16 = 0
    var stateDir: String?
    var name = "am-mac-sim"
    var autoConfirm = false
    var ringAfterConnect = false
    var echoNotify = false
    var bonjour = true
    var filesDir: String?
    var mediaToggle = false
    var liveness = false
    var pingIntervalMs: Int?
    var silenceMs: Int?
    var mirror = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("am-mac-sim: \(message)\n\(usage)\n".utf8))
    exit(2)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var it = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--identity": o.identity = value(arg)
        case "--password": o.password = value(arg)
        case "--port":
            guard let p = UInt16(value(arg)) else { fail("--port must be 0...65535") }
            o.port = p
        case "--state-dir": o.stateDir = value(arg)
        case "--name": o.name = value(arg)
        case "--auto-confirm": o.autoConfirm = true
        case "--ring-after-connect": o.ringAfterConnect = true
        case "--echo-notify": o.echoNotify = true
        case "--no-bonjour": o.bonjour = false
        case "--files": o.filesDir = value(arg)
        case "--media-toggle": o.mediaToggle = true
        case "--liveness": o.liveness = true
        case "--mirror": o.mirror = true
        case "--ping-interval-ms":
            guard let ms = Int(value(arg)), ms > 0 else { fail("--ping-interval-ms must be a positive integer") }
            o.pingIntervalMs = ms
        case "--silence-ms":
            guard let ms = Int(value(arg)), ms > 0 else { fail("--silence-ms must be a positive integer") }
            o.silenceMs = ms
        case "-h", "--help":
            print(usage)
            exit(0)
        default: fail("unknown argument \(arg)")
        }
    }
    if o.identity == nil { fail("--identity is required") }
    if o.stateDir == nil { fail("--state-dir is required") }
    return o
}

// MARK: file-backed stores (test tool only)

final class FilePairedPhoneStore: PairedPhoneStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(directory: URL) { url = directory.appendingPathComponent("paired-phones.json") }

    func all() throws -> [PairedPhone] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    func save(_ phone: PairedPhone) throws {
        lock.lock(); defer { lock.unlock() }
        var phones = try load()
        if let i = phones.firstIndex(where: { $0.id == phone.id }) { phones[i] = phone } else { phones.append(phone) }
        try store(phones)
    }

    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try store(try load().filter { $0.id != id })
    }

    private func load() throws -> [PairedPhone] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PairedPhone].self, from: Data(contentsOf: url))
    }

    private func store(_ phones: [PairedPhone]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(phones).write(to: url, options: .atomic)
    }
}

final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(directory: URL) { url = directory.appendingPathComponent("discovery-key.hex") }

    func discoveryKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let key = Data(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 {
            return key
        }
        let key = PairingCrypto.randomBytes(32)
        try (key.lowercaseHex + "\n").write(to: url, atomically: true, encoding: .utf8)
        return key
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

// MARK: output

func emit(_ line: String) {
    print(line)
}

func networkName(_ kind: AMNetworkKind) -> String {
    switch kind {
    case .wifi: "wifi"
    case .cellular: "cellular"
    case .none: "none"
    case .other: "other"
    case .unspecified: "unspecified"
    case let .UNRECOGNIZED(n): "unknown-\(n)"
    }
}

// MARK: main

let options = parse(Array(CommandLine.arguments.dropFirst()))
let stateDir = URL(fileURLWithPath: options.stateDir!, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
} catch {
    fail("cannot create state dir: \(error)")
}

let identityProvider = P12IdentityProvider(url: URL(fileURLWithPath: options.identity!), password: options.password)
let macIdentity: TLSIdentity
do {
    macIdentity = try identityProvider.identity()
} catch {
    fail("cannot load identity: \(error)")
}

var capabilities: Set<String> = ["status.v1", "find.v1"]
if options.echoNotify { capabilities.insert("notify.v1") }
if options.filesDir != nil { capabilities.insert("files.v1") }
if options.mediaToggle { capabilities.insert("media.v1") }
if options.liveness { capabilities.insert(Liveness.capability) }
if options.mirror { capabilities.insert("mirror.v1") }

let server = MacServer(
    identity: identityProvider,
    phones: FilePairedPhoneStore(directory: stateDir),
    secrets: FileSecretStore(directory: stateDir),
    macName: options.name,
    appVersion: "0.1.0-sim",
    capabilities: capabilities,
    advertise: options.bonjour,
    silenceTimeout: options.silenceMs.map { .milliseconds($0) } ?? .seconds(75),
    pingInterval: options.pingIntervalMs.map { .milliseconds($0) } ?? Liveness.defaultInterval
)

// MARK: files (--files)

/// Feature work, one item at a time in arrival order, as the app's queue does it.
let featureWork: AsyncStream<@MainActor @Sendable () async -> Void>.Continuation = {
    let (stream, continuation) = AsyncStream.makeStream(of: (@MainActor @Sendable () async -> Void).self)
    Task { @MainActor in
        for await work in stream { await work() }
    }
    return continuation
}()

func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize()).lowercaseHex
}

func megabytesPerSecond(_ bytes: UInt64, since start: ContinuousClock.Instant?) -> String {
    guard let start else { return "0.0" }
    let d = ContinuousClock.now - start
    let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.1f", seconds > 0 ? Double(bytes) / 1e6 / seconds : 0)
}

/// Transfer ID to when it started (offer seen, or send queued), for the rates printed.
var transferStarts: [String: ContinuousClock.Instant] = [:]

/// The bulk listener, for --files and --mirror.
let bulk: BulkServer? = options.filesDir != nil || options.mirror
    ? MainActor.assumeIsolated { BulkServer(identity: identityProvider) } : nil

let transfers: TransferEngine? = options.filesDir.map { path in
    let dir = URL(fileURLWithPath: path, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        fail("cannot create files dir: \(error)")
    }
    guard let bulk else { fail("no bulk listener") }
    let engine = TransferEngine(
        bulk: bulk,
        send: { type, message in try? await server.send(type, message, channel: .files) },
        destination: { _ in .folder(dir) })
    engine.onFinished = { item, _, url in
        let start = transferStarts.removeValue(forKey: item.id)
        switch (item.direction, item.state) {
        case (.receive, .done):
            guard let url, let hash = sha256Hex(of: url) else { return }
            emit("EVENT files-received bytes=\(item.size) sha256=\(hash) mbps=\(megabytesPerSecond(item.size, since: start))")
            for id in engine.send(files: [url]) { transferStarts[id] = .now }
        case (.send, .done):
            emit("EVENT files-sent bytes=\(item.size) mbps=\(megabytesPerSecond(item.size, since: start))")
        case let (_, .failed(reason)):
            emit("EVENT files-failed \(item.id) \(reason)")
        default:
            break
        }
    }
    return engine
}

// MARK: media (--media-toggle)

/// Now Playing for a command-line tool: nothing to show, no remote commands.
@MainActor
final class NoNowPlaying: NowPlayingCenter {
    var onCommand: ((AMMediaCommandKind, Double?) -> Void)?
    func show(_ info: NowPlayingInfo, playing: Bool, commands: RemoteCommands) {}
    func clear() {}
}

/// Drives the toggle round trips: the first TOGGLE on the first active state, the second once
/// the first is answered.
@MainActor
final class MediaToggle {
    let model: MediaModel
    private var started = false
    private var answered = 0

    init() {
        model = MediaModel(
            center: NoNowPlaying(),
            send: { type, message in try? await server.send(type, message, channel: .media) })
        model.onRoundTrip = { [unowned self] _, rtt in
            let ms = rtt.components.seconds * 1000 + rtt.components.attoseconds / 1_000_000_000_000_000
            emit("EVENT media-roundtrip ms=\(ms)")
            answered += 1
            if answered == 1 { Task { await self.model.command(.toggle) } }
        }
    }

    func message(_ envelope: AMEnvelope) async {
        await model.message(envelope)
        guard !started, model.state?.active == true else { return }
        started = true
        // Off the work stream, like the second: the send must not hold up the next message.
        Task { await self.model.command(.toggle) }
    }
}

let media: MediaToggle? = options.mediaToggle ? MainActor.assumeIsolated { MediaToggle() } : nil

// MARK: mirror (--mirror)

/// Counts the pictures VideoToolbox decodes; nothing is shown.
final class CountingFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0

    func show(_ image: CVPixelBuffer) { lock.withLock { shown += 1 } }
    func flush() {}
    var count: Int { lock.withLock { shown } }
}

/// One mirror session against the phone: started on the first enabled availability, touched once
/// at the centre after the first frame, stopped after 60 frames or 2 s without one.
@MainActor
final class MirrorRun {
    static let frames = 60
    static let idle: Duration = .seconds(2)

    let model: MirrorModel
    private let sink: CountingFrameSink
    private var started = false

    init(bulk: BulkServer) {
        let sink = CountingFrameSink()
        self.sink = sink
        model = MirrorModel(
            bulk: bulk,
            send: { type, message in try? await server.send(type, message, channel: .mirror) },
            makeSink: { sink })
        model.audioEnabled = false
        model.codec = .h264
    }

    func message(_ envelope: AMEnvelope) async {
        await model.message(envelope)
        guard !started, model.canStart else { return }
        started = true
        await model.start()
        Task { await self.watch() }
    }

    private func watch() async {
        var received = 0
        var lastFrame = ContinuousClock.now
        var firstReceived: ContinuousClock.Instant?
        var touched = false
        while true {
            try? await Task.sleep(for: .milliseconds(10))
            if case let .ended(reason) = model.phase {
                emit("EVENT mirror-ended \(reason)")
                exit(1)
            }
            guard let session = model.session else { continue }
            let now = ContinuousClock.now
            if session.videoFramesReceived != received {
                received = session.videoFramesReceived
                lastFrame = now
                if firstReceived == nil { firstReceived = now }
            }
            let decoded = sink.count
            // After the first frame (or, when nothing decodes, a second after the first one came).
            if !touched, let size = session.videoSize,
               decoded > 0 || firstReceived.map({ now - $0 >= .seconds(1) }) == true {
                touched = true
                let (x, y) = (Int32(size.width / 2), Int32(size.height / 2))
                let (w, h) = (UInt16(clamping: size.width), UInt16(clamping: size.height))
                session.sendControl(ScrcpyControl.touch(action: 0, x: x, y: y, width: w, height: h, pressure: 1))
                session.sendControl(ScrcpyControl.touch(action: 1, x: x, y: y, width: w, height: h, pressure: 0))
            }
            guard decoded >= Self.frames || (received > 0 && now - lastFrame >= Self.idle) else { continue }
            let size = session.videoSize ?? (0, 0)
            let count = decoded > 0 ? "decoded=\(decoded)" : "parsed=\(received)"
            emit("EVENT mirror-frames \(count) size=\(size.width)x\(size.height)")
            await model.stop()
            // The control link drains (at most 200 ms) before the process goes.
            try? await Task.sleep(for: .milliseconds(300))
            exit(0)
        }
    }
}

let mirrorRun: MirrorRun? = options.mirror ? MainActor.assumeIsolated { bulk.map { MirrorRun(bulk: $0) } } : nil

if let bulk {
    MainActor.assumeIsolated {
        bulk.onLink = { pipe, grant in
            switch grant.role {
            case .mirrorVideo, .mirrorAudio, .mirrorControl:
                if let mirrorRun { mirrorRun.model.link(pipe, grant: grant) } else { pipe.close() }
            default:
                if let transfers { transfers.link(pipe, grant: grant) } else { pipe.close() }
            }
        }
        do {
            try bulk.start()
        } catch {
            fail("cannot start the bulk listener: \(error)")
        }
    }
}

var announced = false
server.onEvent = { event in
    switch event {
    case let .listening(port):
        guard !announced else { return }
        announced = true
        let uri = server.beginPairing()
        emit("URI \(uri.string)")
        emit("PORT \(port)")
    case let .listenerFailed(message):
        FileHandle.standardError.write(Data("am-mac-sim: listener failed: \(message)\n".utf8))
        exit(1)
    case let .pairingCode(code):
        emit("EVENT code \(code)")
        if options.autoConfirm { server.confirmPairing(true) }
    case let .paired(phone):
        emit("EVENT paired \(phone.id)")
    case let .connected(phone, shared):
        emit("EVENT connected \(phone.id) shared=\(shared.sorted().joined(separator: ","))")
        if let transfers {
            featureWork.yield { await transfers.connected(phoneID: phone.id, phoneName: phone.name, shared: shared) }
        }
        if let media {
            featureWork.yield { await media.model.connected(phoneID: phone.id, phoneName: phone.name, shared: shared) }
        }
        if let mirrorRun, let bulk {
            featureWork.yield {
                bulk.allow(peerFingerprint: Data(hex: phone.id))
                await mirrorRun.model.connected(phoneID: phone.id, phoneName: phone.name, shared: shared)
            }
        }
        if options.ringAfterConnect, shared.contains("find.v1") {
            Task { try? await server.send(.findRing, AMRingRequest(), channel: .find) }
        }
    case let .disconnected(phone):
        emit("EVENT disconnected \(phone.id)")
        if let transfers { featureWork.yield { transfers.disconnected() } }
        if let media { featureWork.yield { media.model.disconnected() } }
        if let mirrorRun { featureWork.yield { mirrorRun.model.disconnected() } }
    case let .unpaired(phone):
        emit("EVENT unpaired \(phone.id)")
    case let .rejected(reason):
        emit("EVENT rejected \(reason.rawValue)")
    }
}

server.onMessage = { envelope in
    if let transfers, transfers.messagePrefixes.contains(where: { envelope.type.hasPrefix($0) }) {
        if envelope.type == MessageType.filesOffer.rawValue,
           let offer = try? AMTransferOffer(serializedBytes: envelope.payload) {
            transferStarts[offer.transferID] = .now
        }
        featureWork.yield { await transfers.message(envelope) }
        return
    }
    if let media, media.model.messagePrefixes.contains(where: { envelope.type.hasPrefix($0) }) {
        featureWork.yield { await media.message(envelope) }
        return
    }
    if let mirrorRun, mirrorRun.model.messagePrefixes.contains(where: { envelope.type.hasPrefix($0) }) {
        featureWork.yield { await mirrorRun.message(envelope) }
        return
    }
    switch envelope.type {
    case MessageType.statusUpdate.rawValue:
        guard let s = try? AMStatusUpdate(serializedBytes: envelope.payload) else { return }
        emit("EVENT status battery=\(s.batteryPercent) charging=\(s.charging) "
            + "signal=\(s.signalLevel) network=\(networkName(s.network)) restricted=\(s.backgroundRestricted)")
    case MessageType.findState.rawValue:
        guard let r = try? AMRingState(serializedBytes: envelope.payload) else { return }
        emit("EVENT ring-state ringing=\(r.ringing) silent=\(r.mayBeSilent)")
    case MessageType.notifyPosted.rawValue:
        guard let n = try? AMPhoneNotification(serializedBytes: envelope.payload) else { return }
        emit("EVENT notify-posted key=\(n.key) title=\(n.title) text=\(n.text) alert=\(n.alert)")
        if options.echoNotify {
            var invoke = AMInvokeAction()
            invoke.key = n.key
            invoke.actionIndex = 0
            invoke.replyText = "hi"
            Task { try? await server.send(.notifyInvoke, invoke, channel: .notify) }
        }
    default:
        break
    }
}

@MainActor
func command(_ line: String) {
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first {
    case "confirm": server.confirmPairing(true)
    case "decline": server.confirmPairing(false)
    case "pair":
        let uri = server.beginPairing()
        emit("URI \(uri.string)")
    case "ring": Task { try? await server.send(.findRing, AMRingRequest(), channel: .find) }
    case "stop": Task { try? await server.send(.findStop, AMStopRingRequest(), channel: .find) }
    case "forget" where parts.count == 2: Task { await server.forget(phoneID: parts[1]) }
    case "quit": exit(0)
    default: break
    }
}

emit("ID \(macIdentity.deviceID)")
do {
    try server.start(port: options.port)
} catch {
    fail("cannot start: \(error)")
}

// Optional commands on stdin; EOF (e.g. </dev/null) just stops reading.
Thread.detachNewThread {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in command(trimmed) }
    }
}

dispatchMain()
