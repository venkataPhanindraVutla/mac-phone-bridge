import Foundation

/// Reads the `photos.thumbs` bulk stream (SPEC section 18): records of
/// `uint64_be id | uint32_be length | JPEG`, in any chunking, up to the end record
/// (`id = 0, length = 0`). Anything after the end record is ignored.
public struct ThumbnailRecordReader {
    public enum Failure: Error, Equatable {
        /// A record announced more than `maxRecordBytes` (thumbnails are at most 64 KB).
        case oversized
        /// A record with ID 0 that is not the end record.
        case malformed
    }

    /// The largest record body taken; SPEC section 18 makes anything longer an error. The check
    /// runs on the header, so a hostile length never makes the reader wait for, or hold, more.
    public static let maxRecordBytes = 1 << 20
    static let headerBytes = 12

    /// Bytes of a record not yet complete; never more than one header plus one record body.
    private var pending = Data()
    /// The end record has been read.
    public private(set) var finished = false

    public init() {}

    /// Feeds the next chunk; returns the records it completes, in stream order (an empty `jpeg`
    /// means the phone has no thumbnail for that ID). Throws on an oversized or malformed record;
    /// the stream should then be dropped.
    public mutating func append(_ d: Data) throws -> [(id: Int64, jpeg: Data)] {
        guard !finished else { return [] }
        pending.append(d)
        var records: [(id: Int64, jpeg: Data)] = []
        var at = pending.startIndex
        while pending.endIndex - at >= Self.headerBytes {
            let id = Int64(bitPattern: Self.uint64(pending, at))
            let length = Int(Self.uint32(pending, at + 8))
            guard length <= Self.maxRecordBytes else { throw Failure.oversized }
            if id == 0 {
                guard length == 0 else { throw Failure.malformed }
                finished = true
                pending = Data()
                return records
            }
            let body = at + Self.headerBytes
            guard pending.endIndex - body >= length else { break }
            records.append((id, Data(pending[body..<(body + length)])))
            at = body + length
        }
        pending = Data(pending[at...])
        return records
    }

    private static func uint64(_ d: Data, _ at: Data.Index) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(d[at + $1]) }
    }

    private static func uint32(_ d: Data, _ at: Data.Index) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(d[at + $1]) }
    }
}
