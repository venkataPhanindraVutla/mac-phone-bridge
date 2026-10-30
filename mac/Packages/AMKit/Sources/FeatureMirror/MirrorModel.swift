import AMProtocol
import AppKit
import ConnectionCore
import Foundation
import Observation
import os
import SwiftProtobuf

/// Why a session ended, as the window shows it.
public enum MirrorEndReason: Equatable, Sendable {
    /// The phone's `mirror.state` STOPPED/FAILED or `mirror.stop`, with its reason; also
    /// `LINK_FAILED` when a link ends with no state from the phone within 1 s.
    case phone(AMMirrorReason)
    /// No RUNNING and first frame within the start deadline.
    case timeout
    case disconnected
    case macSleep
    case user
}

/// Screen mirroring (SPEC section 24, PRD F-17), while the phone shares `mirror.v1`.
///
/// `start()` issues the bulk tokens (context `mirror-<session>`), sends `mirror.start` and waits
/// for the phone's RUNNING and the first decoded frame. The phone dials one bulk link per token
/// (roles `MIRROR_VIDEO`, `MIRROR_AUDIO`, `MIRROR_CONTROL`), handed in through `link(_:grant:)`.
/// The tokens are revoked whenever the session ends, for any reason.
///
/// Which side sends which `MirrorReason`: the Mac's own `mirror.stop` always carries `USER`
/// (the user's stop, closing the window, the start deadline, a dead link, the Mac going to sleep);
/// `REPLACED`, `LINK_FAILED`, `TURNED_OFF`, `NEEDS_SETUP`, `ADB_FAILED`, `HELPER_FAILED` and
/// `UNAVAILABLE` come from the phone. A new `start()` sends no stop: the phone ends the old
/// session with `REPLACED`. A `mirror.state` or `mirror.stop` for any session other than the
/// current one is ignored.
///
/// Mirror bytes never pass through here or the app's NotifyWork queue; only `mirror.*` messages
/// do. Logs carry session IDs, phases, reasons, sizes, presets, codecs and counts only.
@MainActor
@Observable
public final class MirrorModel: SessionFeature {
    public let messagePrefixes = ["mirror."]
    /// The deadline for RUNNING and the first frame (Global Constraints).
    public static let defaultStartDeadline: Duration = .seconds(20)
    /// The scrcpy RESET_VIDEO control message (type 17).
    static let resetVideo = ScrcpyControl.resetVideo()

    public enum Phase: Equatable {
        case idle, starting
        case running(width: Int, height: Int)
        case ended(MirrorEndReason)
    }

    public private(set) var phase: Phase = .idle
    /// The phone's last `mirror.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?
    /// The current (or last) session, a Mac counter from 1.
    public private(set) var sessionID: UInt32 = 0
    public var preset: QualityPreset = .high
    /// The codec asked for; unspecified is sent as H.264.
    public var codec: AMVideoCodec = .h264

    /// `mirror.v1` is shared, the phone's availability is enabled and the bulk listener has a port.
    public var canStart: Bool {
        sharesMirror && phoneAvailability?.enabled == true && bulk.port != nil
    }

    /// The running (or starting) session; nil otherwise.
    public var session: MirrorSession? { current }

    /// Lets go of held input (the mirror view's `InputMapper.releaseAll`). Called while the session
    /// is still current, before it ends for any reason (so the UP goes out on its control link before
    /// the links close), and after a session packet changes the video size (so the UP carries the
    /// new size, the only one the helper accepts).
    @ObservationIgnored public var releaseInput: (@MainActor () -> Void)?
    /// Text the view has just set on the phone's clipboard to paste (⌘V, emoji, other scripts).
    /// Task 8 wires it; never logged.
    @ObservationIgnored public var onPasteSent: ((String) -> Void)?

    @ObservationIgnored private let bulk: any BulkGrants
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let makeSink: @MainActor () -> any FrameSink
    @ObservationIgnored private let startDeadline: Duration
    /// How long a link end waits for the phone's state before it counts as LINK_FAILED (internal, for tests).
    @ObservationIgnored var linkGrace: Duration = .seconds(1)
    private var sharesMirror = false
    /// The phone in session; a forget for any other phone leaves this model alone.
    @ObservationIgnored private var phoneID: String?
    @ObservationIgnored private var current: MirrorSession?
    @ObservationIgnored private var phoneRunning = false
    /// The current session's first picture is decoded (internal, for tests).
    @ObservationIgnored private(set) var firstFrameSeen = false
    /// The current session's last reported video size.
    @ObservationIgnored private var videoSize: (width: Int, height: Int)?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var linkEnd: Task<Void, Never>?

    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "mirror")

    public init(bulk: any BulkGrants,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                makeSink: @escaping @MainActor () -> any FrameSink, startDeadline: Duration = MirrorModel.defaultStartDeadline) {
        self.bulk = bulk
        self.send = send
        self.makeSink = makeSink
        self.startDeadline = startDeadline
    }

    /// A link end is waiting for the phone's state (internal, for tests).
    var linkEndPending: Bool { linkEnd != nil }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        if current != nil { end(.disconnected) }
        sharesMirror = shared.contains("mirror.v1")
        self.phoneID = phoneID
        phoneAvailability = nil
    }

    public func disconnected() {
        if current != nil { end(.disconnected) }
        sharesMirror = false
        phoneID = nil
        phoneAvailability = nil
    }

    public func message(_ envelope: AMEnvelope) async {
        guard sharesMirror else { return }
        switch MessageType(rawValue: envelope.type) {
        case .mirrorAvailability:
            // Turning it off mid-session is the phone's to end (STOPPED or FAILED TURNED_OFF).
            guard let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
            phoneAvailability = a
        case .mirrorState:
            guard let s = try? AMMirrorState(serializedBytes: envelope.payload),
                  s.session == sessionID, current != nil else { return }
            switch s.phase {
            case .running:
                phoneRunning = true
                becomeRunningIfReady()
            case .stopped, .failed:
                end(.phone(s.reason))
            default:
                break
            }
        case .mirrorStop:
            guard let s = try? AMMirrorStop(serializedBytes: envelope.payload),
                  s.session == sessionID, current != nil else { return }
            end(.phone(s.reason))
        default:
            break
        }
    }

    /// Only the phone in session counts (the queue sends `disconnected()` before forgetting it);
    /// forgetting another paired phone leaves the session and the availability alone.
    public func forget(phoneID: String) async {
        guard phoneID == self.phoneID else { return }
        if current != nil { end(.disconnected) }
        self.phoneID = nil
        sharesMirror = false
        phoneAvailability = nil
    }

    // MARK: API

    /// Starts a new session (replacing the current one), when `canStart`.
    public func start() async {
        guard canStart, let port = bulk.port else { return }
        if current != nil { end(nil) }
        sessionID += 1
        let id = sessionID
        let context = Self.context(id)
        let videoCodec: AMVideoCodec = codec == .h265 ? .h265 : .h264
        var start = AMMirrorStart()
        start.session = id
        start.port = UInt32(port)
        start.maxSize = preset.maxSize
        start.videoBitRate = preset.bitRate
        start.maxFps = preset.maxFps
        start.videoCodec = videoCodec
        start.audio = false // Task 7 turns audio on; its token stays empty until then.
        start.tokens.video = bulk.issue(role: .mirrorVideo, context: context)
        start.tokens.control = bulk.issue(role: .mirrorControl, context: context)

        current = MirrorSession(id: id, sink: makeSink(), events: Self.eventHandler(for: self, session: id))
        phoneRunning = false
        firstFrameSeen = false
        videoSize = nil
        phase = .starting
        deadline = Task { [weak self, startDeadline] in
            try? await Task.sleep(for: startDeadline)
            guard !Task.isCancelled, let self, self.sessionID == id, self.phase == .starting else { return }
            await self.stopCurrent(.timeout)
        }
        Self.log.info("session \(id, privacy: .public) start preset \(self.preset.name, privacy: .public) codec \(videoCodec == .h265 ? "h265" : "h264", privacy: .public)")
        await send(.mirrorStart, start)
    }

    /// The user's stop (also closing the window): `mirror.stop{session, USER}`.
    public func stop() async {
        await stopCurrent(.user)
    }

    /// The Mac is going to sleep: like `stop()`.
    /// The links close before the stop is awaited, so nothing stays open across sleep even if the
    /// Mac sleeps before the send completes.
    public func macWillSleep() async {
        await stopCurrent(.macSleep, closeFirst: true)
    }

    /// `macWillSleep()` for the sleep notification: everything local happens now, before returning;
    /// the stop goes out from a task.
    public func macWillSleepNow() {
        guard let stop = endLocally(.macSleep, closeFirst: true) else { return }
        Task { await send(.mirrorStop, stop.message) }
    }

    /// A bulk link whose token redeemed. Only the current session's context is kept.
    public func link(_ pipe: any BulkPipe, grant: BulkGrant) {
        guard let current, grant.context == Self.context(sessionID) else {
            pipe.close()
            return
        }
        current.attach(pipe, role: grant.role)
    }

    // MARK: session events

    /// The session's event callback: built here, nonisolated, so the closure handed to the
    /// session's read loops and VideoToolbox's thread carries no main-actor isolation; it hops.
    nonisolated static func eventHandler(for model: MirrorModel, session id: UInt32) -> @Sendable (MirrorSessionEvent) -> Void {
        { [weak model] event in
            Task { @MainActor in model?.handle(event, session: id) }
        }
    }

    /// Internal so tests can deliver events directly.
    func handle(_ event: MirrorSessionEvent, session id: UInt32) {
        guard id == sessionID, let current else { return }
        switch event {
        case .firstFrame:
            firstFrameSeen = true
            becomeRunningIfReady()
        case let .size(width, height):
            let changed = videoSize.map { $0 != (width, height) } ?? false
            videoSize = (width, height)
            if case .running = phase {
                phase = .running(width: width, height: height)
                Self.log.info("session \(id, privacy: .public) size \(width, privacy: .public)x\(height, privacy: .public)")
            }
            if changed { releaseInput?() }
        case .needsReset:
            current.sendControl(Self.resetVideo)
        case let .linkEnded(role):
            // Audio may end on its own (Task 7); video or control ending ends the session.
            guard role != .mirrorAudio, linkEnd == nil else { return }
            linkEnd = Task { [weak self, linkGrace] in
                try? await Task.sleep(for: linkGrace)
                guard !Task.isCancelled, let self, self.sessionID == id, self.current != nil else { return }
                await self.stopCurrent(.phone(.linkFailed))
            }
        }
    }

    // MARK: private

    private static func context(_ id: UInt32) -> String { "mirror-\(id)" }

    private func becomeRunningIfReady() {
        guard phase == .starting, phoneRunning, firstFrameSeen, let current else { return }
        let size = videoSize ?? current.videoSize ?? (0, 0)
        phase = .running(width: size.width, height: size.height)
        deadline?.cancel()
        deadline = nil
        Self.log.info("session \(self.sessionID, privacy: .public) running \(size.width, privacy: .public)x\(size.height, privacy: .public)")
    }

    /// Ends the current session from this side and tells the phone (`mirror.stop`, reason USER).
    /// The session ends here first, so the phone's answer finds nothing to act on. The links close
    /// after the stop has gone (so the phone hears the stop first), or before when `closeFirst`.
    private func stopCurrent(_ reason: MirrorEndReason, closeFirst: Bool = false) async {
        guard let stop = endLocally(reason, closeFirst: closeFirst) else { return }
        await send(.mirrorStop, stop.message)
        stop.session?.close()
    }

    /// The local half of a stop: ends the session and builds its `mirror.stop{session, USER}`.
    private func endLocally(_ reason: MirrorEndReason, closeFirst: Bool) -> (message: AMMirrorStop, session: MirrorSession?)? {
        guard current != nil else { return nil }
        var stop = AMMirrorStop()
        stop.session = sessionID
        stop.reason = .user
        let session = end(reason, closing: closeFirst)
        return (stop, closeFirst ? nil : session)
    }

    /// Ends the current session: revokes its tokens, closes it (unless the caller will) and sets
    /// `.ended(reason)`, or leaves the phase to the caller when `reason` is nil (a replacing start).
    @discardableResult
    private func end(_ reason: MirrorEndReason?, closing: Bool = true) -> MirrorSession? {
        guard let session = current else { return nil }
        releaseInput?()
        current = nil
        deadline?.cancel()
        deadline = nil
        linkEnd?.cancel()
        linkEnd = nil
        bulk.revoke(context: Self.context(session.id))
        if closing { session.close() }
        let errors = session.decoder.decodeErrors
        let why = reason.map(Self.describe) ?? "replaced"
        Self.log.info("session \(session.id, privacy: .public) ended \(why, privacy: .public) decode errors \(errors, privacy: .public)")
        if let reason { phase = .ended(reason) }
        return session
    }

    private static func describe(_ reason: MirrorEndReason) -> String {
        switch reason {
        case let .phone(r): "phone \(r)"
        case .timeout: "timeout"
        case .disconnected: "disconnected"
        case .macSleep: "macSleep"
        case .user: "user"
        }
    }
}

/// Tells the main actor when the Mac is about to sleep. The observer block is built here,
/// nonisolated, and runs on the main queue whatever thread posts the notification.
public enum MacSleepObserver {
    nonisolated public static func install(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                                           _ handler: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        // Delivered on the main queue: at once when posted there (as the system does), else one hop.
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
