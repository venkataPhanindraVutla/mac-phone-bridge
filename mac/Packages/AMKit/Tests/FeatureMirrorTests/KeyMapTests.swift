import AppKit
import Testing
@testable import FeatureMirror

// Android key codes and meta states (Global Constraints).
let kBack: Int32 = 4, kHome: Int32 = 3, kAppSwitch: Int32 = 187, kVolumeUp: Int32 = 24, kVolumeDown: Int32 = 25
let kEnter: Int32 = 66, kDel: Int32 = 67, kForwardDel: Int32 = 112, kTab: Int32 = 61, kEscape: Int32 = 111
let kUp: Int32 = 19, kDown: Int32 = 20, kLeft: Int32 = 21, kRight: Int32 = 22
let kPageUp: Int32 = 92, kPageDown: Int32 = 93, kMoveHome: Int32 = 122, kMoveEnd: Int32 = 123, kA: Int32 = 29, kZ: Int32 = 54
let mShift: UInt32 = 0x1 | 0x40, mCtrl: UInt32 = 0x1000 | 0x2000

func stroke(_ code: Int32, _ meta: UInt32 = 0) -> KeyStroke { KeyStroke(code: code, meta: meta) }

@Suite struct KeyMapTests {
    /// The brief's whole table, plus the `…AndModifySelection:` variants with SHIFT.
    static let table: [(String, [KeyStroke])] = [
        ("insertNewline:", [stroke(kEnter)]),
        ("insertTab:", [stroke(kTab)]),
        ("insertBacktab:", [stroke(kTab, mShift)]),
        ("deleteBackward:", [stroke(kDel)]),
        ("deleteForward:", [stroke(kForwardDel)]),
        ("deleteWordBackward:", [stroke(kDel, mCtrl)]),
        ("deleteToBeginningOfLine:", [stroke(kMoveHome, mShift), stroke(kDel)]),
        ("moveLeft:", [stroke(kLeft)]),
        ("moveRight:", [stroke(kRight)]),
        ("moveUp:", [stroke(kUp)]),
        ("moveDown:", [stroke(kDown)]),
        ("moveWordLeft:", [stroke(kLeft, mCtrl)]),
        ("moveWordRight:", [stroke(kRight, mCtrl)]),
        ("moveToBeginningOfLine:", [stroke(kMoveHome)]),
        ("moveToEndOfLine:", [stroke(kMoveEnd)]),
        ("moveToBeginningOfDocument:", [stroke(kMoveHome, mCtrl)]),
        ("moveToEndOfDocument:", [stroke(kMoveEnd, mCtrl)]),
        ("moveLeftAndModifySelection:", [stroke(kLeft, mShift)]),
        ("moveRightAndModifySelection:", [stroke(kRight, mShift)]),
        ("moveUpAndModifySelection:", [stroke(kUp, mShift)]),
        ("moveDownAndModifySelection:", [stroke(kDown, mShift)]),
        ("moveWordLeftAndModifySelection:", [stroke(kLeft, mCtrl | mShift)]),
        ("moveWordRightAndModifySelection:", [stroke(kRight, mCtrl | mShift)]),
        ("moveToBeginningOfLineAndModifySelection:", [stroke(kMoveHome, mShift)]),
        ("moveToEndOfLineAndModifySelection:", [stroke(kMoveEnd, mShift)]),
        ("moveToBeginningOfDocumentAndModifySelection:", [stroke(kMoveHome, mCtrl | mShift)]),
        ("moveToEndOfDocumentAndModifySelection:", [stroke(kMoveEnd, mCtrl | mShift)]),
        ("cancelOperation:", [stroke(kEscape)]),
        ("pageUp:", [stroke(kPageUp)]),
        ("scrollPageUp:", [stroke(kPageUp)]),
        ("pageDown:", [stroke(kPageDown)]),
        ("scrollPageDown:", [stroke(kPageDown)]),
    ]

    @Test func selectorsMapToKeycodes() {
        for (name, expected) in Self.table {
            #expect(KeyMap.strokes(for: NSSelectorFromString(name)) == expected, "\(name)")
        }
    }

    /// What the Mac's standard key bindings send for ⌘←/⌘→ (line ends), ⌃A/⌃E (paragraph ends) and
    /// the Home and End keys (document ends), so those keys reach the table's line and document moves.
    @Test func standardBindingAliasesMapToTheSameMoves() {
        let aliases: [(String, [KeyStroke])] = [
            ("moveToLeftEndOfLine:", [stroke(kMoveHome)]),
            ("moveToRightEndOfLine:", [stroke(kMoveEnd)]),
            ("moveToLeftEndOfLineAndModifySelection:", [stroke(kMoveHome, mShift)]),
            ("moveToRightEndOfLineAndModifySelection:", [stroke(kMoveEnd, mShift)]),
            ("moveToBeginningOfParagraph:", [stroke(kMoveHome)]),
            ("moveToEndOfParagraph:", [stroke(kMoveEnd)]),
            ("moveToBeginningOfParagraphAndModifySelection:", [stroke(kMoveHome, mShift)]),
            ("moveToEndOfParagraphAndModifySelection:", [stroke(kMoveEnd, mShift)]),
            ("scrollToBeginningOfDocument:", [stroke(kMoveHome, mCtrl)]),
            ("scrollToEndOfDocument:", [stroke(kMoveEnd, mCtrl)]),
        ]
        for (name, expected) in aliases {
            #expect(KeyMap.strokes(for: NSSelectorFromString(name)) == expected, "\(name)")
        }
    }

    @Test func unknownSelectorsMapToNothing() {
        for name in ["noop:", "transpose:", "complete:", "yank:"] {
            #expect(KeyMap.strokes(for: NSSelectorFromString(name)) == nil, "\(name)")
        }
    }

    @Test func cmdShortcuts() {
        #expect(KeyMap.shortcut(characters: "v", modifiers: .command) == .paste)
        #expect(KeyMap.shortcut(characters: "c", modifiers: .command) == .copy)
        #expect(KeyMap.shortcut(characters: "x", modifiers: .command) == .cut)
        #expect(KeyMap.shortcut(characters: "a", modifiers: .command) == .strokes([stroke(kA, mCtrl)]))
        #expect(KeyMap.shortcut(characters: "z", modifiers: .command) == .strokes([stroke(kZ, mCtrl)]))
        #expect(KeyMap.shortcut(characters: "Z", modifiers: [.command, .shift]) == .strokes([stroke(kZ, mCtrl | mShift)]))
        #expect(KeyMap.shortcut(characters: "z", modifiers: [.command, .shift]) == .strokes([stroke(kZ, mCtrl | mShift)]))
        #expect(KeyMap.shortcut(characters: "w", modifiers: .command) == .closeWindow)
        // Caps Lock, the numeric pad and the function key flags do not change the match.
        #expect(KeyMap.shortcut(characters: "V", modifiers: [.command, .capsLock]) == .paste)
        #expect(KeyMap.shortcut(characters: "w", modifiers: [.command, .function]) == .closeWindow)
    }

    /// Anything else is left to the Mac (its menus: ⌘Q, ⌘H, ⌘M, ⌘, …) and never reaches the phone.
    @Test func otherCmdKeysAreNotForwarded() {
        for c in ["q", "h", "m", ",", "n", "t", "s", "f", "p", "1", "`", " "] {
            #expect(KeyMap.shortcut(characters: c, modifiers: .command) == nil, "⌘\(c)")
        }
        #expect(KeyMap.shortcut(characters: "V", modifiers: [.command, .shift]) == nil)
        #expect(KeyMap.shortcut(characters: "v", modifiers: [.command, .option]) == nil)
        #expect(KeyMap.shortcut(characters: "c", modifiers: [.command, .control]) == nil)
        #expect(KeyMap.shortcut(characters: "w", modifiers: [.command, .option]) == nil)
        #expect(KeyMap.shortcut(characters: "v", modifiers: []) == nil)
        #expect(KeyMap.shortcut(characters: "v", modifiers: .control) == nil)
        #expect(KeyMap.shortcut(characters: "", modifiers: .command) == nil)
    }
}
