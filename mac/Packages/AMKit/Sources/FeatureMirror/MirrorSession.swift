import AMProtocol
import ConnectionCore
import Foundation

/// What a session tells its model. Delivered from the session's read loops and the decoder's
/// side, never on the main thread: the model hops to the main actor itself.
public enum MirrorSessionEvent: Sendable {
    /// The first picture was decoded.
    case firstFrame
    /// A session packet: the video size (it changes on rotation).
    case size(width: Int, height: Int)
    /// A link ended (EOF, an error, or a bad stream such as an oversized packet).
    case linkEnded(AMBulkRole)
    /// The decoder fell behind and dropped to the next key frame; send RESET_VIDEO. At most once per second.
    case needsReset
}

/// One mirror session's links, parsers and decoder. Every read loop runs off the main actor;
/// pictures go from the decoder to the sink without passing through it. Mirror bytes never go
/// through the app's NotifyWork queue: only `mirror.*` control-channel messages do.
public final class MirrorSession: @unchecked Sendable {
    /// More undecoded packets than this drops to the next key frame (Global Constraints).
    public static let maxBacklog = 30
    /// RESET_VIDEO is asked for at most this often.
    static let resetInterval: Duration = .seconds(1)
    static let readChunk = 262_144

    public let id: UInt32
    /// Internal so tests can hold it.
    let decoder: VideoDecoder
    private let events: @Sendable (MirrorSessionEvent) -> Void
    private let lock = NSLock()

    // Guarded by `lock`.
    private var pipes: [AMBulkRole: any BulkPipe] = [:]
    private var closed = false
    private var size: (width: Int, height: Int)?
    private var sawFirstFrame = false
    private var lastReset: ContinuousClock.Instant?
    private var parsed = 0
    private var control: AsyncStream<Data>.Continuation?
    private var frameHook: (@Sendable (UInt64) -> Void)?

    public init(id: UInt32, sink: any FrameSink, events: @escaping @Sendable (MirrorSessionEvent) -> Void) {
        self.id = id
        self.events = events
        let relay = Relay()
        decoder = VideoDecoder(sink: sink, onFrame: { relay.session?.frameDecoded($0) })
        decoder.onKeyFrameNeeded = { relay.session?.requestReset() }
        relay.session = self
    }

    /// Starts reading `pipe` for `role` off the main actor. A second link for a role, or a link
    /// after `close()`, is closed.
    public func attach(_ pipe: any BulkPipe, role: AMBulkRole) {
        let accepted: Bool = lock.withLock {
            guard !closed, pipes[role] == nil, [.mirrorVideo, .mirrorAudio, .mirrorControl].contains(role) else { return false }
            pipes[role] = pipe
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
            let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
            lock.withLock { control = continuation }
            let writer = ControlWriter(pipe: pipe)
            Task.detached {
                for await bytes in stream { await writer.send(bytes) }
            }
            // Device messages (Task 8 reads them); drained so the phone's side never backs up.
            Task.detached { [self] in await drain(pipe, role: role) }
        default:
            // Audio is not played yet (Task 7): drained and discarded.
            Task.detached { [self] in await drain(pipe, role: role) }
        }
    }

    /// Queues scrcpy control bytes for the control link, in call order; dropped while there is none.
    public func sendControl(_ bytes: Data) {
        lock.withLock { _ = control?.yield(bytes) }
    }

    /// The last session packet's size.
    public var videoSize: (width: Int, height: Int)? { lock.withLock { size } }

    /// Closes every link and stops the decoder. Nothing is reported after this.
    public func close() {
        let (open, writer): ([any BulkPipe], AsyncStream<Data>.Continuation?) = lock.withLock {
            closed = true
            defer {
                pipes = [:]
                control = nil
            }
            return (Array(pipes.values), control)
        }
        writer?.finish()
        for pipe in open { pipe.close() }
        decoder.invalidate()
    }

    /// Media packets parsed so far (internal, for tests).
    var packetsParsed: Int { lock.withLock { parsed } }

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

    fileprivate func requestReset() {
        let now = ContinuousClock.now
        let due: Bool = lock.withLock {
            if let lastReset, now - lastReset < Self.resetInterval { return false }
            lastReset = now
            return true
        }
        if due { emit(.needsReset) }
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
