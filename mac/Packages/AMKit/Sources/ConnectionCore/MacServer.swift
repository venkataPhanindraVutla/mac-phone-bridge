import AMProtocol
import CryptoKit
import Foundation
import Network
import Observation
import os
import SwiftProtobuf

/// What the pairing window and the menu show. A pairing window takes precedence over a
/// connected phone here; whether a phone is connected is `MacServer.activePhone`.
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

/// The phone in session with the Mac and the capabilities both sides share.
public struct ActivePhone: Equatable, Sendable {
    public let phone: PairedPhone
    public let shared: Set<String>

    public init(phone: PairedPhone, shared: Set<String>) {
        self.phone = phone
        self.shared = shared
    }
}

public enum MacServerError: Error, Equatable, Sendable {
    case notConnected
}

/// Why the Mac ended a phone's session. Logged as `phone session ended: <code>`: a code only,
/// never a name, id or address.
enum SessionEndReason: String, Sendable {
    /// 75 s with nothing received (a phone without `liveness.v1`, SPEC 7).
    case silence
    /// The third consecutive silent ping interval (`liveness.v1`, SPEC 7).
    case liveness
    /// The phone closed the connection.
    case eof
    /// A transport, TLS or framing error, or an unreadable hello.
    case error
    /// `system.goodbye` from the phone.
    case goodbye
    /// The Mac woke from sleep (a phone without `liveness.v1`).
    case wake
    /// The same phone connected again.
    case replaced
    /// The server stopped (the Mac app quits).
    case stop
    /// The phone was forgotten on the Mac, or said goodbye UNPAIRED on another connection.
    case unpaired
    /// The Mac sent `system.error` and closed (busy, protocol mismatch, pairing errors).
    case rejected
    /// The pairing window ended.
    case pairing
}

/// The Mac's side of the protocol: listens for phones, runs pairing (SPEC 5.3), enforces the
/// rules after pairing (5.4), keep-alive and wake handling (7). Serves one phone at a time.
@MainActor
@Observable
public final class MacServer {
    public private(set) var state: MacConnectionState = .idle
    public private(set) var port: UInt16?
    public private(set) var isListening = false
    /// The phone in session, whether or not a pairing window is open.
    public private(set) var activePhone: ActivePhone?
    /// True while a pairing window is open whose secret can no longer verify: older than its
    /// lifetime, used, or burned by bad proofs. Unknown certificates are then refused at TLS.
    public private(set) var pairingSecretSpent = false

    /// Messages from the connected phone other than hello/ping/pong/goodbye.
    @ObservationIgnored public var onMessage: ((AMEnvelope) -> Void)?
    @ObservationIgnored public var onEvent: ((MacServerEvent) -> Void)?
    /// Test hook: sees every accepted NWConnection before the handshake.
    @ObservationIgnored var onAcceptForTesting: ((NWConnection) -> Void)?
    /// Where the end of each phone session (one that reached `.active`) is reported: the log by
    /// default, so a Release build can tell why a phone dropped. Tests replace it.
    @ObservationIgnored var logSessionEnd: (SessionEndReason) -> Void = { reason in
        MacServer.sessionLog.notice("phone session ended: \(reason.rawValue, privacy: .public)")
    }
    private nonisolated static let sessionLog = Logger(subsystem: "io.github.anmirror.mac", category: "connection")

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
    @ObservationIgnored private let pingInterval: Duration
    @ObservationIgnored private let missedPingLimit: Int
    @ObservationIgnored private let livenessClock: any Clock<Duration>
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
    /// The paired phones as last read from `phones`; nil means read again. Every change made
    /// through this server (save, remove, forget) clears it.
    @ObservationIgnored private var pairedCache: [PairedPhone]?
    /// Secrets of windows this process closed or replaced, newest last. A proof made with
    /// one of them is an old QR code: it gets PAIRING_EXPIRED, not BAD_PAIRING_SECRET.
    @ObservationIgnored private var retiredSecrets: [Data] = []
    private static let maxRetiredSecrets = 16

    private static let listenerQueue = DispatchQueue(label: "io.github.anmirror.listener")
    private static let maxRestartAttempts = 40

    /// - Parameters:
    ///   - silenceTimeout: drop a connection after this long with no incoming message (SPEC 7).
    ///     Not used for a session that shares `liveness.v1`.
    ///   - pairingLifetime: seconds a pairing secret stays valid (SPEC 5.1).
    ///   - confirmationTimeout: how long to wait for both users' decisions (SPEC 5.3 step 4).
    ///   - pingInterval: with `liveness.v1` shared, the Mac pings this often (SPEC 7).
    ///   - missedPingLimit: with `liveness.v1` shared, drop the phone at this many consecutive
    ///     intervals with nothing received.
    ///   - livenessClock: the clock the ping interval is measured on (a test hook).
    public init(identity: any IdentityProvider, phones: any PairedPhoneStore, secrets: any SecretStore,
                macName: String, appVersion: String, capabilities: Set<String>, advertise: Bool = true,
                silenceTimeout: Duration = .seconds(75), pairingLifetime: TimeInterval = 300,
                confirmationTimeout: Duration = .seconds(60), pingInterval: Duration = Liveness.defaultInterval,
                missedPingLimit: Int = Liveness.defaultMissedLimit, livenessClock: any Clock<Duration> = ContinuousClock(),
                now: @escaping () -> Date = Date.init) {
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
        self.pingInterval = pingInterval
        self.missedPingLimit = missedPingLimit
        self.livenessClock = livenessClock
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
        pairedCache = nil
        refreshPolicy()
        restartAttempts = 0
        try startListener(port: port ?? 0)
    }

    /// Closes every connection and the listener. A phone past pairing is told first
    /// (`system.goodbye SHUTDOWN`): it keeps the pairing and reconnects with its usual backoff.
    public func stop() {
        if let w = window { endWindow(w, rejection: nil, phoneError: .pairingRejected) }
        var bye = AMGoodbye()
        bye.reason = .shutdown
        for s in Array(sessions.values) {
            switch s.phase {
            case .active, .awaitingHello:
                post(s, .goodbye, bye, channel: .system)
                drop(s, .stop, flush: true)
            default:
                drop(s, .stop)
            }
        }
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        advertiser?.stop()
        isListening = false
        refreshPolicy()
        recomputeState()
    }

    /// After wake from sleep: listen again on the same port. A session that shares `liveness.v1`
    /// is kept and pinged at once (its silent count starts over), so a locked phone that never
    /// noticed the sleep stays connected; the drop rule ends it if it is gone. Every other
    /// connection is closed, as in 0.1 (SPEC 7).
    public func handleWake() {
        for s in Array(sessions.values) {
            if s.liveness != nil { startLiveness(s, pingNow: true) } else { drop(s, .wake) }
        }
        guard identity != nil, let port else { return }
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        isListening = false
        restartAttempts = 0
        advertiser?.rotateInstanceName()
        try? startListener(port: port)
        recomputeState()
    }

    // MARK: pairing

    /// Opens a pairing window with a fresh secret and returns the QR content. Call after
    /// `start()` once `port` is known. Replaces any window already open.
    public func beginPairing() -> PairingURI {
        guard let identity else { preconditionFailure("MacServer.start() must succeed before beginPairing()") }
        if let old = window {
            endWindow(old, rejection: old.session == nil ? nil : .pairingRejected, phoneError: .pairingRejected)
        }
        let flow = MacPairingFlow(macFingerprint: identity.fingerprint, now: now(), lifetime: pairingLifetime)
        let uri = PairingURI(macFingerprint: identity.fingerprint, secret: flow.secret,
                             hosts: PairingHosts.current(), port: port ?? 0, macName: macName)
        let w = PairingWindow(flow: flow, uri: uri)
        window = w
        // Close the TLS gate when the secret runs out (the window itself stays, ruling R11).
        let lifetime = pairingLifetime
        w.expiry = Task { [weak self, weak w] in
            do { try await Task.sleep(for: .seconds(lifetime) + .milliseconds(50)) } catch { return }
            guard let self, let w, self.window === w else { return }
            self.refreshPolicy()
        }
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
        let known = pairedList().first { $0.id == phoneID }
        // Untrust first, so a reconnect cannot slip in while the goodbye is on its way.
        try? phones.remove(id: phoneID)
        pairedCache = nil
        refreshPolicy()
        var bye = AMGoodbye()
        bye.reason = .unpaired
        for s in Array(sessions.values) where s.conn.peerFingerprint.lowercaseHex == phoneID {
            switch s.phase {
            case .active, .awaitingHello: post(s, .goodbye, bye, channel: .system)
            default: break
            }
            drop(s, .unpaired, flush: true)
        }
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
        onAcceptForTesting?(nw)
        Task { [weak self] in
            do {
                let conn = try await ControlConnection.open(nw, timeout: .seconds(10))
                if let self { self.attach(conn) } else { conn.close() }
            } catch {
                nw.cancel()
            }
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
            var reason = SessionEndReason.eof
            do {
                for try await envelope in conn.envelopes {
                    guard let self else { return }
                    self.handle(envelope, in: session)
                }
            } catch {
                reason = .error
            }
            self?.drop(session, reason)
        }
    }

    // MARK: message handling

    private func handle(_ env: AMEnvelope, in session: Session) {
        guard sessions[ObjectIdentifier(session)] != nil else { return }
        // With `liveness.v1` the ping ticks decide; otherwise the 0.1 silence rule (SPEC 7).
        if session.liveness != nil { session.liveness?.received() } else { armSilence(session) }
        let paired = pairedPhone(session.conn.peerFingerprint)

        if env.type == MessageType.goodbye.rawValue {
            handleGoodbye(env, paired: paired, in: session)
            return
        }
        if env.type == MessageType.pairRequest.rawValue {
            if case .awaitingFirst = session.phase {
                handlePairRequest(env, in: session)
            } else if let w = window, !w.flow.isSpent(now: now()) {
                // Pairing must be the first message on a connection.
                reject(session, .pairingRejected, .pairingRejected)
            } else {
                // Ruling R2, in every phase.
                reject(session, .pairingExpired, .pairingExpired)
            }
            return
        }
        switch session.phase {
        case .awaitingFirst:
            if paired == nil {
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
            } else if env.type != MessageType.hello.rawValue && env.type != MessageType.pong.rawValue {
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
        if matchesRetiredSecret(request.secretProof, phoneFingerprint: session.conn.peerFingerprint) {
            // An older QR code from this Mac (Review Focus 3); does not use up an attempt.
            reject(session, .pairingExpired, .pairingExpired)
            return
        }
        let verdict = w.flow.verify(request, phoneFingerprint: session.conn.peerFingerprint, now: now())
        // A used, burned or expired secret closes the TLS gate for unknown certificates.
        refreshPolicy()
        switch verdict {
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
                defer { pairedCache = nil }
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

    /// Closes the pairing window; also closes its pairing connection, if any, first sending
    /// `system.error phoneError` when given (SPEC 5.3: the Mac refuses to continue).
    private func endWindow(_ w: PairingWindow, rejection: MacRejection?, phoneError: AMErrorCode? = nil) {
        w.timer?.cancel()
        w.expiry?.cancel()
        if window === w { window = nil }
        retire(w.flow.secret)
        if let s = w.session {
            w.session = nil
            if let phoneError {
                var error = AMError()
                error.code = phoneError
                error.message = "pairing window closed"
                post(s, .error, error, channel: .system)
            }
            drop(s, .pairing, flush: true)
        }
        refreshPolicy()
        if let rejection { emit(.rejected(rejection)) }
        recomputeState()
    }

    private func handleHello(_ env: AMEnvelope, phone: PairedPhone, in session: Session) {
        guard let remote = try? AMHello(serializedBytes: env.payload) else {
            drop(session, .error)
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
                    drop(current, .replaced)
                } else {
                    reject(session, .busy, .busy)
                    return
                }
            }
            post(session, .hello, local, channel: .system, replyTo: env.id)
            session.phase = .active(phone, shared)
            if shared.contains(Liveness.capability) { startLiveness(session) }
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
            pairedCache = nil
            refreshPolicy()
            emit(.unpaired(paired))
            for s in Array(sessions.values) where s.conn.peerFingerprint == paired.fingerprint { drop(s, .unpaired) }
        }
        drop(session, .goodbye)
    }

    // MARK: sessions

    private func armSilence(_ session: Session) {
        session.silence?.cancel()
        let timeout = silenceTimeout
        session.silence = Task { [weak self, weak session] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let session else { return }
            self.drop(session, .silence)
        }
    }

    /// SPEC 7 with `liveness.v1`: the 75 s silence rule no longer applies; the Mac pings every
    /// `pingInterval`, the first one an interval after its hello, and drops the phone at the
    /// `missedPingLimit`-th consecutive interval with nothing received. With `pingNow` (wake)
    /// the count starts over and the first tick is now.
    private func startLiveness(_ session: Session, pingNow: Bool = false) {
        session.silence?.cancel()
        session.silence = nil
        session.pinger?.cancel()
        session.liveness = LivenessMonitor(missedLimit: missedPingLimit)
        if pingNow, !livenessTick(session) { return }
        let interval = pingInterval
        let clock = livenessClock
        session.pinger = Task { [weak self, weak session] in
            while true {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self, let session, self.livenessTick(session) else { return }
            }
        }
    }

    /// One ping interval has passed. Returns false once the session is gone.
    private func livenessTick(_ session: Session) -> Bool {
        guard sessions[ObjectIdentifier(session)] != nil, var monitor = session.liveness else { return false }
        let action = monitor.tick()
        session.liveness = monitor
        switch action {
        case .sendPing:
            post(session, .ping, AMPing(), channel: .system)
            return true
        case .drop:
            drop(session, .liveness)
            return false
        }
    }

    /// Sends `system.error code`, closes, and reports `rejection`.
    private func reject(_ session: Session, _ code: AMErrorCode, _ rejection: MacRejection) {
        var error = AMError()
        error.code = code
        error.message = "\(rejection.rawValue)"
        post(session, .error, error, channel: .system)
        drop(session, .rejected, flush: true)
        emit(.rejected(rejection))
        recomputeState()
    }

    /// Forgets a session and closes its connection. Idempotent: the first reason is the one
    /// logged, and only for a phone session (one that reached `.active`).
    private func drop(_ session: Session, _ reason: SessionEndReason, flush: Bool = false) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        session.silence?.cancel()
        session.pinger?.cancel()
        let phase = session.phase
        session.phase = .closed
        if case .active = phase { logSessionEnd(reason) }
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

    private func retire(_ secret: Data) {
        guard !retiredSecrets.contains(secret) else { return }
        retiredSecrets.append(secret)
        if retiredSecrets.count > Self.maxRetiredSecrets { retiredSecrets.removeFirst() }
    }

    /// Constant-time per candidate: compares HMACs of the proofs, like `MacPairingFlow`.
    private func matchesRetiredSecret(_ proof: Data, phoneFingerprint: Data) -> Bool {
        guard let macFP = identity?.fingerprint else { return false }
        var matched = false
        for secret in retiredSecrets {
            let key = SymmetricKey(data: secret)
            let expected = PairingCrypto.secretProof(secret: secret, macFingerprint: macFP,
                                                     phoneFingerprint: phoneFingerprint)
            let given = HMAC<SHA256>.authenticationCode(for: proof, using: key)
            if HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: expected, using: key) { matched = true }
        }
        return matched
    }

    /// The paired phones, read from the store only when the cache was cleared (not per message).
    private func pairedList() -> [PairedPhone] {
        if let pairedCache { return pairedCache }
        guard let loaded = try? phones.all() else { return [] } // read again next time
        pairedCache = loaded
        return loaded
    }

    private func pairedPhone(_ fingerprint: Data) -> PairedPhone? {
        pairedList().first { $0.fingerprint == fingerprint }
    }

    /// Updates who may complete the TLS handshake: paired phones, plus any certificate while a
    /// pairing window's secret is still usable.
    private func refreshPolicy() {
        let paired = Set(pairedList().map(\.fingerprint))
        let spent = window.map { $0.flow.isSpent(now: now()) } ?? false
        policy.update(paired: paired, pairingOpen: window != nil && !spent)
        if spent != pairingSecretSpent { pairingSecretSpent = spent }
    }

    private func recomputeState() {
        var phone: ActivePhone?
        if let a = active, case let .active(p, shared) = a.phase { phone = ActivePhone(phone: p, shared: shared) }
        if phone != activePhone { activePhone = phone }
        let next: MacConnectionState
        if let w = window {
            next = .pairing(uri: w.uri, code: w.code)
        } else if let phone {
            next = .connected(phone.phone, shared: phone.shared)
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
    /// Set once the session shares `liveness.v1` (SPEC 7): the Mac's ping timer and drop rule.
    var liveness: LivenessMonitor?
    var pinger: Task<Void, Never>?

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
    /// Closes the TLS gate once the secret's lifetime has passed.
    var expiry: Task<Void, Never>?

    init(flow: MacPairingFlow, uri: PairingURI) {
        self.flow = flow
        self.uri = uri
    }
}

/// Who may complete the TLS handshake; read from the TLS verify queue. `pairingOpen`: a
/// pairing window is open and its secret can still verify, so any certificate may try.
final class PeerPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var paired: Set<Data> = []
    private var pairingOpen = false

    func update(paired: Set<Data>, pairingOpen: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.paired = paired
        self.pairingOpen = pairingOpen
    }

    func accepts(_ fingerprint: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pairingOpen || paired.contains(fingerprint)
    }
}
