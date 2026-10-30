import AppKit
import FeatureInput

/// The phone's laser pointer: a 24 pt red dot at 60 % alpha over everything, centred on the
/// pointer. Borderless, transparent, click-through and never key or main, so it never takes
/// focus or a click from the app underneath.
@MainActor
final class LaserOverlayPanel: LaserOverlay {
    static let diameter: CGFloat = 24

    private lazy var panel: NSPanel = Self.makePanel()

    /// `p` is CG global (top-left origin, y down); the panel's frame is Cocoa (y up from the
    /// primary screen's bottom).
    func show(at p: CGPoint) {
        guard let primary = NSScreen.screens.first?.frame else { return }
        let d = Self.diameter
        panel.setFrameOrigin(NSPoint(x: p.x - d / 2, y: primary.maxY - p.y - d / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let d = diameter
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = LaserDotView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        return panel
    }
}

private final class LaserDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
