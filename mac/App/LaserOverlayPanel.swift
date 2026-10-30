import AppKit
import FeatureInput

/// The phone's laser pointer: `LaserPanel`'s dot, centred on the pointer. It never takes focus
/// or a click from the app underneath, and shows over full-screen slideshows.
@MainActor
final class LaserOverlayPanel: LaserOverlay {
    private lazy var panel: NSPanel = LaserPanel.make()

    /// `p` is CG global (top-left origin, y down); the panel's frame is Cocoa (y up from the
    /// primary screen's bottom).
    func show(at p: CGPoint) {
        guard let primary = NSScreen.screens.first?.frame else { return }
        let d = LaserPanel.diameter
        panel.setFrameOrigin(NSPoint(x: p.x - d / 2, y: primary.maxY - p.y - d / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}
