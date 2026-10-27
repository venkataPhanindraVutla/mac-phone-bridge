import AMProtocol
import Foundation
import Network
import Observation
import SwiftProtobuf

public enum MacConnectionState: Equatable, Sendable {
    case idle
    /// A pairing window is open. `code` is set once a phone proved the secret.
    case pairing(uri: PairingURI, code: String?)
    case connected(PairedPhone, shared: Set<String>)
    case incompatible(phoneName: String)
}

/// Why the server turned a phone (or a pairing attempt) away. Raw values are the
/// `EVENT rejected <reason>` strings of `am-mac-sim`.
public enum MacRejection: String, Sendable {
    /// Unknown certificate outside a pairing window, or an unknown certificate whose first
    /// message was not `pairing.request` (`NOT_PAIRED`).
    case notPairedCertificate = "not-paired-certificate"
    case busy
    case protocolMismatch = "protocol-mismatch"
    case badPairingSecret = "bad-pairing-secret"
    case pairingExpired = "pairing-expired"
    case pairingRejected = "pairing-rejected"
    case pairingCancelled = "pairing-cancelled"
    case pairingTimedOut = "pairing-timed-out"
}

public enum MacServerEvent: Equatable, Sendable {
    case listening(port: UInt16)
    case listenerFailed(String)
    /// A phone proved the secret; both sides now show `code`.
    case pairingCode(String)
    case paired(PairedPhone)
    case connected(PairedPhone, shared: Set<String>)
    case disconnected(PairedPhone)
    /// The phone was removed: `forget`, or `system.goodbye UNPAIRED` from the phone.
    case unpaired(PairedPhone)
    case rejected(MacRejection)
}

public enum MacServerError: Error, Equatable, Sendable {
    case notConnected
}

/// The Mac's side of the protocol: listens for phones, runs pairing (SPEC 5.3), enforces the
/// rules after pairing (5.4), keep-alive and wake handling (7). Serves one phone at a time.
@MainActor
@Observable
public final class MacServer {
    public private(set) var state: MacConnectionState = .idle
    public private(set) var port: UInt16?
    public private(set) var isListening = false

    /// Messages from the connected phone other than hello/ping/goodbye.
    @ObservationIgnored public var onMessage: ((AMEnvelope) -> Void)?
    @ObservationIgnored public var onEvent: ((MacServerEvent) -> Void)?

    @ObservationIgnored private let identityProvider: any IdentityProvider
    @ObservationIgnored private let phones: any PairedPhoneStore
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let macName: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let capabilities: Set<String>
    @ObservationIgnored private let advertise: Bool
    @ObservationIgnored private let silenceTimeout: Duration
    @ObservationIgnored private let pairingLifetime: TimeInterval
    @ObservationIgnored private let confirmationTimeout: Duration
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var identity: TLSIdentity?
    @ObservationIgnored private let policy = PeerPolicy()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerGeneration = 0
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var advertiser: BonjourAdvertiser?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var active: Session?
    @ObservationIgnored private var window: PairingWindow?
    @ObservationIgnored private var incompatiblePhone: String?

    private static let listenerQueue = DispatchQueue(label: "io.github.anmirror.listener")
    private static let maxRestartAttempts = 40

    /// - Parameters:
    ///   - silenceTimeout: drop a connection after this long with no incoming message (SPEC 7).
    ///   - pairingLifetime: seconds a pairing secret stays valid (SPEC 5.1).
    ///   - confirmationTimeout: how long to wait for both users' decisions (SPEC 5.3 step 4).
    public init(identity: any IdentityProvider, phones: any PairedPhoneStore, secrets: any SecretStore,
                macName: String, appVersion: String, capabilities: Set<String>, advertise: Bool = true,
                silenceTimeout: Duration = .seconds(75), pairingLifetime: TimeInterval = 300,
                confirmationTimeout: Duration = .seconds(60), now: @escaping () -> Date = Date.init) {
        self.identityProvider = identity
        self.phones = phones
        self.secrets = secrets
        self.macName = macName
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.advertise = advertise
        self.silenceTimeout = silenceTimeout
        self.pairingLifetime = pairingLifetime
        self.confirmationTimeout = confirmationTimeout
        self.now = now
    }

    // MARK: lifecycle

    /// Loads the identity and starts listening (`port` nil or 0: any free port). `port` and
    /// `isListening` are set, and `.listening` is emitted, once the listener is ready.
    public func start(port: UInt16? = nil) throws {
        guard listener == nil else { return }
        let identity = try identityProvider.identity()
        self.identity = identity
        if advertise { advertiser = BonjourAdvertiser(discoveryKey: try secrets.discoveryKey()) }
        refreshPolicy()
        restartAttempts = 0
        try startListener(port: port ?? 0)
    }

    /// Closes every connection and the listener.
    public func stop() {
        for s in Array(sessions.values) { drop(s) }
        window = nil
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        advertiser?.stop()
        isListening = false
        refreshPolicy()
        recomputeState()
    }

    /// After wake from sleep: close every connection and listen again on the same port.
    public func handleWake() {
        for s in Array(sessions.values) { drop(s) }
        guard identity != nil, let port else { return }
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        isListening = false
        restartAttempts = 0
        try? startListener(port: port)
        recomputeState()
    }

    // MARK: pairing

    /// Opens a pairing window with a fresh secret and returns the QR content. Call after
    /// `start()` once `port` is known. Replaces any window already open.
    public func beginPairing() -> PairingURI {
        guard let identity else { preconditionFailure("MacServer.start() must succeed before beginPairing()") }
        if let old = window { endWindow(old, rejection: nil) }
        let flow = MacPairingFlow(macFingerprint: identity.fingerprint, now: now(), lifetime: pairingLifetime)
        let uri = PairingURI(macFingerprint: identity.fingerprint, secret: flow.secret,
                             hosts: PairingHosts.current(), port: port ?? 0, macName: macName)
        window = PairingWindow(flow: flow, uri: uri)
        incompatiblePhone = nil
        refreshPolicy()
        recomputeState()
        return uri
    }

    /// The Mac user's decision on the confirmation code. Declining before a phone has been
    /// verified closes the window (cancel).
    public func confirmPairing(_ accepted: Bool) {
        guard let w = window else { return }
        guard let session = w.session, w.code != nil else {
            if !accepted {
                _ = w.flow.localDecision(false, now: now())
                endWindow(w, rejection: nil)
            }
            return
        }
        let outcome = w.flow.localDecision(accepted, now: now())
        if outcome != .timedOut { post(session, .pairConfirm, confirm(accepted), channel: .pairing) }
        apply(outcome, window: w)
    }

    // MARK: phone

    /// Sends to the connected phone.
    public func send(_ type: MessageType, _ message: some SwiftProtobuf.Message & Sendable,
                     channel: AMChannel) async throws {
        guard let a = active, case .active = a.phase else { throw MacServerError.notConnected }
        try await a.conn.send(type, message, channel: channel)
    }

    /// Unpairs: tells the phone (`system.goodbye UNPAIRED`) if it is connected, then removes it.
    public func forget(phoneID: String) async {
        let known = (try? phones.all())?.first { $0.id == phoneID }
        for s in Array(sessions.values) where s.conn.peerFingerprint.lowercaseHex == phoneID {
            if case .active = s.phase {
                var bye = AMGoodbye()
                bye.reason = .unpaired
                _ = try? await s.conn.send(.goodbye, bye, channel: .system)
            }
            drop(s, flush: true)
        }
        try? phones.remove(id: phoneID)
        refreshPolicy()
        if let known { emit(.unpaired(known)) }
        recomputeState()
    }

    // MARK: listener

    private func startListener(port: UInt16) throws {
        guard let identity else { return }
        let policy = self.policy
        let params = TLSParameters.server(identity: identity) { [weak self] fp in
            let ok = policy.accepts(fp)
            if !ok { Task { @MainActor in self?.emit(.rejected(.notPairedCertificate)) } }
            return ok
        }
        let l: NWListener
        if port == 0 {
            l = try NWListener(using: params)
        } else {
            l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        listenerGeneration += 1
        let generation = listenerGeneration
        l.stateUpdateHandler = { [weak self] st in
            let report: ListenerReport
            switch st {
            case .ready: report = .ready(l.port?.rawValue ?? 0)
            case let .failed(error): report = .failed(String(describing: error))
            default: return
            }
            Task { @MainActor in self?.listenerChanged(report, generation: generation) }
        }
        l.newConnectionHandler = { [weak self] nw in
            Task { @MainActor in self?.accept(nw) }
        }
        listener = l
        advertiser?.attach(to: l)
        l.start(queue: Self.listenerQueue)
    }

    private enum ListenerReport: Sendable {
        case ready(UInt16)
        case failed(String)
    }

    private func listenerChanged(_ report: ListenerReport, generation: Int) {
        guard generation == listenerGeneration else { return }
        switch report {
        case let .ready(p):
            port = p
            isListening = true
            restartAttempts = 0
            emit(.listening(port: p))
        case let .failed(message):
            isListening = false
            listener?.cancel()
            listener = nil
            // Rebinding the same port right after a close can briefly fail: retry.
            if let p = port, restartAttempts < Self.maxRestartAttempts {
                restartAttempts += 1
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.listener == nil, self.identity != nil else { return }
                    try? self.startListener(port: p)
                }
            } else {
                emit(.listenerFailed(message))
            }
        }
    }

    private func accept(_ nw: NWConnection) {
        Task { [weak self] in
            guard let conn = try? await ControlConnection.open(nw, timeout: .seconds(10)) else { return }
            self?.attach(conn)
        }
    }

    private func attach(_ conn: ControlConnection) {
        // The window may have closed between the TLS handshake and now.
        guard policy.accepts(conn.peerFingerprint) else {
            conn.close()
            emit(.rejected(.notPairedCertificate))
            return
        }
        let session = Session(conn: conn)
        sessions[ObjectIdentifier(session)] = session
        armSilence(session)
        session.reader = Task { [weak self] in
            do {
                for try await envelope in conn.envelopes {
                    guard let self else { return }
                    self.handle(envelope, in: session)
                }
            } catch {}
            self?.drop(session)
        }
    }

    // MARK: message handling

    private func handle(_ env: AMEnvelope, in session: Session) {
        guard sessions[ObjectIdentifier(session)] != nil else { return }
        armSilence(session)
        let paired = pairedPhone(session.conn.peerFingerprint)

        if env.type == MessageType.goodbye.rawValue {
            handleGoodbye(env, paired: paired, in: session)
            return
        }
        switch session.phase {
        case .awaitingFirst:
            if env.type == MessageType.pairRequest.rawValue {
                handlePairRequest(env, in: session)
            } else if paired == nil {
                reject(session, .notPaired, .notPairedCertificate)
            } else if env.type == MessageType.hello.rawValue, let paired {
                handleHello(env, phone: paired, in: session)
            }
            // A paired phone's other messages before hello are ignored.
        case .pairing:
            if env.type == MessageType.pairConfirm.rawValue, let w = window, w.session === session {
                let accepted = (try? AMPairConfirm(serializedBytes: env.payload))?.accepted ?? false
                apply(w.flow.remoteDecision(accepted, now: now()), window: w)
            }
        case let .awaitingHello(phone):
            if env.type == MessageType.hello.rawValue { handleHello(env, phone: phone, in: session) }
        case .active:
            if env.type == MessageType.ping.rawValue {
                post(session, .pong, AMPong(), channel: .system, replyTo: env.id)
            } else if env.type != MessageType.hello.rawValue {
                onMessage?(env)
            }
        case .closed:
            break
        }
    }

    private func handlePairRequest(_ env: AMEnvelope, in session: Session) {
        guard let w = window else {
            // Ruling R2: no window, or its secret is spent: the code has expired.
            reject(session, .pairingExpired, .pairingExpired)
            return
        }
        guard let request = try? AMPairRequest(serializedBytes: env.payload) else {
            reject(session, .pairingRejected, .pairingRejected)
            return
        }
        switch w.flow.verify(request, phoneFingerprint: session.conn.peerFingerprint, now: now()) {
        case let .rejected(code):
            reject(session, code, Self.rejection(for: code))
        case let .verified(code):
            w.session = session
            w.request = request
            w.code = code
            session.phase = .pairing
            post(session, .pairVerified, AMPairVerified(), channel: .pairing, replyTo: env.id)
            let timeout = confirmationTimeout
            w.timer = Task { [weak self, weak w] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, let w, self.window === w, let s = w.session else { return }
                self.post(s, .pairConfirm, self.confirm(false), channel: .pairing)
                self.endWindow(w, rejection: .pairingTimedOut)
            }
            recomputeState()
            emit(.pairingCode(code))
        }
    }

    private func apply(_ outcome: PairingOutcome, window w: PairingWindow) {
        switch outcome {
        case .waiting:
            break
        case .paired:
            guard let session = w.session, let request = w.request else { return }
            let phone = PairedPhone(id: session.conn.peerFingerprint.lowercaseHex, name: request.deviceName,
                                    model: request.deviceModel, certificateDER: session.conn.peerCertificateDER,
                                    pairedAt: now())
            var complete = AMPairComplete()
            do {
                complete.discoveryKey = try secrets.discoveryKey()
                try phones.save(phone)
            } catch {
                // Detach first so dropping the session does not also report "cancelled".
                w.session = nil
                endWindow(w, rejection: nil)
                reject(session, .pairingRejected, .pairingRejected)
                return
            }
            complete.macName = macName
            post(session, .pairComplete, complete, channel: .pairing)
            session.phase = .awaitingHello(phone)
            w.session = nil
            endWindow(w, rejection: nil)
            emit(.paired(phone))
        case .cancelled:
            endWindow(w, rejection: .pairingCancelled)
        case .timedOut:
            endWindow(w, rejection: .pairingTimedOut)
        }
    }

    /// Closes the pairing window; also closes its pairing connection, if any.
    private func endWindow(_ w: PairingWindow, rejection: MacRejection?) {
        w.timer?.cancel()
        if window === w { window = nil }
        if let s = w.session {
            w.session = nil
            drop(s, flush: true)
        }
        refreshPolicy()
        if let rejection { emit(.rejected(rejection)) }
        recomputeState()
    }

    private func handleHello(_ env: AMEnvelope, phone: PairedPhone, in session: Session) {
        guard let remote = try? AMHello(serializedBytes: env.payload) else {
            drop(session)
            return
        }
        let local = macHello()
        switch Handshake.evaluate(local: local, remote: remote) {
        case .incompatible:
            incompatiblePhone = remote.deviceName.isEmpty ? phone.name : remote.deviceName
            reject(session, .protocolMismatch, .protocolMismatch)
        case let .ok(shared):
            if let current = active, current !== session {
                if current.conn.peerFingerprint == session.conn.peerFingerprint {
                    // The same phone came back (new address, half-dead old socket): replace.
                    active = nil
                    drop(current)
                } else {
                    reject(session, .busy, .busy)
                    return
                }
            }
            post(session, .hello, local, channel: .system, replyTo: env.id)
            session.phase = .active(phone, shared)
            active = session
            incompatiblePhone = nil
            recomputeState()
            emit(.connected(phone, shared: shared))
        }
    }

    private func handleGoodbye(_ env: AMEnvelope, paired: PairedPhone?, in session: Session) {
        let reason = (try? AMGoodbye(serializedBytes: env.payload))?.reason ?? .unspecified
        if reason == .unpaired, let paired {
            try? phones.remove(id: paired.id)
            refreshPolicy()
            emit(.unpaired(paired))
        }
        drop(session)
    }

    // MARK: sessions

    private func armSilence(_ session: Session) {
        session.silence?.cancel()
        let timeout = silenceTimeout
        session.silence = Task { [weak self, weak session] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let session else { return }
            self.drop(session)
        }
    }

    /// Sends `system.error code`, closes, and reports `rejection`.
    private func reject(_ session: Session, _ code: AMErrorCode, _ rejection: MacRejection) {
        var error = AMError()
        error.code = code
        error.message = "\(rejection.rawValue)"
        post(session, .error, error, channel: .system)
        drop(session, flush: true)
        emit(.rejected(rejection))
        recomputeState()
    }

    /// Forgets a session and closes its connection. Idempotent.
    private func drop(_ session: Session, flush: Bool = false) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        session.silence?.cancel()
        let phase = session.phase
        session.phase = .closed
        if flush { session.conn.closeAfterFlush() } else { session.conn.close() }
        if let w = window, w.session === session {
            // The phone went away mid-confirmation: the spent secret cannot be reused.
            w.session = nil
            _ = w.flow.localDecision(false, now: now())
            endWindow(w, rejection: .pairingCancelled)
        }
        if active === session {
            active = nil
            if case let .active(phone, _) = phase { emit(.disconnected(phone)) }
        }
        recomputeState()
    }

    private func post(_ session: Session, _ type: MessageType, _ message: some SwiftProtobuf.Message,
                      channel: AMChannel, replyTo: UInt64 = 0) {
        _ = try? session.conn.post(type, message, channel: channel, replyTo: replyTo)
    }

    // MARK: helpers

    private func pairedPhone(_ fingerprint: Data) -> PairedPhone? {
        (try? phones.all())?.first { $0.fingerprint == fingerprint }
    }

    private func refreshPolicy() {
        let paired = Set(((try? phones.all()) ?? []).map(\.fingerprint))
        policy.update(paired: paired, windowOpen: window != nil)
    }

    private func recomputeState() {
        let next: MacConnectionState
        if let w = window {
            next = .pairing(uri: w.uri, code: w.code)
        } else if let a = active, case let .active(phone, shared) = a.phase {
            next = .connected(phone, shared: shared)
        } else if let name = incompatiblePhone {
            next = .incompatible(phoneName: name)
        } else {
            next = .idle
        }
        if next != state { state = next }
    }

    private func emit(_ event: MacServerEvent) { onEvent?(event) }

    private func macHello() -> AMHello {
        var hello = AMHello()
        hello.protocolVersion = Handshake.protocolVersion
        hello.appVersion = appVersion
        hello.capabilities = capabilities.sorted()
        hello.deviceName = macName
        hello.deviceModel = "Mac"
        return hello
    }

    private func confirm(_ accepted: Bool) -> AMPairConfirm {
        var c = AMPairConfirm()
        c.accepted = accepted
        return c
    }

    private static func rejection(for code: AMErrorCode) -> MacRejection {
        switch code {
        case .notPaired: .notPairedCertificate
        case .busy: .busy
        case .protocolMismatch: .protocolMismatch
        case .badPairingSecret: .badPairingSecret
        case .pairingExpired: .pairingExpired
        default: .pairingRejected
        }
    }
}

/// One accepted connection and where it is in the protocol.
@MainActor
private final class Session {
    enum Phase {
        case awaitingFirst
        case pairing
        case awaitingHello(PairedPhone)
        case active(PairedPhone, Set<String>)
        case closed
    }

    let conn: ControlConnection
    var phase: Phase = .awaitingFirst
    var silence: Task<Void, Never>?
    var reader: Task<Void, Never>?

    init(conn: ControlConnection) { self.conn = conn }
}

/// An open pairing window.
@MainActor
private final class PairingWindow {
    let flow: MacPairingFlow
    let uri: PairingURI
    var code: String?
    var session: Session?
    var request: AMPairRequest?
    var timer: Task<Void, Never>?

    init(flow: MacPairingFlow, uri: PairingURI) {
        self.flow = flow
        self.uri = uri
    }
}

/// Who may complete the TLS handshake; read from the TLS verify queue.
final class PeerPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var paired: Set<Data> = []
    private var windowOpen = false

    func update(paired: Set<Data>, windowOpen: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.paired = paired
        self.windowOpen = windowOpen
    }

    func accepts(_ fingerprint: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return windowOpen || paired.contains(fingerprint)
    }
}
