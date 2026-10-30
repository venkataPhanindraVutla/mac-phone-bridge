import AppKit
import Foundation

/// The mirror window's toolbar keys.
public enum ToolbarKey: Sendable { case back, home, recents, rotate, volumeDown, volumeUp }

/// Turns the Mac's mouse, scroll, keys and text in the mirror view into scrcpy control messages.
///
/// Nothing is sent while there is no running session (`videoSize()` is nil), except the release of
/// something already held. A finger, Back (right button) or Home (middle button) that is down is
/// always let go: `releaseAll()` runs on resign key, window close, view removal, session end or
/// restart, and a video size change. Typed and pasted text is never logged.
@MainActor
public final class InputMapper {
    private let send: (Data) -> Void
    private let videoSize: () -> CGSize?
    private let pasteboardText: () -> String?
    private let onPasteSent: (String) -> Void
    private let closeWindow: () -> Void
    /// Refusing an over-long paste (internal, for tests).
    var beep: () -> Void = { NSSound.beep() }

    /// The finger that is down: its last video point and the video size it was sent for.
    private var finger: (point: (x: Int32, y: Int32), size: CGSize)?
    private var backHeld = false
    private var homeHeld = false
    /// SET_CLIPBOARD sequence numbers, from 1 (0 asks for no acknowledgement).
    private var sequence: UInt64 = 0

    /// A trackpad's points per scroll unit.
    static let pointsPerScrollUnit: CGFloat = 24

    public init(send: @escaping (Data) -> Void, videoSize: @escaping () -> CGSize?, pasteboardText: @escaping () -> String?,
                onPasteSent: @escaping (String) -> Void, closeWindow: @escaping () -> Void) {
        self.send = send
        self.videoSize = videoSize
        self.pasteboardText = pasteboardText
        self.onPasteSent = onPasteSent
        self.closeWindow = closeWindow
    }

    // MARK: mouse

    /// A left down inside the picture puts the finger down; outside it is ignored.
    public func mouseDown(at p: CGPoint, viewSize: CGSize) {
        guard finger == nil, let video = currentVideo(),
              let point = MirrorGeometry.videoPoint(p, viewSize: viewSize, video: video, clamp: false) else { return }
        finger = (point, video)
        touch(AndroidKey.down, point, video, pressure: 1)
    }

    /// Moves the finger, clamped to the picture's edge.
    public func mouseDragged(to p: CGPoint, viewSize: CGSize) {
        guard let held = finger else { return }
        guard let video = currentVideo(), video == held.size,
              let point = MirrorGeometry.videoPoint(p, viewSize: viewSize, video: video, clamp: true) else {
            releaseAll()
            return
        }
        finger = (point, video)
        touch(AndroidKey.move, point, video, pressure: 1)
    }

    /// Lifts the finger, clamped to the picture's edge.
    public func mouseUp(at p: CGPoint, viewSize: CGSize) {
        guard let held = finger else { return }
        guard let video = currentVideo(), video == held.size,
              let point = MirrorGeometry.videoPoint(p, viewSize: viewSize, video: video, clamp: true) else {
            releaseAll()
            return
        }
        finger = nil
        touch(AndroidKey.up, point, video, pressure: 0)
    }

    /// The right button is Back (or turns the screen on).
    public func rightMouse(down: Bool) {
        if down {
            guard !backHeld, active else { return }
            backHeld = true
            send(ScrcpyControl.backOrScreenOn(action: AndroidKey.down))
        } else {
            guard backHeld else { return }
            backHeld = false
            send(ScrcpyControl.backOrScreenOn(action: AndroidKey.up))
        }
    }

    /// The middle button is Home.
    public func middleMouse(down: Bool) {
        if down {
            guard !homeHeld, active else { return }
            homeHeld = true
            send(ScrcpyControl.keycode(action: AndroidKey.down, code: AndroidKey.home))
        } else {
            guard homeHeld else { return }
            homeHeld = false
            send(ScrcpyControl.keycode(action: AndroidKey.up, code: AndroidKey.home))
        }
    }

    /// A scroll at the pointer's video point (clamped). Precise (trackpad) deltas are divided by 24;
    /// a wheel notch is one unit. The deltas are the Mac's own, after Natural scrolling, so content
    /// moves as it does on the Mac: vertical keeps the sign (both mean "towards the top"), and
    /// horizontal is reversed, because AppKit's positive X is towards the left edge and Android's
    /// AXIS_HSCROLL towards the right (as scrcpy's own client gets it from SDL).
    public func scroll(dx: CGFloat, dy: CGFloat, precise: Bool, at p: CGPoint, viewSize: CGSize) {
        let h = precise ? -dx / Self.pointsPerScrollUnit : -notch(dx)
        let v = precise ? dy / Self.pointsPerScrollUnit : notch(dy)
        guard h != 0 || v != 0, h.isFinite, v.isFinite, let video = currentVideo(),
              let point = MirrorGeometry.videoPoint(p, viewSize: viewSize, video: video, clamp: true),
              let size = wire(video) else { return }
        send(ScrcpyControl.scroll(x: point.x, y: point.y, width: size.width, height: size.height, h: Float(h), v: Float(v)))
    }

    // MARK: keys and text

    /// Text the input method committed: printable ASCII is typed, anything else is pasted.
    public func commit(_ text: String) {
        guard active else { return }
        for route in TextRouter.route(text) {
            switch route {
            case let .inject(chunk): send(ScrcpyControl.text(chunk))
            case let .paste(whole): paste(whole)
            }
        }
    }

    /// A `doCommand(by:)` selector: each stroke as DOWN then UP (every key event, repeats included).
    public func command(_ selector: Selector) {
        guard active, let strokes = KeyMap.strokes(for: selector) else { return }
        press(strokes)
    }

    public func shortcut(_ action: ShortcutAction) {
        if action == .closeWindow {
            closeWindow()
            return
        }
        guard active else { return }
        switch action {
        case .paste:
            guard let text = pasteboardText(), !text.isEmpty else { return }
            paste(text)
        case .copy:
            send(ScrcpyControl.getClipboard(copyKey: 1))
        case .cut:
            send(ScrcpyControl.getClipboard(copyKey: 2))
        case let .strokes(strokes):
            press(strokes)
        case .closeWindow:
            break
        }
    }

    public func button(_ b: ToolbarKey) {
        guard active else { return }
        switch b {
        case .back:
            send(ScrcpyControl.backOrScreenOn(action: AndroidKey.down))
            send(ScrcpyControl.backOrScreenOn(action: AndroidKey.up))
        case .home: press([KeyStroke(code: AndroidKey.home)])
        case .recents: press([KeyStroke(code: AndroidKey.appSwitch)])
        case .volumeDown: press([KeyStroke(code: AndroidKey.volumeDown)])
        case .volumeUp: press([KeyStroke(code: AndroidKey.volumeUp)])
        case .rotate: send(ScrcpyControl.rotateDevice())
        }
    }

    // MARK: release

    /// Touch UP at the last position if a finger is down (at the current video size, scaled, when
    /// the size has changed: the helper drops a touch made for another size); Back and Home UP if held.
    public func releaseAll() {
        if let held = finger {
            finger = nil
            let video = currentVideo() ?? held.size
            let point = MirrorGeometry.rescale(held.point, from: held.size, to: video)
            touch(AndroidKey.up, point, video, pressure: 0)
        }
        if backHeld {
            backHeld = false
            send(ScrcpyControl.backOrScreenOn(action: AndroidKey.up))
        }
        if homeHeld {
            homeHeld = false
            send(ScrcpyControl.keycode(action: AndroidKey.up, code: AndroidKey.home))
        }
    }

    // MARK: private

    private var active: Bool { currentVideo() != nil }

    private func currentVideo() -> CGSize? {
        guard let size = videoSize(), wire(size) != nil else { return nil }
        return size
    }

    /// The video size as the wire's u16 width and height.
    private func wire(_ size: CGSize) -> (width: UInt16, height: UInt16)? {
        guard size.width >= 1, size.height >= 1, size.width <= CGFloat(UInt16.max), size.height <= CGFloat(UInt16.max) else { return nil }
        return (UInt16(size.width), UInt16(size.height))
    }

    private func touch(_ action: UInt8, _ point: (x: Int32, y: Int32), _ video: CGSize, pressure: Float) {
        guard let size = wire(video) else { return }
        send(ScrcpyControl.touch(action: action, x: point.x, y: point.y, width: size.width, height: size.height, pressure: pressure))
    }

    private func press(_ strokes: [KeyStroke]) {
        for s in strokes {
            send(ScrcpyControl.keycode(action: AndroidKey.down, code: s.code, meta: s.meta))
            send(ScrcpyControl.keycode(action: AndroidKey.up, code: s.code, meta: s.meta))
        }
    }

    /// SET_CLIPBOARD with paste, then `onPasteSent`; over the limit, a beep and nothing sent.
    private func paste(_ text: String) {
        guard text.utf8.count <= ScrcpyControl.setClipboardTextMaxBytes else {
            beep()
            return
        }
        sequence += 1
        send(ScrcpyControl.setClipboard(sequence: sequence, paste: true, text: text))
        onPasteSent(text)
    }

    private func notch(_ delta: CGFloat) -> CGFloat {
        delta > 0 ? 1 : delta < 0 ? -1 : 0
    }
}
