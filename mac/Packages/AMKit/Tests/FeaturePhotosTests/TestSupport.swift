import Foundation

// The shared doubles (FakeBulk, MemoryPipe, SentLog, until, ...) are in AMTestSupport.

/// `id | length | bytes` records as the phone writes them (SPEC section 18).
func record(_ id: Int64, _ jpeg: Data) -> Data {
    var d = Data()
    withUnsafeBytes(of: UInt64(bitPattern: id).bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(jpeg.count).bigEndian) { d.append(contentsOf: $0) }
    d.append(jpeg)
    return d
}

let endRecord = record(0, Data())
