import AMProtocol
import AMTestSupport
import AppKit
import ConnectionCore
import Foundation
import Testing
@testable import FeatureMirror

// MARK: expected messages

func touchDown(_ x: Int32, _ y: Int32, _ w: UInt16 = 1080, _ h: UInt16 = 2400) -> Data {
    ScrcpyControl.touch(action: 0, x: x, y: y, width: w, height: h, pressure: 1)
}

func touchMove(_ x: Int32, _ y: Int32, _ w: UInt16 = 1080, _ h: UInt16 = 2400) -> Data {
    ScrcpyControl.touch(action: 2, x: x, y: y, width: w, height: h, pressure: 1)
}

func touchUp(_ x: Int32, _ y: Int32, _ w: UInt16 = 1080, _ h: UInt16 = 2400) -> Data {
    ScrcpyControl.touch(action: 1, x: x, y: y, width: w, height: h, pressure: 0)
}

/// A key's DOWN then UP.
func keyPair(_ code: Int32, _ meta: UInt32 = 0) -> [Data] {
    [ScrcpyControl.keycode(action: 0, code: code, meta: meta), ScrcpyControl.keycode(action: 1, code: code, meta: meta)]
}

/// An InputMapper with a recording `send`, a settable video size (1080 × 2400) and a fake pasteboard.
@MainActor
final class InputRig {
    var sent: [Data] = []
    var size: CGSize? = testVideo
    var pasteboard: String?
    var pastes: [String] = []
    var closes = 0
    var beeps = 0
    private(set) var mapper: InputMapper!

    init() {
        mapper = InputMapper(
            send: { [unowned self] in sent.append($0) },
            videoSize: { [unowned self] in size },
            pasteboardText: { [unowned self] in pasteboard },
            onPasteSent: { [unowned self] in pastes.append($0) },
            closeWindow: { [unowned self] in closes += 1 }
        )
        mapper.beep = { [unowned self] in beeps += 1 }
    }

    /// Clears what was sent so far.
    func reset() { sent = [] }
}

@MainActor
@Suite struct InputMapperTests {
    // MARK: mouse

    @Test func clickSendsDownUp() {
        let rig = InputRig()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.mouseUp(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        #expect(rig.sent == [touchDown(540, 1200), touchUp(540, 1200)])

        // With bars: the same picture point.
        rig.reset()
        rig.mapper.mouseDown(at: CGPoint(x: 250, y: 400), viewSize: letterboxView)
        rig.mapper.mouseUp(at: CGPoint(x: 250, y: 400), viewSize: letterboxView)
        #expect(rig.sent == [touchDown(540, 1200), touchUp(540, 1200)])

        // A down in the bar is ignored, and so is everything until the next down in the picture.
        rig.reset()
        rig.mapper.mouseDown(at: CGPoint(x: 10, y: 400), viewSize: letterboxView)
        rig.mapper.mouseDragged(to: CGPoint(x: 250, y: 400), viewSize: letterboxView)
        rig.mapper.mouseUp(at: CGPoint(x: 250, y: 400), viewSize: letterboxView)
        #expect(rig.sent.isEmpty)
    }

    @Test func dragSendsMoves() {
        let rig = InputRig()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.mouseDragged(to: CGPoint(x: 190, y: 420), viewSize: exactView)
        rig.mapper.mouseDragged(to: CGPoint(x: 200, y: 450), viewSize: exactView)
        rig.mapper.mouseUp(at: CGPoint(x: 200, y: 450), viewSize: exactView)
        #expect(rig.sent == [touchDown(540, 1200), touchMove(570, 1260), touchMove(600, 1350), touchUp(600, 1350)])
    }

    @Test func upOutsidePictureClampsToEdge() {
        let rig = InputRig()
        rig.mapper.mouseDown(at: CGPoint(x: 250, y: 400), viewSize: letterboxView)
        rig.mapper.mouseDragged(to: CGPoint(x: 10, y: 400), viewSize: letterboxView)
        rig.mapper.mouseUp(at: CGPoint(x: 10, y: 900), viewSize: letterboxView)
        #expect(rig.sent == [touchDown(540, 1200), touchMove(0, 1200), touchUp(0, 2399)])
    }

    @Test func rightClickIsBack() {
        let rig = InputRig()
        rig.mapper.rightMouse(down: true)
        rig.mapper.rightMouse(down: false)
        #expect(rig.sent == [Data([4, 0]), Data([4, 1])])
        #expect(rig.sent == [ScrcpyControl.backOrScreenOn(action: 0), ScrcpyControl.backOrScreenOn(action: 1)])
    }

    @Test func middleClickIsHome() {
        let rig = InputRig()
        rig.mapper.middleMouse(down: true)
        rig.mapper.middleMouse(down: false)
        #expect(rig.sent == keyPair(kHome))
    }

    /// Holding the button is a long press: nothing is sent between the DOWN and the UP.
    @Test func holdSendsNothingExtra() async throws {
        let rig = InputRig()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.sent == [touchDown(540, 1200)])
    }

    // MARK: release

    @Test func resignKeyReleasesHeldTouch() throws {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(rig.sent == [touchDown(540, 1200), touchUp(540, 1200)])

        // Losing first responder releases too.
        rig.reset()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        #expect(window.makeFirstResponder(view))
        #expect(window.makeFirstResponder(nil))
        #expect(rig.sent == [touchDown(540, 1200), touchUp(540, 1200)])

        // Another window's resign is not this one's.
        rig.reset()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        #expect(rig.sent == [touchDown(540, 1200)])
    }

    /// The window observers' blocks carry no main-actor isolation (Swift 6: a main-actor closure
    /// called off the main thread traps); a post from another thread still reaches the main actor.
    @Test func releaseObserverPostedOffMainRunsOnTheMainActor() async throws {
        let center = NotificationCenter()
        let window = NSWindow()
        let calls = Recorder<Bool>()
        let tokens = MirrorView.observeRelease(of: window, center: center) {
            MainActor.assertIsolated()
            calls.append(true)
        }
        defer { tokens.forEach(center.removeObserver) }
        nonisolated(unsafe) let posted = window
        DispatchQueue.global().async {
            center.post(name: NSWindow.didResignKeyNotification, object: posted)
            center.post(name: NSWindow.willCloseNotification, object: posted)
        }
        try await until("both seen") { calls.count == 2 }
    }

    @Test func windowCloseReleasesHeldTouch() {
        let rig = InputRig()
        let (window, _) = mirrorWindow(rig)
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.mouseDragged(to: CGPoint(x: 190, y: 420), viewSize: exactView)
        window.close()
        #expect(rig.sent == [touchDown(540, 1200), touchMove(570, 1260), touchUp(570, 1260)])
    }

    @Test func viewRemovalReleasesHeldTouch() {
        let rig = InputRig()
        let (window, _) = mirrorWindow(rig)
        defer { window.close() }
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        window.contentView = NSView()
        #expect(rig.sent == [touchDown(540, 1200), touchUp(540, 1200)])
    }

    /// However a session ends, a finger held in the bound view is lifted and the UP is read off the
    /// control link itself: the model releases while the session is current, and the session
    /// writes what is queued before it closes the control link (R45).
    @Test(arguments: ModelRig.Ending.allCases)
    func sessionEndReleasesHeldTouch(_ ending: ModelRig.Ending) async throws {
        let rig = ModelRig()
        let links = try await rig.running()
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        let mapper = try #require(view.input)
        mapper.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        let down = try await readTouch(links.control)
        #expect(down.hex == touchDown(160, 320, 320, 640).hex)

        let ended = ContinuousClock.now
        await rig.end(ending)
        // Everything up to the Mac's close of the link (EOF): the UP, last (a RESET_VIDEO may come first).
        let rest = Data(try await readAll(links.control, 1 << 20).drop(while: { $0 == 17 }))
        #expect(rest.hex == touchUp(160, 320, 320, 640).hex, "\(ending)")
        // The Mac closed it (well inside readAll's 5 s wait), once the UP had gone.
        #expect(ContinuousClock.now - ended < .seconds(2), "\(ending)")
    }

    /// The release hook is the view's mapper, and runs with the session still current.
    @Test func releaseHookRunsWhileTheSessionIsCurrent() async throws {
        let rig = ModelRig()
        let links = try await rig.running()
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        view.input?.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        #expect(try await readTouch(links.control).hex == touchDown(160, 320, 320, 640).hex)
        rig.model.releaseInput?()
        let up = try await readTouch(links.control)
        #expect(up.hex == touchUp(160, 320, 320, 640).hex)

        for end in ModelRig.Ending.allCases {
            let each = ModelRig()
            let eachLinks = try await each.running()
            var live: [Bool] = []
            each.model.releaseInput = { [unowned model = each.model] in live.append(model.session != nil) }
            await each.end(end)
            #expect(live == [true], "\(end)")
            _ = eachLinks
        }
    }

    @Test func sizeChangeMidDragReleasesFirst() async throws {
        // The mapper: the release after a size change is an UP at the new size (the helper drops a
        // touch whose size is not its current video size), and the drag is over.
        let rig = InputRig()
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.size = CGSize(width: 2400, height: 1080)
        rig.mapper.releaseAll()
        rig.mapper.mouseDragged(to: CGPoint(x: 190, y: 420), viewSize: exactView)
        rig.mapper.mouseUp(at: CGPoint(x: 190, y: 420), viewSize: exactView)
        #expect(rig.sent == [touchDown(540, 1200), touchUp(1200, 540, 2400, 1080)])

        // A drag that finds a new size without the hook releases first and sends no MOVE.
        let lone = InputRig()
        lone.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        lone.size = CGSize(width: 2400, height: 1080)
        lone.mapper.mouseDragged(to: CGPoint(x: 190, y: 420), viewSize: exactView)
        lone.mapper.mouseUp(at: CGPoint(x: 190, y: 420), viewSize: exactView)
        #expect(lone.sent == [touchDown(540, 1200), touchUp(1200, 540, 2400, 1080)])

        // The model: a new size calls the hook after the phase has the new size; the same size does not.
        let model = ModelRig()
        let links = try await model.running()
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(model.model, closeWindow: {})
        let mapper = try #require(view.input)
        mapper.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        let read3 = try await readTouch(links.control)
        #expect(read3.hex == touchDown(160, 320, 320, 640).hex)
        model.model.handle(.size(width: 640, height: 320), session: 1)
        let read4 = try await readTouch(links.control)
        #expect(read4.hex == touchUp(320, 160, 640, 320).hex)

        var phases: [MirrorModel.Phase] = []
        model.model.releaseInput = { [unowned m = model.model] in phases.append(m.phase) }
        model.model.handle(.size(width: 640, height: 320), session: 1)
        #expect(phases.isEmpty)
        model.model.handle(.size(width: 320, height: 640), session: 1)
        #expect(phases == [.running(width: 320, height: 640)])
    }

    @Test func releaseWithoutTouchSendsNothing() {
        let rig = InputRig()
        rig.mapper.releaseAll()
        #expect(rig.sent.isEmpty)
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.mouseUp(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.reset()
        rig.mapper.releaseAll()
        rig.mapper.releaseAll()
        #expect(rig.sent.isEmpty)
    }

    /// A Back or Home button still held when the focus goes is let go too.
    @Test func releaseLetsGoOfHeldButtons() {
        let rig = InputRig()
        rig.mapper.rightMouse(down: true)
        rig.mapper.middleMouse(down: true)
        rig.mapper.releaseAll()
        #expect(rig.sent == [Data([4, 0]), keyPair(kHome)[0], Data([4, 1]), keyPair(kHome)[1]])
        rig.reset()
        rig.mapper.rightMouse(down: false)
        rig.mapper.middleMouse(down: false)
        #expect(rig.sent.isEmpty)
    }

    // MARK: scroll

    /// The Mac's own deltas, after Natural scrolling: content follows the fingers. Vertical keeps the
    /// sign (both positive = towards the top); Android's horizontal axis is the Mac's reversed
    /// (AppKit positive = towards the left edge, AXIS_HSCROLL positive = towards the right).
    @Test func scrollUsesMacDirection() {
        let rig = InputRig()
        rig.mapper.scroll(dx: 0, dy: 24, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.scroll(dx: 0, dy: -24, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.scroll(dx: 24, dy: 0, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.scroll(dx: -24, dy: 0, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        #expect(rig.sent == [
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 0, v: 1),
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 0, v: -1),
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: -1, v: 0),
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 1, v: 0),
        ])
        // At the pointer's video point, clamped to the picture.
        rig.reset()
        rig.mapper.scroll(dx: 0, dy: 1, precise: false, at: CGPoint(x: 10, y: 400), viewSize: letterboxView)
        #expect(rig.sent == [ScrcpyControl.scroll(x: 0, y: 1200, width: 1080, height: 2400, h: 0, v: 1)])
        // Nothing to scroll sends nothing.
        rig.reset()
        rig.mapper.scroll(dx: 0, dy: 0, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        #expect(rig.sent.isEmpty)
    }

    @Test func notchScrollIsOneUnit() {
        let rig = InputRig()
        let at = CGPoint(x: 180, y: 400)
        rig.mapper.scroll(dx: 0, dy: 3.7, precise: false, at: at, viewSize: exactView)
        rig.mapper.scroll(dx: 0, dy: -0.3, precise: false, at: at, viewSize: exactView)
        rig.mapper.scroll(dx: 2, dy: 0, precise: false, at: at, viewSize: exactView)
        #expect(rig.sent == [
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 0, v: 1),
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 0, v: -1),
            ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: -1, v: 0),
        ])
        // One notch on the wire: 1 / 16 × 32768 = 2048.
        #expect(rig.sent[0].subdata(in: 15..<17) == Data([0x08, 0x00]))
    }

    @Test func preciseScrollDividesBy24() {
        let rig = InputRig()
        rig.mapper.scroll(dx: -6, dy: 12, precise: true, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        #expect(rig.sent == [ScrcpyControl.scroll(x: 540, y: 1200, width: 1080, height: 2400, h: 0.25, v: 0.5)])
        // 0.5 / 16 × 32768 = 1024; 0.25 → 512.
        #expect(rig.sent[0].subdata(in: 13..<17) == Data([0x02, 0x00, 0x04, 0x00]))
    }

    // MARK: keys

    @Test func commandsSendStrokes() {
        let rig = InputRig()
        rig.mapper.command(#selector(NSResponder.insertNewline(_:)))
        rig.mapper.command(#selector(NSResponder.deleteToBeginningOfLine(_:)))
        rig.mapper.command(NSSelectorFromString("noop:"))
        #expect(rig.sent == keyPair(kEnter) + keyPair(kMoveHome, mShift) + keyPair(kDel))
    }

    /// Key repeat: every keyDown (repeats included) goes through interpretKeyEvents and is its own
    /// DOWN and UP, with repeat 0.
    @Test func repeatedKeyDownSendsPairEach() throws {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        for isRepeat in [false, true, true] {
            view.keyDown(with: try key("\u{7F}", keyCode: 51, isARepeat: isRepeat, window: window)) // Delete
        }
        #expect(rig.sent == keyPair(kDel) + keyPair(kDel) + keyPair(kDel))
        // A held letter repeats as text, one INJECT_TEXT per event.
        rig.reset()
        for isRepeat in [false, true] {
            view.keyDown(with: try key("a", keyCode: 0, isARepeat: isRepeat, window: window))
        }
        #expect(rig.sent == [ScrcpyControl.text("a"), ScrcpyControl.text("a")])
        // And doCommand(by:) directly, as the input method calls it.
        rig.reset()
        for _ in 0..<2 { view.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        #expect(rig.sent == keyPair(kDel) + keyPair(kDel))
    }

    /// F1–F19 and Help have no binding: AppKit hands them to insertText as private-use characters,
    /// which are never pasted (nor typed).
    @Test func functionKeysSendNothing() throws {
        let rig = InputRig()
        rig.mapper.commit("\u{F708}")
        rig.mapper.commit("\u{F704}\u{F716}\u{F746}")
        #expect(rig.sent.isEmpty)
        #expect(rig.pastes.isEmpty)
        // Through the view, as a key press: F5.
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        view.keyDown(with: try key("\u{F708}", keyCode: 96, window: window))
        view.insertText("\u{F708}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(rig.sent.isEmpty)
        // Mixed with text, the text still goes.
        rig.mapper.commit("a\u{F708}")
        #expect(rig.sent == [ScrcpyControl.text("a")])
    }

    @Test func cmdVPastesMacClipboard() {
        let rig = InputRig()
        rig.pasteboard = "Hi 👋 from the Mac"
        rig.mapper.shortcut(.paste)
        rig.mapper.shortcut(.paste)
        #expect(rig.sent == [
            ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "Hi 👋 from the Mac"),
            ScrcpyControl.setClipboard(sequence: 2, paste: true, text: "Hi 👋 from the Mac"),
        ])
        #expect(rig.pastes == ["Hi 👋 from the Mac", "Hi 👋 from the Mac"])
        // An empty pasteboard sends nothing.
        rig.reset()
        rig.pasteboard = nil
        rig.mapper.shortcut(.paste)
        rig.pasteboard = ""
        rig.mapper.shortcut(.paste)
        #expect(rig.sent.isEmpty)
        #expect(rig.pastes.count == 2)
    }

    @Test func cmdCSendsGetClipboardCopy() {
        let rig = InputRig()
        rig.mapper.shortcut(.copy)
        rig.mapper.shortcut(.cut)
        #expect(rig.sent == [Data([8, 1]), Data([8, 2])])
        rig.reset()
        rig.mapper.shortcut(.strokes([stroke(kA, mCtrl)]))
        #expect(rig.sent == keyPair(kA, mCtrl))
    }

    @Test func cmdWClosesAndIsNotForwarded() throws {
        let rig = InputRig()
        rig.mapper.shortcut(.closeWindow)
        #expect(rig.closes == 1)
        #expect(rig.sent.isEmpty)

        // Through the view: ⌘W is taken (the menus never see it) and closes, sending nothing.
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: try cmdKey("w", window: window)))
        #expect(rig.closes == 2)
        #expect(rig.sent.isEmpty)
        // ⌘V through the view pastes.
        rig.pasteboard = "x"
        #expect(view.performKeyEquivalent(with: try cmdKey("v", window: window)))
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "x")])
    }

    /// Other ⌘ keys go on to the Mac's menus; nothing reaches the phone. Nor does a shortcut when
    /// another view of the window has the focus.
    @Test func otherCmdKeysAreNotForwarded() throws {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        for c in ["q", "h", "m", ",", "n"] {
            #expect(!view.performKeyEquivalent(with: try cmdKey(c, window: window)), "⌘\(c)")
        }
        #expect(!view.performKeyEquivalent(with: try cmdKey("v", modifiers: [.command, .option], window: window)))
        #expect(rig.sent.isEmpty && rig.closes == 0)

        let other = NSTextField()
        window.contentView?.addSubview(other)
        #expect(window.makeFirstResponder(other))
        #expect(!view.performKeyEquivalent(with: try cmdKey("w", window: window)))
        #expect(rig.closes == 0)
    }

    /// With no running session the Edit menu's phone actions are disabled, and only ⌘W is taken
    /// from the keyboard; the rest go on to the (disabled) menus.
    @Test func editActionsAreDisabledWithoutASession() throws {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        let actions = ["paste:", "copy:", "cut:", "selectAll:", "undo:", "redo:"]
        for name in actions {
            let item = NSMenuItem(title: name, action: NSSelectorFromString(name), keyEquivalent: "")
            #expect(view.validateUserInterfaceItem(item), "\(name)")
        }
        #expect(view.performKeyEquivalent(with: try cmdKey("a", window: window)))

        rig.size = nil
        rig.reset()
        for name in actions {
            let item = NSMenuItem(title: name, action: NSSelectorFromString(name), keyEquivalent: "")
            #expect(!view.validateUserInterfaceItem(item), "\(name)")
        }
        for c in ["v", "c", "x", "a", "z"] {
            #expect(!view.performKeyEquivalent(with: try cmdKey(c, window: window)), "⌘\(c)")
        }
        #expect(view.performKeyEquivalent(with: try cmdKey("w", window: window)))
        #expect(rig.closes == 1)
        #expect(rig.sent.isEmpty)
        // Anything else is the view's usual validation.
        let other = NSMenuItem(title: "x", action: #selector(NSResponder.noResponder(for:)), keyEquivalent: "")
        #expect(view.validateUserInterfaceItem(other))
    }

    /// The Edit menu's ⌘A, ⌘Z and ⌘⇧Z send the same strokes as the keys.
    @Test func editMenuActionsMatchTheShortcuts() {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        view.selectAll(nil)
        view.undo(nil)
        view.redo(nil)
        #expect(rig.sent == keyPair(kA, mCtrl) + keyPair(kZ, mCtrl) + keyPair(kZ, mCtrl | mShift))
        #expect(KeyMap.shortcut(characters: "a", modifiers: .command) == KeyMap.selectAll)
        #expect(KeyMap.shortcut(characters: "z", modifiers: .command) == KeyMap.undo)
        #expect(KeyMap.shortcut(characters: "Z", modifiers: [.command, .shift]) == KeyMap.redo)
    }

    @Test func pasteOverLimitIsRefused() {
        let rig = InputRig()
        rig.pasteboard = String(repeating: "a", count: ScrcpyControl.setClipboardTextMaxBytes + 1)
        rig.mapper.shortcut(.paste)
        #expect(rig.sent.isEmpty)
        #expect(rig.pastes.isEmpty)
        #expect(rig.beeps == 1)
        // The limit is in UTF-8 bytes: 65,533 four-byte emoji are 262,132 bytes.
        rig.pasteboard = String(repeating: "😀", count: 65_533)
        rig.mapper.shortcut(.paste)
        #expect(rig.sent.isEmpty && rig.beeps == 2)
        // Exactly at the limit goes.
        let most = String(repeating: "a", count: ScrcpyControl.setClipboardTextMaxBytes)
        rig.pasteboard = most
        rig.mapper.shortcut(.paste)
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 1, paste: true, text: most)])
        #expect(rig.beeps == 2)
    }

    // MARK: text

    @Test func markedTextIsNotSent() {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
        #expect(view.markedOverlayText == "か")
        #expect(rig.sent.isEmpty)
        // The input method commits: the committed text goes, the composition is gone.
        view.insertText("家", replacementRange: none)
        #expect(!view.hasMarkedText())
        #expect(view.markedOverlayText == nil)
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "家")])

        // unmarkText commits what is marked.
        rig.reset()
        view.setMarkedText(NSAttributedString(string: "é"), selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.unmarkText()
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 2, paste: true, text: "é")])
        // Clearing the composition (backspace to nothing) sends nothing.
        rig.reset()
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        #expect(!view.hasMarkedText())
        view.unmarkText()
        #expect(rig.sent.isEmpty)
        // Losing the focus mid-composition drops it, unsent.
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(window.makeFirstResponder(view))
        #expect(window.makeFirstResponder(nil))
        #expect(!view.hasMarkedText())
        view.unmarkText()
        #expect(rig.sent.isEmpty)
        // The input method's candidate window goes by the overlay, in screen coordinates.
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(rect.width > 0 && rect.height > 0)
        #expect(window.frame.insetBy(dx: -1, dy: -1).contains(rect))
    }

    /// Press-and-hold accents: "é" replaces the "e" already sent, so the phone deletes it first.
    /// A replacement inside a composition deletes nothing (the composition was never sent).
    @Test func replacementRangeDeletesWhatWasSent() {
        let rig = InputRig()
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        view.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        #expect(rig.sent == [ScrcpyControl.text("e")] + keyPair(kDel)
            + [ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "é")])

        rig.reset()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("家", replacementRange: NSRange(location: 0, length: 1))
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 2, paste: true, text: "家")])

        // At most 32 deletions, whatever the range says.
        rig.reset()
        view.insertText("x", replacementRange: NSRange(location: 0, length: 500))
        #expect(rig.sent == Array(repeating: keyPair(kDel), count: 32).flatMap { $0 } + [ScrcpyControl.text("x")])
    }

    @Test func asciiGoesAsInjectText() {
        let rig = InputRig()
        rig.mapper.commit("hello")
        #expect(rig.sent == [ScrcpyControl.text("hello")])
        #expect(rig.sent == [Data(hex: "010000000568656c6c6f")])
        #expect(rig.pastes.isEmpty)
        // Through the view's insertText.
        let (window, view) = mirrorWindow(rig)
        defer { window.close() }
        rig.reset()
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(rig.sent == [ScrcpyControl.text("a")])
    }

    @Test func emojiGoesAsClipboardPaste() {
        let rig = InputRig()
        rig.mapper.commit("👋🏽")
        #expect(rig.sent == [ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "👋🏽")])
        #expect(rig.pastes == ["👋🏽"])
    }

    @Test func nonLatinGoesAsPaste() {
        let rig = InputRig()
        rig.mapper.commit("привет")
        rig.mapper.commit("ok")
        rig.mapper.commit("日本")
        #expect(rig.sent == [
            ScrcpyControl.setClipboard(sequence: 1, paste: true, text: "привет"),
            ScrcpyControl.text("ok"),
            ScrcpyControl.setClipboard(sequence: 2, paste: true, text: "日本"),
        ])
        #expect(rig.pastes == ["привет", "日本"])
    }

    @Test func longTextSplitsAt300BytesOnScalarBoundary() {
        let rig = InputRig()
        let text = String(repeating: "0123456789", count: 65)
        rig.mapper.commit(text)
        #expect(rig.sent == [
            ScrcpyControl.text(String(text.prefix(300))),
            ScrcpyControl.text(String(text.dropFirst(300).prefix(300))),
            ScrcpyControl.text(String(text.suffix(50))),
        ])
    }

    // MARK: toolbar

    @Test func toolbarKeysSendExpectedMessages() {
        let rig = InputRig()
        rig.mapper.button(.back)
        #expect(rig.sent == [Data([4, 0]), Data([4, 1])])
        rig.reset()
        rig.mapper.button(.home)
        rig.mapper.button(.recents)
        rig.mapper.button(.volumeDown)
        rig.mapper.button(.volumeUp)
        #expect(rig.sent == keyPair(kHome) + keyPair(kAppSwitch) + keyPair(kVolumeDown) + keyPair(kVolumeUp))
        rig.reset()
        rig.mapper.button(.rotate)
        #expect(rig.sent == [Data([11])])
    }

    // MARK: not running

    /// With no running session (no video size) nothing is sent; ⌘W still closes the window.
    @Test func nothingIsSentWithoutARunningSession() {
        let rig = InputRig()
        rig.size = nil
        rig.pasteboard = "x"
        rig.mapper.mouseDown(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.mouseUp(at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.rightMouse(down: true)
        rig.mapper.rightMouse(down: false)
        rig.mapper.middleMouse(down: true)
        rig.mapper.scroll(dx: 0, dy: 1, precise: false, at: CGPoint(x: 180, y: 400), viewSize: exactView)
        rig.mapper.commit("hi")
        rig.mapper.commit("日本")
        rig.mapper.command(#selector(NSResponder.insertNewline(_:)))
        rig.mapper.shortcut(.paste)
        rig.mapper.shortcut(.copy)
        rig.mapper.button(.home)
        rig.mapper.releaseAll()
        #expect(rig.sent.isEmpty)
        #expect(rig.pastes.isEmpty)
        rig.mapper.shortcut(.closeWindow)
        #expect(rig.closes == 1)
    }
}

// MARK: helpers

/// A window whose content is a mirror view driven by `rig`'s mapper, with the view focused.
@MainActor
func mirrorWindow(_ rig: InputRig) -> (NSWindow, MirrorView) {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: exactView.width, height: exactView.height),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = MirrorView(frame: NSRect(origin: .zero, size: exactView))
    view.input = rig.mapper
    window.contentView = view
    _ = window.makeFirstResponder(view)
    return (window, view)
}

@MainActor
func key(_ c: String, keyCode: UInt16, isARepeat: Bool = false, window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: c,
                                  charactersIgnoringModifiers: c, isARepeat: isARepeat, keyCode: keyCode))
}

@MainActor
func cmdKey(_ c: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: c,
                                  charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0))
}

/// The next touch message on the control link's phone end, past any RESET_VIDEO the decoder asked for.
func readTouch(_ pipe: MemoryPipe) async throws -> Data {
    var bytes = Data()
    while bytes.count < 32 {
        let more = try await readAll(pipe, 32 - bytes.count)
        guard !more.isEmpty else { break }
        bytes = Data((bytes + more).drop(while: { $0 == 17 }))
    }
    return bytes
}

/// A model with a fake bulk listener and a running session on the canned 320 × 640 sample.
@MainActor
final class ModelRig {
    let bulk = FakeBulk()
    let model: MirrorModel

    enum Ending: CaseIterable, Sendable { case userStop, phoneStop, phoneFailed, disconnect, sleep, replaced }

    init() {
        model = MirrorModel(bulk: bulk, send: { _, _ in }, makeSink: { CountingSink() })
    }

    /// Running, with both links held open; returns their phone ends.
    func running() async throws -> (video: MemoryPipe, control: MemoryPipe) {
        await model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: ["mirror.v1"])
        var a = AMFeatureAvailability()
        a.enabled = true
        await model.message(envelope(.mirror, .mirrorAvailability, a))
        await model.start()
        let id = model.sessionID
        let (videoMac, videoPhone) = MemoryPipe.pair()
        model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-\(id)"))
        let (controlMac, controlPhone) = MemoryPipe.pair()
        model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-\(id)"))
        var s = AMMirrorState()
        s.session = id
        s.phase = .running
        await model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { [model] in model.phase == .running(width: 320, height: 640) }
        return (videoPhone, controlPhone)
    }

    func end(_ ending: Ending) async {
        switch ending {
        case .userStop:
            await model.stop()
        case .phoneStop:
            var s = AMMirrorStop()
            s.session = model.sessionID
            s.reason = .linkFailed
            await model.message(envelope(.mirror, .mirrorStop, s))
        case .phoneFailed:
            var s = AMMirrorState()
            s.session = model.sessionID
            s.phase = .failed
            s.reason = .helperFailed
            await model.message(envelope(.mirror, .mirrorState, s))
        case .disconnect:
            model.disconnected()
        case .sleep:
            model.macWillSleepNow()
        case .replaced:
            await model.start()
        }
    }
}
