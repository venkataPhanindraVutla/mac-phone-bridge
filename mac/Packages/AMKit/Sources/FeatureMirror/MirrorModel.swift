import AMProtocol
import AppKit
import ConnectionCore
import CoreVideo
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
///
/// Screen off: with `screenOffByDefault` the phone's screen is turned off (SET_DISPLAY_POWER) after
/// each session's first frame; `setScreenOff` toggles it. Before any end from this side (stop,
/// closing the window, sleep, a new start for "Show Again" or a quality change) it is turned back
/// on first, if off. The helper's cleanup restores it on every other end.
///
/// The helper's clipboard goes to `onPhoneClipboard`, and files dropped on the view to
/// `onDropFiles`; the app decides what to do with them.
///
/// Quality: Auto (the default, `QualityController`) is evaluated every second while a session runs,
/// from the session's 5 s median lateness and decode backlog; a step restarts the session with the
/// new preset. So does a preset picked by hand (which turns Auto off) and "Use H.265". A restart is
/// an automatic `mirror.start` (it needs the phone's availability, R22); it keeps the window and its
/// last picture (the phase goes from running to starting, never ended) and the screen-off state:
/// the old screen comes back on first, and the new session turns it off again after its first
/// frame when it was off. LINK_SLOW from the phone makes Auto start one preset lower next time.
/// A session on H.265 that fails HELPER_FAILED before running starts again once on H.264
/// (`h265Refused`). "Measure Delay…" is `measureDelay()`.
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
    /// The quality preset of the next start (under Auto, its current step). Setting it is a choice
    /// by hand: Auto turns off. Nothing restarts here (`choosePreset` does).
    public var preset: QualityPreset {
        get {
            access(keyPath: \.preset)
            return quality.preset
        }
        set { updateQuality { $0.choose(newValue); return .keep } }
    }
    /// Auto quality (the default). Turning it on goes on from the current preset, with no restart.
    public var autoQuality: Bool {
        get {
            access(keyPath: \.autoQuality)
            return quality.auto
        }
        set { updateQuality { $0.auto = newValue; return .keep } }
    }
    /// The codec asked for; unspecified is sent as H.264.
    public var codec: AMVideoCodec = .h264
    /// The phone couldn't start on H.265, so this session fell back to H.264: the window shows
    /// `MirrorCopy.h265Note`. Cleared by the user's next start or by turning H.265 on again.
    public private(set) var h265Refused = false
    /// "Measure Delay…" is running.
    public private(set) var measuringDelay = false
    /// "Play phone audio on this Mac" (Settings, default on). A change applies at the next start.
    public var audioEnabled = true
    /// Mute / Unmute in the window: the audio link stays up and is decoded, the output drops it.
    /// Kept across sessions.
    public var muted = false {
        didSet { current?.audioMuted = muted }
    }
    /// The current session carries the phone's audio: asked for, and not ended (the phone can't
    /// capture or failed to, or its link ended). The Mute button is enabled only then.
    public private(set) var audioActive = false
    /// The phone's screen is off for the current session (Screen Off / Screen On in the window).
    public private(set) var screenOff = false
    /// "Turn the phone's screen off while mirroring" (Settings, default off): applied after each
    /// session's first frame.
    public var screenOffByDefault = false
    /// The current session's control link is attached: Screen Off / Screen On can reach the phone.
    private var controlLinked = false

    /// `mirror.v1` is shared, the phone's availability is enabled and the bulk listener has a port.
    public var canStart: Bool {
        sharesMirror && phoneAvailability?.enabled == true && bulk.port != nil
    }

    /// The running (or starting) session; nil otherwise.
    public var session: MirrorSession? { current }

    /// Lets go of held input: owned by `MirrorView.bind`, which sets it to its `InputMapper.releaseAll`
    /// (one slot; nothing else sets it, tests aside). Called while the session
    /// is still current, before it ends for any reason (so the UP goes out on its control link before
    /// the links close), and after a session packet changes the video size (so the UP carries the
    /// new size, the only one the helper accepts).
    @ObservationIgnored public internal(set) var releaseInput: (@MainActor () -> Void)?
    /// Text the view has just set on the phone's clipboard to paste (⌘V, emoji, other scripts):
    /// the phone's clipboard now holds it, so the helper's echo of it is not news. Never logged.
    @ObservationIgnored public var onPasteSent: ((String) -> Void)?
    /// The helper's clipboard while a session runs (ruling R38), with whether it answers the
    /// user's ⌘C / ⌘X in the mirror (explicit). Never logged.
    @ObservationIgnored public var onPhoneClipboard: ((String, Bool) -> Void)?
    /// Files dropped on the mirror while a session runs and the phone shares `files.v1`.
    @ObservationIgnored public var onDropFiles: (([URL]) -> Void)?

    @ObservationIgnored private let bulk: any BulkGrants
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let makeSink: @MainActor () -> any FrameSink
    @ObservationIgnored private let startDeadline: Duration
    /// How the start deadline waits out `startDeadline` (a test hook).
    @ObservationIgnored var startSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// How long a link end waits for the phone's state before it counts as LINK_FAILED (internal, for tests).
    @ObservationIgnored var linkGrace: Duration = .seconds(1)
    /// How a link end waits out `linkGrace` (a test hook).
    @ObservationIgnored var graceSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Whether this Mac decodes Opus (internal, so tests can say it doesn't); AAC otherwise.
    @ObservationIgnored var opusSupported: () -> Bool = { AudioDecoder.supports(.opus) }
    private var sharesMirror = false
    /// The phone takes files (`files.v1`): a drop on the mirror is sent.
    private var sharesFiles = false
    /// The phone in session; a forget for any other phone leaves this model alone.
    @ObservationIgnored private var phoneID: String?
    @ObservationIgnored private var current: MirrorSession?
    @ObservationIgnored private var phoneRunning = false
    /// The current session's first picture is decoded (internal, for tests).
    @ObservationIgnored private(set) var firstFrameSeen = false
    /// `screenOffByDefault` was applied to the current session (or the user chose for it).
    @ObservationIgnored private var screenOffSettled = false
    /// SET_DISPLAY_POWER(on) is queued on the current session for its end.
    @ObservationIgnored private var screenOnQueued = false
    /// Moves when an end from this side begins (stop, window close, sleep, timeout, link failed),
    /// before it waits for anything, so a `start()` waiting for the old screen to come back on
    /// knows it was overtaken, whichever of the two resumes first. Internal, for tests.
    @ObservationIgnored private(set) var stopGeneration = 0
    /// The clock each session's throttles and deadlines run on (internal, so tests can hold them).
    @ObservationIgnored var sessionClock = ResetClock.system
    /// The current session's last reported video size.
    @ObservationIgnored private var videoSize: (width: Int, height: Int)?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var linkEnd: Task<Void, Never>?
    @ObservationIgnored private var quality = QualityController()
    /// How often Auto is evaluated (internal, so tests can keep the ticker out of the way).
    @ObservationIgnored var qualityInterval: Duration = QualityController.interval
    /// Replaces the session's lateness and backlog for the ticker (internal, for tests).
    @ObservationIgnored var qualityInputForTesting: (() -> (Double?, Int))?
    /// Ticker evaluations so far (internal, for tests).
    @ObservationIgnored private(set) var qualityTicks = 0
    /// Moves whenever a session ends or a ticker starts: a ticker of another generation stops.
    @ObservationIgnored private var tickerGeneration = 0
    /// The screen-off state a restart carries into the current session: nil uses `screenOffByDefault`.
    @ObservationIgnored private var carriedScreenOff: Bool?
    /// The trial counts and waits of "Measure Delay…" (internal, so tests can shorten them).
    @ObservationIgnored var delayHarness = DelayHarness()
    /// The centre luma of each picture while the delay trials run; finished when the session ends.
    @ObservationIgnored private var delayFrames: AsyncStream<DelayFrame>.Continuation?

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
        sharesFiles = shared.contains("files.v1")
        self.phoneID = phoneID
        phoneAvailability = nil
    }

    public func disconnected() {
        if current != nil { end(.disconnected) }
        sharesMirror = false
        sharesFiles = false
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
                if s.phase == .failed, s.reason == .helperFailed, phase == .starting, codec == .h265 {
                    await fallBackToH264()
                    return
                }
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
        sharesFiles = false
        phoneAvailability = nil
    }

    // MARK: API

    /// Starts a new session (replacing the current one, whose screen is turned back on first),
    /// when `canStart`. A stop, window close or sleep (or another start) that comes while the old
    /// screen is coming back on wins: no session starts.
    public func start() async {
        await begin(carryScreenOff: nil, keepNote: false)
    }

    /// `start()`, carrying a screen-off state into the new session (a restart) and keeping the
    /// H.265 note (a restart or the fallback).
    private func begin(carryScreenOff: Bool?, keepNote: Bool) async {
        guard canStart else { return }
        let replacing = current
        let generation = stopGeneration
        await screenOnBeforeEnd()
        guard stopGeneration == generation, current == nil || current === replacing,
              canStart, let port = bulk.port else { return }
        if current != nil { end(nil) }
        if !keepNote { h265Refused = false }
        sessionID += 1
        let id = sessionID
        let context = Self.context(id)
        let videoCodec: AMVideoCodec = codec == .h265 ? .h265 : .h264
        let audio = audioEnabled
        let audioCodec: AMAudioCodec = opusSupported() ? .opus : .aac
        var start = AMMirrorStart()
        start.session = id
        start.port = UInt32(port)
        start.maxSize = preset.maxSize
        start.videoBitRate = preset.bitRate
        start.maxFps = preset.maxFps
        start.videoCodec = videoCodec
        start.audio = audio
        start.audioCodec = audioCodec
        start.tokens.video = bulk.issue(role: .mirrorVideo, context: context)
        if audio { start.tokens.audio = bulk.issue(role: .mirrorAudio, context: context) }
        start.tokens.control = bulk.issue(role: .mirrorControl, context: context)

        let session = MirrorSession(id: id, sink: makeSink(), events: Self.eventHandler(for: self, session: id),
                                    clock: sessionClock)
        session.audioMuted = muted
        current = session
        audioActive = audio
        phoneRunning = false
        firstFrameSeen = false
        screenOffSettled = false
        screenOnQueued = false
        controlLinked = false
        carriedScreenOff = carryScreenOff
        videoSize = nil
        phase = .starting
        deadline = Task { [weak self, startDeadline, startSleep] in
            try? await startSleep(startDeadline)
            guard !Task.isCancelled, let self, self.sessionID == id, self.phase == .starting else { return }
            await self.stopCurrent(.timeout)
        }
        let audioName = audio ? (audioCodec == .opus ? "opus" : "aac") : "off"
        Self.log.info("session \(id, privacy: .public) start preset \(self.preset.name, privacy: .public) codec \(videoCodec == .h265 ? "h265" : "h264", privacy: .public) audio \(audioName, privacy: .public)")
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
    /// the stop goes out from a task. A screen that is off is turned on first (queued ahead of the
    /// release, both written before the control link closes).
    public func macWillSleepNow() {
        stopGeneration += 1
        queueScreenOn()
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
        if grant.role == .mirrorControl {
            controlLinked = current.hasControlLink
            applyScreenOffSetting()
        }
    }

    /// Screen Off / Screen On is offered: a session runs and its control link is there.
    public var canSetScreenOff: Bool { phase.isRunning && controlLinked }

    /// The mirror window is closing (its `stop()` follows): a screen that is off is turned back on
    /// now, ahead of the release the view sends as the window goes. `stop()` still waits for it to
    /// be written before `mirror.stop`.
    public func screenOnBeforeClose() {
        queueScreenOn()
    }

    /// Screen Off / Screen On: SET_DISPLAY_POWER on the current session's control link (nothing
    /// without one).
    public func setScreenOff(_ off: Bool) {
        guard let current, current.hasControlLink, off != screenOff else { return }
        screenOffSettled = true
        screenOff = off
        current.sendControl(ScrcpyControl.setDisplayPower(on: !off))
        Self.log.info("session \(self.sessionID, privacy: .public) screen \(off ? "off" : "on", privacy: .public)")
    }

    // MARK: quality

    /// A preset picked by hand: Auto turns off, and a session that is starting or running starts
    /// again with it. The preset already in use changes nothing but Auto.
    public func choosePreset(_ preset: QualityPreset) async {
        let changed = preset != quality.preset
        self.preset = preset
        guard changed else { return }
        Self.log.info("session \(self.sessionID, privacy: .public) quality \(preset.name, privacy: .public) by hand")
        await restart()
    }

    /// "Use H.265": the codec of the next start; a session that is starting or running starts again.
    public func setH265(_ on: Bool) async {
        let wanted: AMVideoCodec = on ? .h265 : .h264
        if on { h265Refused = false }
        guard wanted != (codec == .h265 ? .h265 : .h264) else { return }
        codec = wanted
        await restart()
    }

    /// One Auto evaluation (the ticker's, every second; internal so tests can feed it). Only while
    /// a session runs, the phone's availability allows a start, and no delay measurement runs.
    func evaluateQuality(medianMs: Double?, backlog: Int, now: ContinuousClock.Instant) async {
        guard quality.auto, phase.isRunning, canStart, !measuringDelay else { return }
        let decision = updateQuality { $0.tick(medianMs: medianMs, backlog: backlog, now: now) }
        guard case let .switchTo(next) = decision else { return }
        Self.log.info("session \(self.sessionID, privacy: .public) quality auto \(next.name, privacy: .public)")
        await restart()
    }

    /// A session that is starting or running starts again with the current settings, keeping the
    /// window and the screen-off state.
    private func restart() async {
        guard phase == .starting || phase.isRunning, current != nil else { return }
        let off: Bool? = screenOffSettled ? screenOff : carriedScreenOff
        await begin(carryScreenOff: off, keepNote: true)
    }

    /// The phone couldn't start on H.265 (HELPER_FAILED before running): once more on H.264.
    private func fallBackToH264() async {
        Self.log.info("session \(self.sessionID, privacy: .public) h265 refused, starting with h264")
        codec = .h264
        h265Refused = true
        end(nil)
        await begin(carryScreenOff: nil, keepNote: true)
        if current == nil, phase == .starting { phase = .ended(.phone(.helperFailed)) }
    }

    /// Applies a change to the controller, telling observers when the preset or Auto changed.
    @discardableResult
    private func updateQuality(_ change: (inout QualityController) -> QualityController.Decision) -> QualityController.Decision {
        var next = quality
        let decision = change(&next)
        if next.preset != quality.preset || next.auto != quality.auto {
            withMutation(keyPath: \.preset) {
                withMutation(keyPath: \.autoQuality) { quality = next }
            }
        } else {
            quality = next
        }
        return decision
    }

    /// Evaluates Auto every `qualityInterval` while this session runs.
    private func startQualityTicker() {
        tickerGeneration += 1
        let generation = tickerGeneration
        let interval = qualityInterval
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard let self, self.tickerGeneration == generation else { return }
                await self.tickQuality()
            }
        }
    }

    private func tickQuality() async {
        guard let session = current else { return }
        qualityTicks += 1
        let (median, backlog) = qualityInputForTesting?() ?? session.qualitySample()
        await evaluateQuality(medianMs: median, backlog: backlog, now: sessionClock.now())
    }

    // MARK: Measure Delay

    /// "Measure Delay…" is offered: a session runs, its control link is there, and none is running.
    public var canMeasureDelay: Bool { phase.isRunning && controlLinked && !measuringDelay }

    /// "Measure Delay…": the phone's DELAY test screen (`mirror.test_pattern`); the trials
    /// (`DelayProbe`: nothing is tapped until the screen's corner marker shows, R56; then a touch at
    /// the centre, wait for white, lift, wait for the idle screen); then, when a tap was answered,
    /// the FPS screen and 30 s of counting decoded frames (from 1 s after it was asked for, so the
    /// DELAY screen's frames don't count); then OFF. Auto pauses meanwhile. Nil when no session runs
    /// or it ends before the measurement is done. Logged as one line of numbers.
    public func measureDelay() async -> DelayResult? {
        guard canMeasureDelay, let session = current else { return nil }
        measuringDelay = true
        defer { measuringDelay = false }
        let id = sessionID
        let harness = delayHarness
        let frames = AsyncStream.makeStream(of: DelayFrame.self, bufferingPolicy: .bufferingNewest(256))
        delayFrames = frames.continuation
        session.observeFrames(Self.delayObserver(frames.continuation))
        await sendTestPattern(.delay, session: id)
        let probe = DelayProbe(tap: { [weak self] down in self?.tapCentre(down) }, frames: { frames.stream },
                               trials: harness.trials, timeout: harness.timeout, pause: harness.pause)
        probe.markerTimeout = harness.markerTimeout
        probe.settle = harness.settle
        var result = await probe.run()
        session.observeFrames(nil)
        frames.continuation.finish()
        delayFrames = nil
        guard current === session else { return nil }
        if result.testScreenOpened, result.misses < result.trials {
            let from = ContinuousClock.now + harness.fpsSettle
            let counter = FrameCounter(from: from)
            session.observeFrames(Self.countingObserver(counter))
            await sendTestPattern(.fps, session: id)
            let end = from + harness.fpsDuration
            while current === session, ContinuousClock.now < end {
                try? await Task.sleep(for: min(.milliseconds(100), harness.fpsDuration))
            }
            session.observeFrames(nil)
            guard current === session else { return nil }
            result = result.with(fpsMean: Double(counter.count) / (LatenessMeter.ms(ContinuousClock.now - from) / 1_000))
        }
        await sendTestPattern(.off, session: id)
        let size = videoSize ?? session.videoSize ?? (0, 0)
        let codecName = codec == .h265 ? "h265" : "h264"
        Self.log.info("delay median \(Int(result.medianMs.rounded()), privacy: .public) p95 \(Int(result.p95Ms.rounded()), privacy: .public) min \(Int(result.minMs.rounded()), privacy: .public) trials \(result.trials, privacy: .public) misses \(result.misses, privacy: .public) fps \(String(format: "%.1f", result.fpsMean), privacy: .public) size \(size.width, privacy: .public)x\(size.height, privacy: .public) preset \(self.quality.preset.name, privacy: .public) codec \(codecName, privacy: .public)")
        return result
    }

    /// The frame observer for the delay trials: built here, nonisolated, as it runs on the decoder's side.
    nonisolated private static func delayObserver(
        _ frames: AsyncStream<DelayFrame>.Continuation
    ) -> @Sendable (CVPixelBuffer, ContinuousClock.Instant) -> Void {
        { image, at in
            frames.yield(DelayFrame(centerLuma: LumaProbe.centerLuma(image), marker: LumaProbe.testScreenMarker(image), at: at))
        }
    }

    /// The frame observer that counts pictures for the frame rate, built nonisolated like `delayObserver`.
    nonisolated private static func countingObserver(_ counter: FrameCounter) -> @Sendable (CVPixelBuffer, ContinuousClock.Instant) -> Void {
        { _, at in counter.add(at: at) }
    }

    /// A touch DOWN or UP at the centre of the current video, on the control link.
    private func tapCentre(_ down: Bool) {
        guard let current, let size = videoSize ?? current.videoSize, size.width > 0, size.height > 0 else { return }
        current.sendControl(ScrcpyControl.touch(
            action: down ? 0 : 1, x: Int32(size.width / 2), y: Int32(size.height / 2),
            width: UInt16(clamping: size.width), height: UInt16(clamping: size.height), pressure: down ? 1 : 0))
    }

    private func sendTestPattern(_ mode: AMTestPatternMode, session id: UInt32) async {
        var pattern = AMMirrorTestPattern()
        pattern.session = id
        pattern.mode = mode
        await send(.mirrorTestPattern, pattern)
    }

    // MARK: files

    /// A drop on the mirror is taken: a session runs and the phone shares `files.v1`.
    public var canDropFiles: Bool { phase.isRunning && sharesFiles }

    /// Hands `urls` to `onDropFiles` when `canDropFiles`; whether they were taken.
    @discardableResult
    public func dropFiles(_ urls: [URL]) -> Bool {
        guard canDropFiles, !urls.isEmpty else { return false }
        Self.log.info("session \(self.sessionID, privacy: .public) dropped \(urls.count, privacy: .public) items")
        onDropFiles?(urls)
        return true
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
            applyScreenOffSetting()
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
        case .audioEnded:
            audioActive = false
        case let .clipboard(text, explicit):
            onPhoneClipboard?(text, explicit)
        case let .linkEnded(role):
            // Audio may end on its own; video or control ending ends the session.
            if role == .mirrorAudio {
                audioActive = false
                return
            }
            guard linkEnd == nil else { return }
            linkEnd = Task { [weak self, linkGrace, graceSleep] in
                try? await graceSleep(linkGrace)
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
        startQualityTicker()
        Self.log.info("session \(self.sessionID, privacy: .public) running \(size.width, privacy: .public)x\(size.height, privacy: .public)")
    }

    /// `screenOffByDefault` after the session's first frame, once its control link is there.
    private func applyScreenOffSetting() {
        guard carriedScreenOff ?? screenOffByDefault, !screenOffSettled, firstFrameSeen, let current, current.hasControlLink else { return }
        setScreenOff(true)
    }

    /// Queues SET_DISPLAY_POWER(on) when the current session's screen is off.
    private func queueScreenOn() {
        guard screenOff, let current else { return }
        screenOff = false
        screenOnQueued = true
        current.sendControl(ScrcpyControl.setDisplayPower(on: true))
        Self.log.info("session \(self.sessionID, privacy: .public) screen on before end")
    }

    /// Before an end from this side: the screen back on, written to the control link (at most
    /// the drain deadline) before anything else goes to the phone.
    private func screenOnBeforeEnd() async {
        guard let session = current else { return }
        queueScreenOn()
        guard screenOnQueued else { return }
        await session.flushControl()
    }

    /// Ends the current session from this side and tells the phone (`mirror.stop`, reason USER).
    /// The session ends here first, so the phone's answer finds nothing to act on. The links close
    /// after the stop has gone (so the phone hears the stop first), or before when `closeFirst`.
    /// A screen that is off goes back on first: SET_DISPLAY_POWER(on) is written before the stop
    /// (when the links close first it is queued ahead of the release, and drained with it).
    private func stopCurrent(_ reason: MirrorEndReason, closeFirst: Bool = false) async {
        stopGeneration += 1
        if closeFirst { queueScreenOn() } else { await screenOnBeforeEnd() }
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
        audioActive = false
        screenOff = false
        screenOnQueued = false
        controlLinked = false
        deadline?.cancel()
        deadline = nil
        linkEnd?.cancel()
        linkEnd = nil
        tickerGeneration += 1
        delayFrames?.finish()
        delayFrames = nil
        if reason == .phone(.linkSlow) {
            updateQuality { $0.linkTooSlow(now: sessionClock.now()); return .keep }
        }
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

/// The waits and counts of "Measure Delay…" (Global Constraints, R56).
struct DelayHarness {
    var trials = 50
    var timeout: Duration = .seconds(3)
    var pause: Duration = .milliseconds(500)
    /// For the test screen's corner marker to show.
    var markerTimeout: Duration = .seconds(5)
    /// The least time from DELAY to the first tap.
    var settle: Duration = .milliseconds(500)
    /// After FPS is asked for, pictures are counted only from this much later.
    var fpsSettle: Duration = .seconds(1)
    var fpsDuration: Duration = .seconds(30)
}

/// Counts pictures decoded from `from` on, from the decoder's side.
private final class FrameCounter: @unchecked Sendable {
    private let from: ContinuousClock.Instant
    private let lock = NSLock()
    private var value = 0

    init(from: ContinuousClock.Instant) { self.from = from }

    func add(at: ContinuousClock.Instant) {
        guard at >= from else { return }
        lock.withLock { value += 1 }
    }

    var count: Int { lock.withLock { value } }
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
