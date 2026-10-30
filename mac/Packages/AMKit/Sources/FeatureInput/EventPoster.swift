import AMProtocol
import AppKit
import CoreGraphics

/// Posts pointer, scroll and key events. Coordinates are CG global: top-left origin of the
/// primary screen, y down.
@MainActor
public protocol EventPoster: AnyObject {
    /// Where the pointer is now.
    func location() -> CGPoint
    /// Every screen's frame.
    func screens() -> [CGRect]
    /// A plain move, or a drag of `holding` with its click state (`clickCount`, 0 for a plain move).
    func move(to p: CGPoint, holding: AMMouseButton?, clickCount: Int)
    func button(_ b: AMMouseButton, down: Bool, at p: CGPoint, clickCount: Int)
    /// A continuous scroll in pixels.
    func scroll(pixelsX: Int32, pixelsY: Int32)
    /// Key down, then key up.
    func key(_ code: CGKeyCode)
}

/// The real poster: CGEvents to the HID event tap. Needs Accessibility; without it macOS drops
/// the events, which is harmless.
@MainActor
public final class CGEventPoster: EventPoster {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Posting must not hold up the Mac's own mouse and keyboard.
        source?.localEventsSuppressionInterval = 0
    }

    public func location() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public func screens() -> [CGRect] {
        let screens = NSScreen.screens
        // CG global y runs down from the primary screen's top.
        guard let primary = screens.first?.frame else { return [] }
        return screens.map { s in
            let f = s.frame
            return CGRect(x: f.minX, y: primary.maxY - f.maxY, width: f.width, height: f.height)
        }
    }

    public func move(to p: CGPoint, holding: AMMouseButton?, clickCount: Int) {
        let type: CGEventType
        let button: CGMouseButton
        switch holding {
        case .left?: (type, button) = (.leftMouseDragged, .left)
        case .right?: (type, button) = (.rightMouseDragged, .right)
        default: (type, button) = (.mouseMoved, .left)
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        if holding != nil { event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        event?.post(tap: .cghidEventTap)
    }

    public func button(_ b: AMMouseButton, down: Bool, at p: CGPoint, clickCount: Int) {
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case .right: (type, button) = (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (type, button) = (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
    }

    public func scroll(pixelsX: Int32, pixelsY: Int32) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: pixelsY, wheel2: pixelsX, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    public func key(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

/// The laser dot over everything, centred on a CG global point.
@MainActor
public protocol LaserOverlay: AnyObject {
    func show(at p: CGPoint)
    func hide()
}
