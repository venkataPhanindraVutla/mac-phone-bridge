import Foundation

// The scrcpy v5.0.1 device messages, helper → Mac on the control socket (SPEC section 24; the
// fixtures are the `device` entries in protocol/vectors/scrcpy.json). Written from the upstream
// wire format; no scrcpy code is used.

/// A message from the helper. UHID_OUTPUT (type 2) is read and skipped.
public enum DeviceMessage: Equatable, Sendable {
    /// The phone's clipboard text (CLIPBOARD, type 0). Content: never logged, nor its size.
    case clipboard(String)
    /// The helper set the clipboard for this SET_CLIPBOARD sequence (ACK_CLIPBOARD, type 1).
    case ackClipboard(UInt64)
}

public enum DeviceMessageError: Error, Equatable {
    /// A type the helper never sends: the stream is out of step.
    case unknownType(UInt8)
    /// A CLIPBOARD longer than the helper ever sends (`DeviceMessageParser.clipboardTextMaxBytes`).
    case clipboardTooLong
}

/// Parses the control socket's helper → Mac bytes incrementally: however the bytes are chunked,
/// the same messages come out. All integers are big endian:
/// - `0` CLIPBOARD: u32 length, then that many bytes of UTF-8;
/// - `1` ACK_CLIPBOARD: u64 sequence;
/// - `2` UHID_OUTPUT: u16 id, u16 size, then that many bytes (skipped).
public struct DeviceMessageParser: Sendable {
    /// The longest CLIPBOARD text the helper sends; it cuts longer clips at a UTF-8 boundary.
    public static let clipboardTextMaxBytes = 262_139

    private var buffer = Data()
    private var head = 0

    public init() {}

    /// The messages completed by `data`. Throws on a type or a length the helper never sends; the
    /// parser is then of no further use.
    public mutating func push(_ data: Data) throws -> [DeviceMessage] {
        buffer.append(data)
        var messages: [DeviceMessage] = []
        var at = head
        defer { compactBuffer(consumed: at) }
        while at < buffer.count {
            let available = buffer.count - at
            switch buffer[at] {
            case 0:
                guard available >= 5 else { return messages }
                let length = Int(number(at + 1, 4))
                guard length <= Self.clipboardTextMaxBytes else { throw DeviceMessageError.clipboardTooLong }
                guard available >= 5 + length else { return messages }
                messages.append(.clipboard(String(decoding: buffer[(at + 5)..<(at + 5 + length)], as: UTF8.self)))
                at += 5 + length
            case 1:
                guard available >= 9 else { return messages }
                messages.append(.ackClipboard(number(at + 1, 8)))
                at += 9
            case 2:
                guard available >= 5 else { return messages }
                let size = Int(number(at + 3, 2))
                guard available >= 5 + size else { return messages }
                at += 5 + size
            case let type:
                throw DeviceMessageError.unknownType(type)
            }
        }
        return messages
    }

    /// `count` bytes from `offset` as a big-endian integer.
    private func number(_ offset: Int, _ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in offset..<(offset + count) { v = v << 8 | UInt64(buffer[i]) }
        return v
    }

    private mutating func compactBuffer(consumed: Int) {
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
}
