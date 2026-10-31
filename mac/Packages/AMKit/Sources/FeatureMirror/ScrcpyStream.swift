import Foundation

// The scrcpy v5.0.1 media streams as the phone relays them (SPEC section 24; the fixtures are in
// protocol/vectors/scrcpy.json). Written from the upstream wire format; no scrcpy code is used.

/// The codec IDs on the scrcpy video and audio sockets (u32 BE, the codec's name in ASCII).
public enum ScrcpyCodec: UInt32, Sendable {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
    case opus = 0x6f70_7573
    case aac = 0x0061_6163
}

/// One media packet: a config packet (the codec's parameter sets) or a frame, in Annex B.
public struct MediaPacket: Equatable, Sendable {
    public var config: Bool
    public var key: Bool
    /// Microseconds, from the phone's encoder clock.
    public var pts: UInt64
    public var payload: Data

    public init(config: Bool, key: Bool, pts: UInt64, payload: Data) {
        self.config = config
        self.key = key
        self.pts = pts
        self.payload = payload
    }
}

/// What the video socket carries, in order: the device name, the codec ID, then session
/// packets (the video size) and media packets.
public enum VideoEvent: Equatable, Sendable {
    /// The phone's name. It is content: never logged.
    case deviceName(String)
    case codec(UInt32)
    case session(width: Int, height: Int)
    case packet(MediaPacket)
}

public enum ScrcpyStreamError: Error, Equatable {
    /// A packet payload over `VideoStreamParser.maxPayloadBytes`; the link ends.
    case packetTooLarge(Int)
    /// A session packet on the audio socket, which has none: the stream is broken.
    case unexpectedSessionPacket
}

/// Parses the video socket's bytes incrementally: however the bytes are chunked, the same
/// events come out. Layout: one dummy byte `0x00` (when `expectDummyByte`), the device name
/// (64 bytes, UTF-8, NUL-padded), the codec ID (u32 BE), then packets with a 12-byte header:
/// - byte 0 bit 7 set: a session packet, bytes 4–7 the width and 8–11 the height, no payload;
/// - otherwise a u64 BE (bit 62 config, bit 61 key frame, the low 61 bits the PTS in µs) and
///   the payload size (u32 BE), then the payload.
public struct VideoStreamParser: Sendable {
    /// The largest payload accepted (16 MiB).
    public static let maxPayloadBytes = 16 << 20
    static let nameBytes = 64
    static let headerBytes = 12

    private enum Stage: Sendable {
        case dummy, name, codec, header
        case payload(config: Bool, key: Bool, pts: UInt64, size: Int)
    }

    private var stage: Stage
    /// Bytes received; those before `head` are consumed. Compacted only once the consumed part is
    /// large, so a big payload arriving in many chunks is not copied again on every push.
    private var buffer = Data()
    private var head = 0

    public init(expectDummyByte: Bool = true) {
        stage = expectDummyByte ? .dummy : .name
    }

    /// The events completed by `data`. Throws `packetTooLarge` for an oversized payload; the
    /// parser is then of no further use.
    public mutating func push(_ data: Data) throws -> [VideoEvent] {
        buffer.append(data)
        var events: [VideoEvent] = []
        var at = head
        defer { compact(&buffer, &head, consumed: at) }
        while true {
            let available = buffer.count - at
            switch stage {
            case .dummy:
                guard available >= 1 else { return events }
                at += 1
                stage = .name
            case .name:
                guard available >= Self.nameBytes else { return events }
                let name = buffer[at..<(at + Self.nameBytes)].prefix { $0 != 0 }
                events.append(.deviceName(String(decoding: name, as: UTF8.self)))
                at += Self.nameBytes
                stage = .codec
            case .codec:
                guard available >= 4 else { return events }
                events.append(.codec(UInt32(bigEndian(buffer, at, 4))))
                at += 4
                stage = .header
            case .header:
                guard available >= Self.headerBytes else { return events }
                if buffer[at] & 0x80 != 0 {
                    events.append(.session(width: Int(bigEndian(buffer, at + 4, 4)), height: Int(bigEndian(buffer, at + 8, 4))))
                    at += Self.headerBytes
                } else {
                    let h = try mediaHeader(buffer, at)
                    at += Self.headerBytes
                    stage = .payload(config: h.config, key: h.key, pts: h.pts, size: h.size)
                }
            case let .payload(config, key, pts, size):
                guard available >= size else { return events }
                let payload = Data(buffer[at..<(at + size)])
                events.append(.packet(MediaPacket(config: config, key: key, pts: pts, payload: payload)))
                at += size
                stage = .header
            }
        }
    }
}

/// What the audio socket carries: the codec ID, then media packets (no session packets). The
/// codec IDs 0 and 1 mean the phone sends no audio: 0 when it can't capture (Android 10, or
/// capture refused), 1 on an error.
public enum AudioEvent: Equatable, Sendable {
    case codec(UInt32)
    /// Codec ID 0: the phone can't capture audio. Nothing follows.
    case unavailable
    /// Codec ID 1: the phone's audio failed. Nothing follows.
    case failed
    case packet(MediaPacket)
}

/// Parses the audio socket's bytes incrementally, like `VideoStreamParser`: the codec ID (u32 BE),
/// then packets with the same 12-byte header (bit 62 config, bit 61 key frame, the low 61 bits the
/// PTS in µs, then the payload size). After `unavailable` or `failed`, further bytes are ignored.
public struct AudioStreamParser: Sendable {
    private enum Stage: Sendable {
        case codec, header, done
        case payload(config: Bool, key: Bool, pts: UInt64, size: Int)
    }

    private var stage = Stage.codec
    private var buffer = Data()
    private var head = 0

    public init() {}

    /// The events completed by `data`. Throws `packetTooLarge` for a payload over
    /// `VideoStreamParser.maxPayloadBytes` and `unexpectedSessionPacket` for a session packet; the
    /// parser is then of no further use.
    public mutating func push(_ data: Data) throws -> [AudioEvent] {
        if case .done = stage { return [] }
        buffer.append(data)
        var events: [AudioEvent] = []
        var at = head
        defer { compact(&buffer, &head, consumed: at) }
        while true {
            let available = buffer.count - at
            switch stage {
            case .done:
                at = buffer.count
                return events
            case .codec:
                guard available >= 4 else { return events }
                let id = UInt32(bigEndian(buffer, at, 4))
                at += 4
                switch id {
                case 0:
                    events.append(.unavailable)
                    stage = .done
                case 1:
                    events.append(.failed)
                    stage = .done
                default:
                    events.append(.codec(id))
                    stage = .header
                }
            case .header:
                guard available >= VideoStreamParser.headerBytes else { return events }
                guard buffer[at] & 0x80 == 0 else { throw ScrcpyStreamError.unexpectedSessionPacket }
                let h = try mediaHeader(buffer, at)
                at += VideoStreamParser.headerBytes
                stage = .payload(config: h.config, key: h.key, pts: h.pts, size: h.size)
            case let .payload(config, key, pts, size):
                guard available >= size else { return events }
                events.append(.packet(MediaPacket(config: config, key: key, pts: pts,
                                                  payload: Data(buffer[at..<(at + size)]))))
                at += size
                stage = .header
            }
        }
    }
}

/// A media packet's 12-byte header at `offset` (bit 63 clear): a u64 BE with bit 62 config, bit 61
/// key frame and the low 61 bits the PTS in µs, then the payload size (u32 BE). Throws
/// `packetTooLarge` for a payload over `VideoStreamParser.maxPayloadBytes`.
private func mediaHeader(_ buffer: Data, _ offset: Int) throws -> (config: Bool, key: Bool, pts: UInt64, size: Int) {
    let head = bigEndian(buffer, offset, 8)
    let size = Int(bigEndian(buffer, offset + 8, 4))
    guard size <= VideoStreamParser.maxPayloadBytes else { throw ScrcpyStreamError.packetTooLarge(size) }
    return (head & (1 << 62) != 0, head & (1 << 61) != 0, head & ((1 << 61) - 1), size)
}

/// Drops the consumed bytes of a parser's buffer: at once when all are consumed, otherwise only
/// once the consumed part is large, so a big payload arriving in many chunks is not copied again
/// on every push.
private func compact(_ buffer: inout Data, _ head: inout Int, consumed: Int) {
    if consumed >= buffer.count {
        buffer = Data()
        head = 0
    } else if consumed >= 65_536 && consumed * 2 >= buffer.count {
        buffer = Data(buffer[consumed...])
        head = 0
    } else {
        head = consumed
    }
}

/// `count` bytes from `offset` as a big-endian integer.
private func bigEndian(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in offset..<(offset + count) { v = v << 8 | UInt64(data[i]) }
    return v
}
