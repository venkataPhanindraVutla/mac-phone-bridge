import AMProtocol
import AVFoundation
import ConnectionCore
import Foundation
import os

/// What a session tells its model. Delivered from the session's read loops and the decoder's
/// side, never on the main thread: the model hops to the main actor itself.
public enum MirrorSessionEvent: Sendable {
    /// The first picture was decoded.
    case firstFrame
    /// A session packet: the video size (it changes on rotation).
    case size(width: Int, height: Int)
    /// A link ended (EOF, an error, or a bad stream such as an oversized packet).
    case linkEnded(AMBulkRole)
    /// The audio path ended while its link stays up: the phone sends no audio (it can't capture,
    /// or failed to), or a stream the Mac can't decode. Video goes on.
    case audioEnded
    /// The decoder dropped to the next key frame (a backlog or a decode error); send RESET_VIDEO.
    /// At most once per second: a request inside the window is deferred to its end, and further
    /// requests before then join it, so the phone is always asked again for a key frame.
    case needsReset
}

/// The clock the RESET_VIDEO throttle reads and schedules on, and the control drain deadline
/// runs on (a fake one in tests).
struct ResetClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var after: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void

    static let system = ResetClock(
        now: { ContinuousClock.now },
        after: { delay, work in
            Task.detached {
                try? await Task.sleep(for: delay)
                work()
            }
        }
    )
}

/// One mirror session's links, parsers and decoders. Every read loop runs off the main actor;
/// pictures go from the decoder to the sink, and sound from the audio decoder to `AudioOutput`,
/// without passing through it. Mirror bytes never go through the app's NotifyWork queue: only
/// `mirror.*` control-channel messages do.
public final class MirrorSession: @unchecked Sendable {
    /// More undecoded packets than this drops to the next key frame (Global Constraints).
    public static let maxBacklog = 30
    /// RESET_VIDEO is asked for at most this often.
    static let resetInterval: Duration = .seconds(1)
    static let readChunk = 262_144
    /// Control messages queued for a slow control link at most.
    static let maxQueuedControl = 512
    /// This many audio packets in a row that decode to nothing end the audio path (a config or
    /// stream the decoder can't use; a codec's start-up delay is a packet or two).
    static let maxAudioDecodeFailures = 50
    /// After `close()`, the control link stays open at most this long for what is still queued
    /// (a release's touch UP) to go out.
    static let controlDrainDeadline: Duration = .milliseconds(200)

    public let id: UInt32
    /// Internal so tests can hold it.
    let decoder: VideoDecoder
    /// The phone's sound; its engine starts with the first buffer played.
    let audioOutput = AudioOutput()
    private let events: @Sendable (MirrorSessionEvent) -> Void
    private let clock: ResetClock
    private let lock = NSLock()

    // Guarded by `lock`.
    private var pipes: [AMBulkRole: any BulkPipe] = [:]
    private var closed = false
    private var size: (width: Int, height: Int)?
    private var sawFirstFrame = false
    private var lastReset: ContinuousClock.Instant?
    /// A deferred RESET_VIDEO is scheduled for the end of the current window.
    private var resetDeferred = false
    private var parsed = 0
    private var control: AsyncStream<Data>.Continuation?
    private var frameHook: (@Sendable (UInt64) -> Void)?
    private var audioDecoded = 0

    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "mirror")

    public convenience init(id: UInt32, sink: any FrameSink, events: @escaping @Sendable (MirrorSessionEvent) -> Void) {
        self.init(id: id, sink: sink, events: events, clock: .system)
    }

    init(id: UInt32, sink: any FrameSink, events: @escaping @Sendable (MirrorSessionEvent) -> Void, clock: ResetClock) {
        self.id = id
        self.events = events
        self.clock = clock
        let relay = Relay()
        decoder = VideoDecoder(sink: sink, onFrame: { relay.session?.frameDecoded($0) })
        decoder.onKeyFrameNeeded = { relay.session?.requestReset() }
        relay.session = self
    }

    /// Starts reading `pipe` for `role` off the main actor. A second link for a role, or a link
    /// after `close()`, is closed.
    public func attach(_ pipe: any BulkPipe, role: AMBulkRole) {
        // Bounded: a stalled link keeps the newest messages (it is ending anyway; the writer drops after an error).
        // Made before the lock and kept with the pipe in one step, so close() always finds both.
        let queue = role == .mirrorControl
            ? AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(Self.maxQueuedControl)) : nil
        let accepted: Bool = lock.withLock {
            guard !closed, pipes[role] == nil, [.mirrorVideo, .mirrorAudio, .mirrorControl].contains(role) else { return false }
            pipes[role] = pipe
            if let queue { control = queue.continuation }
            return true
        }
        guard accepted else {
            pipe.close()
            return
        }
        switch role {
        case .mirrorVideo:
            Task.detached { [self] in await readVideo(pipe) }
        case .mirrorControl:
            guard let stream = queue?.stream else { return }
            let writer = ControlWriter(pipe: pipe)
            Task.detached {
                for await bytes in stream { await writer.send(bytes) }
                // The stream ends only at close(): everything queued has been written (or the
                // link failed), so the link can close now, before the drain deadline.
                pipe.close()
            }
            // Device messages (Task 8 reads them); drained so the phone's side never backs up.
            Task.detached { [self] in await drain(pipe, role: role) }
        default:
            Task.detached { [self] in await readAudio(pipe) }
        }
    }

    /// Queues scrcpy control bytes for the control link, in call order; dropped while there is none.
    public func sendControl(_ bytes: Data) {
        lock.withLock { _ = control?.yield(bytes) }
    }

    /// The last session packet's size.
    public var videoSize: (width: Int, height: Int)? { lock.withLock { size } }

    /// Muted, the audio link stays up and is decoded; the output drops it.
    public var audioMuted: Bool {
        get { audioOutput.muted }
        set { audioOutput.muted = newValue }
    }

    /// Closes the video and audio links at once and stops the decoder. The control link closes
    /// once what is already queued on it has been written (a release's touch UP), or after
    /// `controlDrainDeadline`, whichever comes first; nothing here waits for it. Nothing is
    /// reported after this, and later `sendControl` calls are dropped.
    public func close() {
        let (now, draining, writer): ([any BulkPipe], (any BulkPipe)?, AsyncStream<Data>.Continuation?) = lock.withLock {
            closed = true
            defer {
                pipes = [:]
                control = nil
            }
            let controlPipe = pipes[.mirrorControl]
            return (pipes.filter { $0.key != .mirrorControl }.map(\.value), controlPipe, control)
        }
        writer?.finish()
        for pipe in now { pipe.close() }
        if let draining {
            clock.after(Self.controlDrainDeadline) { draining.close() }
        }
        decoder.invalidate()
        audioOutput.stop()
    }

    /// Media packets parsed so far (internal, for tests).
    var packetsParsed: Int { lock.withLock { parsed } }

    /// Audio packets decoded to sound so far (internal, for tests).
    var audioBuffersDecoded: Int { lock.withLock { audioDecoded } }

    /// Audio buffers the output took to play (internal, for tests: none while muted).
    var audioBuffersAccepted: Int { audioOutput.stats.accepted }

    /// Gets each decoded picture's PTS (internal, for tests).
    var onFrameForTesting: (@Sendable (UInt64) -> Void)? {
        get { lock.withLock { frameHook } }
        set { lock.withLock { frameHook = newValue } }
    }

    // MARK: read loops

    private func readVideo(_ pipe: any BulkPipe) async {
        var parser = VideoStreamParser()
        var codec: ScrcpyCodec?
        reading: do {
            while let data = try await pipe.receive(maximum: Self.readChunk) {
                for event in try parser.push(data) {
                    switch event {
                    case .deviceName:
                        break // content: neither kept nor logged
                    case let .codec(raw):
                        guard let c = ScrcpyCodec(rawValue: raw), c == .h264 || c == .h265 else { break reading }
                        codec = c
                    case let .session(width, height):
                        lock.withLock { size = (width, height) }
                        emit(.size(width: width, height: height))
                    case let .packet(packet):
                        guard let codec else { break reading }
                        video(packet, codec: codec)
                    }
                }
            }
        } catch {
            // EOF, a closed link or a bad stream (`packetTooLarge`): the link has ended.
        }
        ended(pipe, role: .mirrorVideo)
    }

    private func video(_ packet: MediaPacket, codec: ScrcpyCodec) {
        lock.withLock { parsed += 1 }
        decoder.decode(packet, codec: codec)
        if decoder.backlog > Self.maxBacklog {
            decoder.dropUntilKeyFrame()
            requestReset()
        }
    }

    /// Decodes the audio link into `audioOutput`. When the phone sends no audio, audio the Mac
    /// can't decode, or `maxAudioDecodeFailures` packets in a row that decode to nothing, the audio
    /// path ends (`audioEnded`) but the link is kept and drained until the phone closes it, so its
    /// end looks like any other.
    private func readAudio(_ pipe: any BulkPipe) async {
        var parser = AudioStreamParser()
        var codec: ScrcpyCodec?
        var decoder: AudioDecoder?
        var playing = true
        var decodeErrors = 0
        var failuresInARow = 0
        do {
            while let data = try await pipe.receive(maximum: Self.readChunk) {
                guard playing else { continue }
                events: for event in try parser.push(data) {
                    switch event {
                    case let .codec(raw):
                        guard let c = ScrcpyCodec(rawValue: raw), AudioDecoder.supports(c) else {
                            endAudio(playing: &playing, "unsupported codec")
                            break events
                        }
                        codec = c
                        Self.log.info("session \(self.id, privacy: .public) audio codec \(c == .opus ? "opus" : "aac", privacy: .public)")
                    case .unavailable:
                        endAudio(playing: &playing, "unavailable")
                        break events
                    case .failed:
                        // Upstream, the helper exits after code 1, so the session will end through
                        // the video link and the phone's state; until then video goes on.
                        endAudio(playing: &playing, "failed")
                        break events
                    case let .packet(packet):
                        guard let codec else { break }
                        if packet.config || decoder == nil {
                            // The first config packet is the decoder's cookie; a stream with none starts without one.
                            guard let made = try? AudioDecoder(codec: codec, config: packet.config ? packet.payload : Data()) else {
                                endAudio(playing: &playing, "decoder failed")
                                break events
                            }
                            decoder = made
                            if made.cookieStatus != noErr {
                                Self.log.error("session \(self.id, privacy: .public) audio cookie refused, status \(made.cookieStatus, privacy: .public)")
                            }
                            if packet.config { break }
                        }
                        if let pcm = decoder?.decode(packet.payload) {
                            failuresInARow = 0
                            lock.withLock { audioDecoded += 1 }
                            audioOutput.enqueue(pcm)
                        } else {
                            decodeErrors += 1
                            failuresInARow += 1
                            if failuresInARow >= Self.maxAudioDecodeFailures {
                                endAudio(playing: &playing, "decode failing")
                                break events
                            }
                        }
                    }
                }
            }
        } catch {
            // EOF, a closed link or a bad stream: the link has ended.
        }
        audioOutput.stop() // nothing more will come: release the engine now
        if decoder != nil {
            let stats = audioOutput.stats
            Self.log.info("session \(self.id, privacy: .public) audio drops \(stats.drops, privacy: .public) (\(Int(stats.droppedMs), privacy: .public) ms) underruns \(stats.underruns, privacy: .public) decode errors \(decodeErrors, privacy: .public)")
        }
        ended(pipe, role: .mirrorAudio)
    }

    private func endAudio(playing: inout Bool, _ why: StaticString) {
        playing = false
        audioOutput.stop()
        Self.log.info("session \(self.id, privacy: .public) audio ended: \(String(describing: why), privacy: .public)")
        emit(.audioEnded)
    }

    private func drain(_ pipe: any BulkPipe, role: AMBulkRole) async {
        do {
            while try await pipe.receive(maximum: Self.readChunk) != nil {}
        } catch {}
        ended(pipe, role: role)
    }

    private func ended(_ pipe: any BulkPipe, role: AMBulkRole) {
        pipe.close()
        emit(.linkEnded(role))
    }

    // MARK: decoder side

    fileprivate func frameDecoded(_ pts: UInt64) {
        let (first, hook): (Bool, (@Sendable (UInt64) -> Void)?) = lock.withLock {
            defer { sawFirstFrame = true }
            return (!sawFirstFrame, frameHook)
        }
        hook?(pts)
        if first { emit(.firstFrame) }
    }

    /// Asks for RESET_VIDEO: now, or (inside the 1 s window) once at the window's end; requests
    /// made while one is deferred join it. Internal, for tests.
    func requestReset() {
        enum Action { case now, later(Duration), joined }
        let at = clock.now()
        let action: Action = lock.withLock {
            if resetDeferred { return .joined }
            if let lastReset, at - lastReset < Self.resetInterval {
                resetDeferred = true
                return .later(lastReset + Self.resetInterval - at)
            }
            lastReset = at
            return .now
        }
        switch action {
        case .now:
            emit(.needsReset)
        case let .later(delay):
            clock.after(delay) { [weak self] in self?.deferredReset() }
        case .joined:
            break
        }
    }

    private func deferredReset() {
        let at = clock.now()
        lock.withLock {
            resetDeferred = false
            lastReset = at
        }
        emit(.needsReset)
    }

    private func emit(_ event: MirrorSessionEvent) {
        guard !lock.withLock({ closed }) else { return }
        events(event)
    }
}

/// Lets the decoder's callbacks reach the session without the decoder owning it.
private final class Relay: @unchecked Sendable {
    weak var session: MirrorSession?
}
