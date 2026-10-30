import CoreMedia
import Foundation

/// Annex B NAL units and the format descriptions built from a codec's parameter sets.
public enum ParameterSets {
    /// The NAL units of an Annex B buffer, without their start codes (`00 00 01` or
    /// `00 00 00 01`) and trailing zero bytes. Bytes before the first start code are one more
    /// unit, so a buffer with no start code is a single unit.
    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start = 0
        var i = 0
        func emit(_ end: Int) {
            var e = end
            while e > start, bytes[e - 1] == 0 { e -= 1 }
            if e > start { units.append(Data(bytes[start..<e])) }
        }
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                emit(i)
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        emit(bytes.count)
        return units
    }

    /// The NAL unit type: H.264 `nal[0] & 0x1F`, H.265 `(nal[0] >> 1) & 0x3F`.
    static func type(_ nal: Data, _ codec: ScrcpyCodec) -> UInt8? {
        guard let first = nal.first else { return nil }
        return codec == .h265 ? (first >> 1) & 0x3F : first & 0x1F
    }

    /// Whether `nal` is a parameter set (H.264 SPS 7, PPS 8; H.265 VPS 32, SPS 33, PPS 34).
    static func isParameterSet(_ nal: Data, _ codec: ScrcpyCodec) -> Bool {
        guard let t = type(nal, codec) else { return false }
        return codec == .h265 ? (32...34).contains(t) : t == 7 || t == 8
    }

    /// Whether `nal` is an access unit delimiter (H.264 9, H.265 35).
    static func isDelimiter(_ nal: Data, _ codec: ScrcpyCodec) -> Bool {
        type(nal, codec) == (codec == .h265 ? 35 : 9)
    }

    /// The parameter sets among `nals` in the order the format description wants them, or nil
    /// when one is missing: H.264 the first SPS and every PPS; H.265 the first VPS and SPS and every PPS.
    static func ordered(codec: ScrcpyCodec, nals: [Data]) -> [Data]? {
        func all(_ t: UInt8) -> [Data] { nals.filter { type($0, codec) == t } }
        switch codec {
        case .h264:
            guard let sps = all(7).first, !all(8).isEmpty else { return nil }
            return [sps] + all(8)
        case .h265:
            guard let vps = all(32).first, let sps = all(33).first, !all(34).isEmpty else { return nil }
            return [vps, sps] + all(34)
        case .opus, .aac:
            return nil
        }
    }

    /// The format description for `nals`' parameter sets (H.264 SPS/PPS; H.265 VPS/SPS/PPS),
    /// with 4-byte NAL length prefixes; nil when they are missing or don't parse.
    public static func formatDescription(codec: ScrcpyCodec, nals: [Data]) -> CMVideoFormatDescription? {
        guard let sets = ordered(codec: codec, nals: nals) else { return nil }
        // The pointers must stay valid for the call: copy every set into one buffer first.
        let joined = sets.reduce(into: [UInt8]()) { $0 += $1 }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus = joined.withUnsafeBufferPointer { buffer in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(buffer.baseAddress! + offset)
                offset += size
            }
            if codec == .h265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }
}
