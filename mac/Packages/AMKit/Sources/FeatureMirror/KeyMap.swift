import AppKit

/// An Android key press: the key code and its meta state.
public struct KeyStroke: Equatable, Sendable {
    public let code: Int32
    public let meta: UInt32

    public init(code: Int32, meta: UInt32 = 0) {
        self.code = code
        self.meta = meta
    }
}

/// What a ⌘ shortcut in the mirror does.
public enum ShortcutAction: Equatable, Sendable {
    /// ⌘V: the Mac's clipboard is set on the phone and pasted.
    case paste
    /// ⌘C / ⌘X: the phone copies or cuts (its clipboard comes back as a device message).
    case copy, cut
    /// Key presses on the phone (⌘A, ⌘Z, ⌘⇧Z).
    case strokes([KeyStroke])
    /// ⌘W.
    case closeWindow
}

/// Android key codes and meta states (Global Constraints).
enum AndroidKey {
    static let back: Int32 = 4, home: Int32 = 3, appSwitch: Int32 = 187
    static let volumeUp: Int32 = 24, volumeDown: Int32 = 25
    static let enter: Int32 = 66, del: Int32 = 67, forwardDel: Int32 = 112, tab: Int32 = 61, escape: Int32 = 111
    static let dpadUp: Int32 = 19, dpadDown: Int32 = 20, dpadLeft: Int32 = 21, dpadRight: Int32 = 22
    static let pageUp: Int32 = 92, pageDown: Int32 = 93, moveHome: Int32 = 122, moveEnd: Int32 = 123
    static let a: Int32 = 29, z: Int32 = 54

    static let shift: UInt32 = 0x1 | 0x40
    static let ctrl: UInt32 = 0x1000 | 0x2000

    /// Key and motion actions (MOVE is motion only).
    static let down: UInt8 = 0, up: UInt8 = 1, move: UInt8 = 2
}

/// The Mac's text commands and ⌘ shortcuts as Android keys.
public enum KeyMap {
    /// The strokes for a `doCommand(by:)` selector, in order; nil for a command the phone has no key for.
    public static func strokes(for selector: Selector) -> [KeyStroke]? {
        commands[NSStringFromSelector(selector)]
    }

    /// The action for a ⌘ key (`characters` as `charactersIgnoringModifiers`); nil for anything
    /// else, which is left to the Mac's menus and never reaches the phone.
    public static func shortcut(characters: String, modifiers: NSEvent.ModifierFlags) -> ShortcutAction? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch (characters.lowercased(), flags) {
        case ("v", .command): return .paste
        case ("c", .command): return .copy
        case ("x", .command): return .cut
        case ("a", .command): return selectAll
        case ("z", .command): return undo
        case ("z", [.command, .shift]): return redo
        case ("w", .command): return .closeWindow
        default: return nil
        }
    }

    /// ⌘A, ⌘Z and ⌘⇧Z, shared with the Edit menu's actions in the view.
    static let selectAll = ShortcutAction.strokes([KeyStroke(code: AndroidKey.a, meta: AndroidKey.ctrl)])
    static let undo = ShortcutAction.strokes([KeyStroke(code: AndroidKey.z, meta: AndroidKey.ctrl)])
    static let redo = ShortcutAction.strokes([KeyStroke(code: AndroidKey.z, meta: AndroidKey.ctrl | AndroidKey.shift)])

    private static let commands: [String: [KeyStroke]] = {
        typealias K = AndroidKey
        func one(_ code: Int32, _ meta: UInt32 = 0) -> [KeyStroke] { [KeyStroke(code: code, meta: meta)] }
        var table: [String: [KeyStroke]] = [
            "insertNewline:": one(K.enter),
            "insertTab:": one(K.tab),
            "insertBacktab:": one(K.tab, K.shift),
            "deleteBackward:": one(K.del),
            "deleteForward:": one(K.forwardDel),
            "deleteWordBackward:": one(K.del, K.ctrl),
            "deleteToBeginningOfLine:": [KeyStroke(code: K.moveHome, meta: K.shift), KeyStroke(code: K.del)],
            "cancelOperation:": one(K.escape),
            "pageUp:": one(K.pageUp),
            "scrollPageUp:": one(K.pageUp),
            "pageDown:": one(K.pageDown),
            "scrollPageDown:": one(K.pageDown),
            // The Home and End keys: the document's ends.
            "scrollToBeginningOfDocument:": one(K.moveHome, K.ctrl),
            "scrollToEndOfDocument:": one(K.moveEnd, K.ctrl),
        ]
        // Moves, and their `…AndModifySelection:` variants with SHIFT. ⌘←/⌘→ (line ends) and ⌃A/⌃E
        // (paragraph ends) are what the Mac's standard key bindings send for the line moves.
        let moves: [(String, Int32, UInt32)] = [
            ("moveLeft", K.dpadLeft, 0), ("moveRight", K.dpadRight, 0), ("moveUp", K.dpadUp, 0), ("moveDown", K.dpadDown, 0),
            ("moveWordLeft", K.dpadLeft, K.ctrl), ("moveWordRight", K.dpadRight, K.ctrl),
            ("moveToBeginningOfLine", K.moveHome, 0), ("moveToEndOfLine", K.moveEnd, 0),
            ("moveToLeftEndOfLine", K.moveHome, 0), ("moveToRightEndOfLine", K.moveEnd, 0),
            ("moveToBeginningOfParagraph", K.moveHome, 0), ("moveToEndOfParagraph", K.moveEnd, 0),
            ("moveToBeginningOfDocument", K.moveHome, K.ctrl), ("moveToEndOfDocument", K.moveEnd, K.ctrl),
        ]
        for (name, code, meta) in moves {
            table[name + ":"] = one(code, meta)
            table[name + "AndModifySelection:"] = one(code, meta | K.shift)
        }
        return table
    }()
}
