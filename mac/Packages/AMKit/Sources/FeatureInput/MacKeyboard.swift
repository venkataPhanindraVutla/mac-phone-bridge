import CoreGraphics

/// What one `input.keycode` (SPEC 23) does on the Mac.
public enum MacKeyAction: Equatable, Sendable {
    /// A key down then up, with these modifier flags.
    case key(CGKeyCode, CGEventFlags)
    /// A media or brightness key (`NX_KEYTYPE_*`), as the built-in keyboard's top row sends.
    case system(Int32)
}

/// The phone's Mac keyboard: key code and modifier bits in, what to post out.
public enum MacKeyboard {
    public static let shift: UInt32 = 1, control: UInt32 = 2, option: UInt32 = 4, command: UInt32 = 8, fn: UInt32 = 16

    /// The top row without fn, like the built-in keyboard. F5 and F6 (dictation, Do Not Disturb)
    /// have no public event, so they stay plain F5 and F6.
    private static let topRow: [UInt32: MacKeyAction] = [
        122: .system(3),                                // F1 brightness down
        120: .system(2),                                // F2 brightness up
        99: .key(160, []),                              // F3 Mission Control
        118: .key(49, .maskCommand),                    // F4 Spotlight (⌘Space)
        98: .system(18),                                // F7 previous
        100: .system(16),                               // F8 play/pause
        101: .system(17),                               // F9 next
        109: .system(7),                                // F10 mute
        103: .system(1),                                // F11 volume down
        111: .system(0),                                // F12 volume up
    ]

    /// Nil for a code outside the virtual key range (the phone is not trusted to send any).
    public static func action(code: UInt32, modifiers: UInt32) -> MacKeyAction? {
        guard code < 128 else { return nil }
        if modifiers & fn == 0, let special = topRow[code] { return special }
        var flags: CGEventFlags = []
        if modifiers & shift != 0 { flags.insert(.maskShift) }
        if modifiers & control != 0 { flags.insert(.maskControl) }
        if modifiers & option != 0 { flags.insert(.maskAlternate) }
        if modifiers & command != 0 { flags.insert(.maskCommand) }
        if modifiers & fn != 0 { flags.insert(.maskSecondaryFn) }
        // The built-in keyboard's arrows always carry fn and keypad, and macOS's own shortcuts
        // (⌃← ⌃→ Spaces, ⌃↑ Mission Control) are stored with them: without them they don't match.
        if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        return .key(CGKeyCode(code), flags)
    }
}
