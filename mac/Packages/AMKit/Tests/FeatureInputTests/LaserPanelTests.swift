import AppKit
import Testing
import FeatureInput

/// Ruling R34: the dot must show over full-screen slideshows, above normal windows, and never
/// take a click or focus.
@MainActor @Test func laserPanelShowsOverFullScreenAndIgnoresClicks() {
    let panel = LaserPanel.make()
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
    #expect(panel.level == .screenSaver)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.isOpaque)
    #expect(!panel.hasShadow)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(!panel.styleMask.contains(.titled))
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.frame.size == CGSize(width: 24, height: 24))
}
