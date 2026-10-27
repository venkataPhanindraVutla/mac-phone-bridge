import Foundation
import SwiftProtobuf

public enum ProtocolError: Error, Equatable, Sendable {
    case emptyFrame
    case frameTooLarge(Int)
    case malformed
}

/// Length-prefixed framing: 4-byte big-endian length, then the Envelope bytes.
public enum Frame {
    public static let maxBytes = 1_048_576

    public static func encode(_ envelope: AMEnvelope) throws -> Data {
        let body: Data
        do { body = try envelope.serializedData() } catch { throw ProtocolError.malformed }
        guard !body.isEmpty else { throw ProtocolError.emptyFrame }
        guard body.count <= maxBytes else { throw ProtocolError.frameTooLarge(body.count) }
        var out = Data(capacity: 4 + body.count)
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(body)
        return out
    }
}

/// Incremental decoder: feed bytes with `append`, pull envelopes with `next`.
/// After `next` throws, the connection must be closed; the decoder is not reusable.
public struct FrameDecoder: Sendable {
    private var buffer = [UInt8]()
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(contentsOf: bytes)
    }

    public mutating func next() throws -> AMEnvelope? {
        let available = buffer.count - start
        guard available >= 4 else { return nil }
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        // Judge the header alone: never wait for (or buffer) an oversized body.
        if length == 0 { throw ProtocolError.emptyFrame }
        if length > Frame.maxBytes { throw ProtocolError.frameTooLarge(length) }
        guard available >= 4 + length else { return nil }
        let body = Data(buffer[(start + 4)..<(start + 4 + length)])
        start += 4 + length
        if start > 4096 && start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        do { return try AMEnvelope(serializedBytes: body) } catch { throw ProtocolError.malformed }
    }
}
