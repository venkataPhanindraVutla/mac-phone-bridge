import Foundation

/// The scrcpy v5.0.1 control messages the Mac sends the helper (SPEC section 24): the type byte,
/// then the fields, all big endian. `protocol/vectors/scrcpy.json` is the authority; every
/// `control` entry there is checked against these encoders.
public enum ScrcpyControl {
    /// The touch pointer: scrcpy's generic finger.
    public static let genericFinger: Int64 = -2
    /// INJECT_TEXT carries at most this many UTF-8 bytes.
    public static let injectTextMaxBytes = 300
    /// SET_CLIPBOARD carries at most this many UTF-8 bytes (the helper's 256 KiB message less 14).
    public static let setClipboardTextMaxBytes = 262_130

    enum Kind: UInt8 {
        case injectKeycode = 0, injectText = 1, injectTouch = 2, injectScroll = 3, backOrScreenOn = 4
        case getClipboard = 8, setClipboard = 9, setDisplayPower = 10, rotateDevice = 11, resetVideo = 17
    }

    /// INJECT_KEYCODE: action (DOWN 0, UP 1), Android key code, repeat count and meta state.
    public static func keycode(action: UInt8, code: Int32, repeat: UInt32 = 0, meta: UInt32 = 0) -> Data {
        var w = Writer(.injectKeycode)
        w.u8(action)
        w.u32(UInt32(bitPattern: code))
        w.u32(`repeat`)
        w.u32(meta)
        return w.data
    }

    /// INJECT_TEXT. Precondition: at most `injectTextMaxBytes` UTF-8 bytes.
    public static func text(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        precondition(bytes.count <= injectTextMaxBytes, "INJECT_TEXT over \(injectTextMaxBytes) bytes")
        var w = Writer(.injectText)
        w.string(bytes)
        return w.data
    }

    /// INJECT_TOUCH_EVENT for the generic finger, with no buttons. `width` and `height` must be the
    /// current video size (the helper drops a touch made for another size). Pressure 0…1 is sent as
    /// u16 fixed point (1.0 = 0xFFFF).
    public static func touch(action: UInt8, x: Int32, y: Int32, width: UInt16, height: UInt16, pressure: Float) -> Data {
        var w = Writer(.injectTouch)
        w.u8(action)
        w.u64(UInt64(bitPattern: genericFinger))
        w.position(x: x, y: y, width: width, height: height)
        w.u16(u16FixedPoint(pressure))
        w.u32(0) // action button
        w.u32(0) // buttons
        return w.data
    }

    /// INJECT_SCROLL_EVENT. `h` and `v` are in scroll units (one wheel notch = 1); on the wire each is
    /// i16 = clamp(v / 16, −1, 1) × 32768, truncated toward zero and clamped to −32768…32767.
    public static func scroll(x: Int32, y: Int32, width: UInt16, height: UInt16, h: Float, v: Float) -> Data {
        var w = Writer(.injectScroll)
        w.position(x: x, y: y, width: width, height: height)
        w.u16(UInt16(bitPattern: i16FixedPoint(h / 16)))
        w.u16(UInt16(bitPattern: i16FixedPoint(v / 16)))
        w.u32(0) // buttons
        return w.data
    }

    /// BACK_OR_SCREEN_ON: action (DOWN 0, UP 1).
    public static func backOrScreenOn(action: UInt8) -> Data {
        var w = Writer(.backOrScreenOn)
        w.u8(action)
        return w.data
    }

    /// GET_CLIPBOARD: copy key 0 none, 1 COPY, 2 CUT.
    public static func getClipboard(copyKey: UInt8) -> Data {
        var w = Writer(.getClipboard)
        w.u8(copyKey)
        return w.data
    }

    /// SET_CLIPBOARD. Precondition: at most `setClipboardTextMaxBytes` UTF-8 bytes.
    public static func setClipboard(sequence: UInt64, paste: Bool, text: String) -> Data {
        let bytes = Data(text.utf8)
        precondition(bytes.count <= setClipboardTextMaxBytes, "SET_CLIPBOARD over \(setClipboardTextMaxBytes) bytes")
        var w = Writer(.setClipboard)
        w.u64(sequence)
        w.u8(paste ? 1 : 0)
        w.string(bytes)
        return w.data
    }

    /// SET_DISPLAY_POWER.
    public static func setDisplayPower(on: Bool) -> Data {
        var w = Writer(.setDisplayPower)
        w.u8(on ? 1 : 0)
        return w.data
    }

    /// ROTATE_DEVICE.
    public static func rotateDevice() -> Data { Writer(.rotateDevice).data }

    /// RESET_VIDEO.
    public static func resetVideo() -> Data { Writer(.resetVideo).data }

    // MARK: fixed point (scrcpy's sc_float_to_u16fp / sc_float_to_i16fp)

    static func u16FixedPoint(_ f: Float) -> UInt16 {
        let scaled = min(max(f.isNaN ? 0 : f, 0), 1) * 65536
        return UInt16(min(scaled, 65535))
    }

    static func i16FixedPoint(_ f: Float) -> Int16 {
        let scaled = min(max(f.isNaN ? 0 : f, -1), 1) * 32768
        return Int16(clamping: Int32(scaled)) // Int32(_:) truncates toward zero
    }

    private struct Writer {
        var data: Data

        init(_ kind: Kind) { data = Data([kind.rawValue]) }

        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }

        mutating func position(x: Int32, y: Int32, width: UInt16, height: UInt16) {
            u32(UInt32(bitPattern: x))
            u32(UInt32(bitPattern: y))
            u16(width)
            u16(height)
        }

        mutating func string(_ bytes: Data) {
            u32(UInt32(bytes.count))
            data.append(bytes)
        }
    }
}
