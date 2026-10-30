import Foundation
import Testing
@testable import FeatureMirror

/// `protocol/vectors/scrcpy.json`, the authority for the scrcpy wire format.
nonisolated(unsafe) let scrcpyVectors: [String: Any] = {
    let url = protocolDir.appendingPathComponent("vectors/scrcpy.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fatalError("cannot load \(url.path)")
    }
    return object
}()

/// The `control` entries (Mac → helper).
nonisolated(unsafe) let controlVectors: [[String: Any]] = scrcpyVectors["control"] as? [[String: Any]] ?? []

/// The named control entry's fields and bytes.
func controlVector(_ name: String) -> (fields: [String: Any], bytes: Data)? {
    guard let entry = controlVectors.first(where: { $0["name"] as? String == name }),
          let fields = entry["fields"] as? [String: Any], let hex = entry["hex"] as? String else { return nil }
    return (fields, Data(hex: hex))
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite struct ScrcpyControlTests {
    /// Every `control` entry in `scrcpy.json`, encoded from its fields, gives its bytes.
    @Test func encodersMatchScrcpyFixtures() throws {
        #expect(controlVectors.count >= 20)
        var covered = 0
        for entry in controlVectors {
            let name = try #require(entry["name"] as? String)
            #expect(entry["verified"] as? Bool == true, "\(name) is not verified")
            let f = try #require(entry["fields"] as? [String: Any])
            let expected = Data(hex: try #require(entry["hex"] as? String))
            let int = { (key: String) -> Int in (f[key] as? NSNumber)?.intValue ?? -1 }
            let float = { (key: String) -> Float in (f[key] as? NSNumber)?.floatValue ?? .nan }
            let encoded: Data
            switch int("type") {
            case 0:
                encoded = ScrcpyControl.keycode(action: UInt8(int("action")), code: Int32(int("keycode")),
                                                repeat: UInt32(int("repeat")), meta: UInt32(int("meta_state")))
            case 1:
                encoded = ScrcpyControl.text(try #require(f["text"] as? String))
            case 2:
                #expect(Int64(int("pointer_id")) == ScrcpyControl.genericFinger)
                #expect(int("action_button") == 0 && int("buttons") == 0)
                encoded = ScrcpyControl.touch(action: UInt8(int("action")), x: Int32(int("x")), y: Int32(int("y")),
                                              width: UInt16(int("width")), height: UInt16(int("height")),
                                              pressure: Float(int("pressure")) / 65535)
            case 3:
                #expect(int("buttons") == 0)
                encoded = ScrcpyControl.scroll(x: Int32(int("x")), y: Int32(int("y")),
                                               width: UInt16(int("width")), height: UInt16(int("height")),
                                               h: float("hscroll"), v: float("vscroll"))
            case 4:
                encoded = ScrcpyControl.backOrScreenOn(action: UInt8(int("action")))
            case 8:
                encoded = ScrcpyControl.getClipboard(copyKey: UInt8(int("copy_key")))
            case 9:
                let sequence = try #require(f["sequence"] as? NSNumber).uint64Value
                encoded = ScrcpyControl.setClipboard(sequence: sequence, paste: f["paste"] as? Bool == true,
                                                     text: try #require(f["text"] as? String))
            case 10:
                encoded = ScrcpyControl.setDisplayPower(on: f["on"] as? Bool == true)
            case 11:
                encoded = ScrcpyControl.rotateDevice()
            case 17:
                encoded = ScrcpyControl.resetVideo()
            default:
                Issue.record("\(name): no encoder for type \(int("type"))")
                continue
            }
            #expect(encoded.hex == expected.hex, "\(name)")
            covered += 1
        }
        #expect(covered == controlVectors.count)
    }

    /// `inject_scroll_fractional`: scroll values are truncated toward zero, not rounded (−0.1 → −204, 0.1 → 204).
    @Test func scrollTruncatesTowardZero() throws {
        let vector = try #require(controlVector("inject_scroll_fractional"))
        #expect((vector.fields["hscroll_i16"] as? NSNumber)?.intValue == -204)
        #expect((vector.fields["vscroll_i16"] as? NSNumber)?.intValue == 204)
        let encoded = ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: -0.1, v: 0.1)
        #expect(encoded == vector.bytes)
        // Rounding would give ±205 (0.1 / 16 × 32768 = 204.8).
        #expect(encoded.subdata(in: 13..<17) == Data([0xFF, 0x34, 0x00, 0xCC]))
    }

    /// The text limits the encoders and the router use are the fixture's.
    @Test func limitsMatchTheFixture() throws {
        let limits = try #require(scrcpyVectors["limits"] as? [String: Any])
        #expect(limits["verified"] as? Bool == true)
        #expect((limits["inject_text_max_bytes"] as? NSNumber)?.intValue == ScrcpyControl.injectTextMaxBytes)
        #expect((limits["set_clipboard_text_max_bytes"] as? NSNumber)?.intValue == ScrcpyControl.setClipboardTextMaxBytes)
        // Anything the Mac sets fits what the phone sends back in a CLIPBOARD message, so it is never cut.
        let device = try #require((limits["device_clipboard_text_max_bytes"] as? NSNumber)?.intValue)
        #expect(ScrcpyControl.setClipboardTextMaxBytes <= device)
    }

    @Test func pressureIsU16FixedPoint() {
        let half = ScrcpyControl.touch(action: 2, x: 0, y: 0, width: 1, height: 1, pressure: 0.5)
        #expect(half.subdata(in: 22..<24) == Data([0x80, 0x00]))
        let over = ScrcpyControl.touch(action: 2, x: 0, y: 0, width: 1, height: 1, pressure: 2)
        #expect(over.subdata(in: 22..<24) == Data([0xFF, 0xFF]))
    }
}
