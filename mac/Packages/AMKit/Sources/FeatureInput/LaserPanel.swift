import AppKit

/// The laser dot's window: a 24 pt `systemRed` circle at 60 % alpha in a borderless,
/// transparent, click-through panel that never becomes key or main. It sits at the screen-saver
/// level and joins every Space, full-screen ones included, so it shows over a full-screen
/// slideshow (ruling R34).
public enum LaserPanel {
    public static let diameter: CGFloat = 24

    @MainActor
    public static func make() -> NSPanel {
        let d = diameter
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
