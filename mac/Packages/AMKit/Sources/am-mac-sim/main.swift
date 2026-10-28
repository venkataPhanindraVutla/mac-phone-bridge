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
//   EVENT status battery=<n> charging=<true|false> signal=<n> network=<kind>
//   EVENT ring-state ringing=<true|false> silent=<true|false>
//   EVENT notify-posted key=<key> title=<title> text=<text> alert=<true|false>
//   EVENT rejected <reason>
//   EVENT disconnected <phone-id>
//   EVENT unpaired <phone-id>
// stdin commands (optional): confirm, decline, pair, ring, stop, forget <phone-id>, quit.

import AMProtocol
import ConnectionCore
import Foundation
import SwiftProtobuf

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage: am-mac-sim --identity <p12> --state-dir <dir> [--port <n|0>] [--password <pw>]
                      [--name <mac name>] [--auto-confirm] [--ring-after-connect] [--echo-notify] [--no-bonjour]
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

let server = MacServer(
    identity: identityProvider,
    phones: FilePairedPhoneStore(directory: stateDir),
    secrets: FileSecretStore(directory: stateDir),
    macName: options.name,
    appVersion: "0.1.0-sim",
    capabilities: options.echoNotify ? ["status.v1", "find.v1", "notify.v1"] : ["status.v1", "find.v1"],
    advertise: options.bonjour
)

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
        if options.ringAfterConnect, shared.contains("find.v1") {
            Task { try? await server.send(.findRing, AMRingRequest(), channel: .find) }
        }
    case let .disconnected(phone):
        emit("EVENT disconnected \(phone.id)")
    case let .unpaired(phone):
        emit("EVENT unpaired \(phone.id)")
    case let .rejected(reason):
        emit("EVENT rejected \(reason.rawValue)")
    }
}

server.onMessage = { envelope in
    switch envelope.type {
    case MessageType.statusUpdate.rawValue:
        guard let s = try? AMStatusUpdate(serializedBytes: envelope.payload) else { return }
        emit("EVENT status battery=\(s.batteryPercent) charging=\(s.charging) "
            + "signal=\(s.signalLevel) network=\(networkName(s.network))")
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
