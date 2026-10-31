import Foundation
import Testing
@testable import FeatureMirror

/// The `device` entries in `scrcpy.json` (helper → Mac).
nonisolated(unsafe) let deviceVectors: [[String: Any]] = scrcpyVectors["device"] as? [[String: Any]] ?? []

/// The named device entry's fields and bytes.
func deviceVector(_ name: String) -> (fields: [String: Any], bytes: Data)? {
    guard let entry = deviceVectors.first(where: { $0["name"] as? String == name }),
          let fields = entry["fields"] as? [String: Any], let hex = entry["hex"] as? String else { return nil }
    return (fields, Data(hex: hex))
}

/// A CLIPBOARD device message: type 0, u32 length, UTF-8.
func deviceClipboardBytes(_ text: String) -> Data {
    var d = Data([0])
    withUnsafeBytes(of: UInt32(text.utf8.count).bigEndian) { d.append(contentsOf: $0) }
    return d + Data(text.utf8)
}

@Suite struct DeviceMessagesTests {
    @Test func limitMatchesTheFixtures() throws {
        let limits = try #require(scrcpyVectors["limits"] as? [String: Any])
        #expect((limits["device_clipboard_text_max_bytes"] as? NSNumber)?.intValue == DeviceMessageParser.clipboardTextMaxBytes)
        #expect(DeviceMessageParser.clipboardTextMaxBytes == 262_139)
    }

    @Test func deviceClipboardParsesFixture() throws {
        for name in ["clipboard_ascii", "clipboard_emoji"] {
            let vector = try #require(deviceVector(name), "missing \(name)")
            #expect(deviceVectors.first { $0["name"] as? String == name }?["verified"] as? Bool == true)
            let text = try #require(vector.fields["text"] as? String)
            var parser = DeviceMessageParser()
            #expect(try parser.push(vector.bytes) == [.clipboard(text)])
        }
        // The emoji fixture is what the helper sends for "été 📋✨".
        var parser = DeviceMessageParser()
        #expect(try parser.push(try #require(deviceVector("clipboard_emoji")).bytes) == [.clipboard("été 📋✨")])
    }

    @Test func ackIsParsed() throws {
        let vector = try #require(deviceVector("ack_clipboard"))
        let sequence = try #require((vector.fields["sequence"] as? NSNumber)?.uint64Value)
        var parser = DeviceMessageParser()
        #expect(try parser.push(vector.bytes) == [.ackClipboard(sequence)])
        #expect(sequence == 4_294_967_298)
    }

    @Test func uhidOutputIsSkipped() throws {
        let uhid = try #require(deviceVector("uhid_output")).bytes
        let ack = try #require(deviceVector("ack_clipboard")).bytes
        let clip = try #require(deviceVector("clipboard_ascii")).bytes
        var parser = DeviceMessageParser()
        #expect(try parser.push(uhid).isEmpty)
        #expect(try parser.push(uhid + ack + uhid + clip) == [.ackClipboard(4_294_967_298), .clipboard("copied on the phone")])
    }

    /// However the bytes are chunked, even one byte at a time, the same messages come out.
    @Test func splitAcrossChunks() throws {
        let all = try #require(deviceVector("clipboard_emoji")).bytes
            + (try #require(deviceVector("uhid_output")).bytes)
            + (try #require(deviceVector("ack_clipboard")).bytes)
            + (try #require(deviceVector("clipboard_ascii")).bytes)
        let expected: [DeviceMessage] = [.clipboard("été 📋✨"), .ackClipboard(4_294_967_298), .clipboard("copied on the phone")]
        for size in [1, 2, 3, 5, 7, 13, all.count] {
            var parser = DeviceMessageParser()
            var out: [DeviceMessage] = []
            var i = 0
            while i < all.count {
                out += try parser.push(all.subdata(in: i..<min(i + size, all.count)))
                i += size
            }
            #expect(out == expected, "chunk size \(size)")
        }
    }

    @Test func clipboardAtTheLimitParses() throws {
        let text = String(repeating: "a", count: DeviceMessageParser.clipboardTextMaxBytes)
        var parser = DeviceMessageParser()
        #expect(try parser.push(deviceClipboardBytes(text)) == [.clipboard(text)])
    }

    /// Longer than the helper ever sends: the stream is broken (and nothing is buffered for it).
    @Test func clipboardOverTheLimitThrows() throws {
        var header = Data([0])
        withUnsafeBytes(of: UInt32(DeviceMessageParser.clipboardTextMaxBytes + 1).bigEndian) { header.append(contentsOf: $0) }
        var parser = DeviceMessageParser()
        #expect(throws: DeviceMessageError.clipboardTooLong) { try parser.push(header) }
    }

    @Test func unknownTypeThrows() throws {
        var parser = DeviceMessageParser()
        #expect(throws: DeviceMessageError.unknownType(9)) { try parser.push(Data([9, 0, 0])) }
    }
}
