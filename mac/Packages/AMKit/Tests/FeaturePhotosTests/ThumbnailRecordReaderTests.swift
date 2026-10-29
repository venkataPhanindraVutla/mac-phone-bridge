import Foundation
import Testing
@testable import FeaturePhotos

@Test func readerParsesAcrossChunkBoundaries() throws {
    let a = Data([1, 2, 3])
    let b = Data((0..<5000).map { UInt8($0 % 251) })
    let stream = record(30, a) + record(10, b) + record(20, Data()) + record(-2, Data([9])) + endRecord

    // Every chunk size, from one byte at a time up to the whole stream at once.
    for size in [1, 2, 5, 11, 12, 13, 64, 4999, stream.count] {
        var reader = ThumbnailRecordReader()
        var got: [(id: Int64, jpeg: Data)] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + size, stream.count)
            // A slice keeps its parent's indices: the reader must not assume they start at 0.
            got += try reader.append(stream[offset..<end])
            offset = end
        }
        #expect(got.map(\.id) == [30, 10, 20, -2], "chunk size \(size)")
        #expect(got.map(\.jpeg) == [a, b, Data(), Data([9])], "chunk size \(size)")
        #expect(reader.finished)
    }
}

@Test func readerStopsAtTerminator() throws {
    var reader = ThumbnailRecordReader()
    let head = try reader.append(record(1, Data([7])))
    #expect(head.map(\.id) == [1])
    #expect(!reader.finished)

    // The end record, and whatever follows it in the same chunk, ends the stream.
    let rest = try reader.append(endRecord + record(2, Data([8])))
    #expect(rest.isEmpty)
    #expect(reader.finished)
    #expect(try reader.append(record(3, Data([9]))).isEmpty)
    #expect(reader.finished)
}

@Test func readerWaitsForAWholeRecord() throws {
    var reader = ThumbnailRecordReader()
    let r = record(5, Data(repeating: 1, count: 100))
    #expect(try reader.append(r.prefix(11)).isEmpty)
    #expect(try reader.append(r.dropFirst(11).prefix(50)).isEmpty)
    #expect(try reader.append(r.dropFirst(61)).map(\.id) == [5])
    #expect(!reader.finished)
}

@Test func readerRejectsOversizedRecord() throws {
    // A header announcing more than 1 MiB fails at once, before any of the body arrives.
    var reader = ThumbnailRecordReader()
    var header = Data()
    withUnsafeBytes(of: UInt64(7).bigEndian) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(ThumbnailRecordReader.maxRecordBytes + 1).bigEndian) { header.append(contentsOf: $0) }
    #expect(throws: ThumbnailRecordReader.Failure.oversized) { _ = try reader.append(header) }

    // Exactly the limit is still a record (it waits for its bytes).
    var ok = ThumbnailRecordReader()
    var atLimit = Data()
    withUnsafeBytes(of: UInt64(7).bigEndian) { atLimit.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(ThumbnailRecordReader.maxRecordBytes).bigEndian) { atLimit.append(contentsOf: $0) }
    #expect(try ok.append(atLimit).isEmpty)

    // A hostile 4 GiB length cannot make it allocate.
    var hostile = ThumbnailRecordReader()
    #expect(throws: ThumbnailRecordReader.Failure.oversized) {
        _ = try hostile.append(Data(repeating: 0, count: 7) + Data([1]) + Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }
}

@Test func readerRejectsIdZeroWithBytes() throws {
    var reader = ThumbnailRecordReader()
    #expect(throws: ThumbnailRecordReader.Failure.malformed) { _ = try reader.append(record(0, Data([1]))) }
}
