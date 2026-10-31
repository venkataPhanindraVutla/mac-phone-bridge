import AppKit
import FeatureMirror
import Observation

/// Makes the mirror window the first time it is shown, and each session's sink from it.
@MainActor
final class MirrorWindowHost {
    private(set) var controller: MirrorWindowController?

    func controller(model: MirrorModel, title: @escaping @MainActor () -> String) -> MirrorWindowController {
        if let controller { return controller }
        let made = MirrorWindowController(model: model, title: title)
        controller = made
        return made
    }

    /// The window's sink; one that drops everything when there is no window yet.
    func makeSink() -> any FrameSink {
        controller?.mirrorView.makeSink() ?? DiscardFrameSink()
    }
}

private final class DiscardFrameSink: FrameSink {
    func show(_ image: CVPixelBuffer) {}
    func flush() {}
}

/// The phone's screen: content aspect locked to the video, first sized to 80% of the visible
/// screen height; on a size change the long edge is kept, the frame stays centred and on screen.
/// Closing the window stops the session. The title is the phone's name (never logged).
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let mirrorView = MirrorView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
    private let model: MirrorModel
    private let title: @MainActor () -> String
    /// The video size the window was last fitted to; nil before the first.
    private var fitted: (width: Int, height: Int)?
    private let qualityMenu = NSMenu()

    private static let qualityItem = NSToolbarItem.Identifier("io.github.anmirror.mirror.quality")
    private static let muteItem = NSToolbarItem.Identifier("io.github.anmirror.mirror.mute")
    private static let screenItem = NSToolbarItem.Identifier("io.github.anmirror.mirror.screen")
    /// The phone keys, in toolbar order.
    private static let keys: [(id: NSToolbarItem.Identifier, key: ToolbarKey, symbol: String)] = [
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.back"), .back, "chevron.backward"),
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.home"), .home, "circle"),
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.recents"), .recents, "square.on.square"),
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.rotate"), .rotate, "rotate.right"),
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.volumeDown"), .volumeDown, "speaker.wave.1"),
        (NSToolbarItem.Identifier("io.github.anmirror.mirror.volumeUp"), .volumeUp, "speaker.wave.3"),
    ]
    /// The first window height, as a share of the visible screen height.
    static let firstHeightShare: CGFloat = 0.8

    init(model: MirrorModel, title: @escaping @MainActor () -> String) {
        self.model = model
        self.title = title
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = mirrorView
        window.initialFirstResponder = mirrorView
        window.contentMinSize = NSSize(width: 120, height: 120)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "io.github.anmirror.mirror.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // ⌘W in the mirror closes the window (which stops the session).
        mirrorView.bind(model, closeWindow: { [weak window] in window?.performClose(nil) })
        mirrorView.onShowAgain = { [weak self] in
            guard let model = self?.model else { return }
            Task { await model.start() }
        }
        fitFirst(width: 9, height: 19.5)
        window.center()
        observe()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        render()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        let model = model
        Task { await model.stop() }
    }

    // MARK: model

    private func observe() {
        withObservationTracking {
            _ = model.phase
            _ = model.canStart
            _ = model.preset
            _ = model.muted
            _ = model.audioActive
            _ = model.screenOff
        } onChange: { [weak self] in
            Self.later { self?.render(); self?.observe() }
        }
    }

    /// Hops to the main actor from whatever thread Observation calls back on.
    nonisolated private static func later(_ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in work() }
    }

    private func render() {
        guard let window else { return }
        window.title = title()
        mirrorView.show(model.phase, canStart: model.canStart)
        updateQualityMenu()
        updateKeyItems()
        updateMuteItem()
        updateScreenItem()
        if case let .running(width, height) = model.phase, width > 0, height > 0,
           fitted.map({ $0 != (width, height) }) ?? true {
            fit(width: width, height: height)
        }
    }

    // MARK: size

    private var visibleFrame: NSRect {
        (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func fit(width: Int, height: Int) {
        guard let window else { return }
        let first = fitted == nil
        fitted = (width, height)
        window.contentAspectRatio = NSSize(width: width, height: height)
        if first {
            fitFirst(width: CGFloat(width), height: CGFloat(height))
            window.center()
            return
        }
        // Keep the long edge; centre on the old frame; then keep it on screen.
        let old = window.frame
        let content = window.contentRect(forFrameRect: old).size
        let long = max(content.width, content.height)
        var size = height >= width
            ? NSSize(width: long * CGFloat(width) / CGFloat(height), height: long)
            : NSSize(width: long, height: long * CGFloat(height) / CGFloat(width))
        size = clamped(size, aspect: CGFloat(width) / CGFloat(height))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        window.setFrame(onScreen(frame), display: true, animate: false)
    }

    /// 80% of the visible screen height at the video's aspect, as the content size.
    private func fitFirst(width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let h = visibleFrame.height * Self.firstHeightShare
        let size = clamped(NSSize(width: h * width / height, height: h), aspect: width / height)
        window.setContentSize(size)
    }

    /// `size` scaled down (aspect kept) so the window fits the visible screen.
    private func clamped(_ size: NSSize, aspect: CGFloat) -> NSSize {
        guard let window else { return size }
        let chrome = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let extraW = chrome.width - size.width, extraH = chrome.height - size.height
        let maxW = visibleFrame.width - extraW, maxH = visibleFrame.height - extraH
        let scale = min(1, maxW / size.width, maxH / size.height)
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private func onScreen(_ frame: NSRect) -> NSRect {
        let v = visibleFrame
        var f = frame
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        return f
    }

    // MARK: toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.keys.prefix(3).map(\.id) + [.flexibleSpace] + Self.keys.dropFirst(3).map(\.id)
            + [Self.screenItem, Self.muteItem, Self.qualityItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.keys.map(\.id) + [.flexibleSpace, .space, Self.screenItem, Self.muteItem, Self.qualityItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let key = Self.keys.first(where: { $0.id == id }) {
            return keyItem(id: id, key: key.key, symbol: key.symbol)
        }
        if id == Self.screenItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.paletteLabel = String(localized: "Screen Off")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleScreen(_:))
            item.autovalidates = false
            configureScreen(item)
            return item
        }
        if id == Self.muteItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.paletteLabel = String(localized: "Mute")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleMute(_:))
            item.autovalidates = false
            configureMute(item)
            return item
        }
        guard id == Self.qualityItem else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: id)
        let label = String(localized: "Quality")
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: label)
        item.showsIndicator = true
        for (i, preset) in QualityPreset.all.enumerated() {
            let entry = NSMenuItem(title: Self.title(preset), action: #selector(choosePreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            qualityMenu.addItem(entry)
        }
        item.menu = qualityMenu
        updateQualityMenu()
        return item
    }

    /// A phone key button: its title is its label, tooltip and VoiceOver label.
    private func keyItem(id: NSToolbarItem.Identifier, key: ToolbarKey, symbol: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let title = Self.title(key)
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isBordered = true
        item.target = self
        item.action = #selector(pressKey(_:))
        item.autovalidates = false
        item.isEnabled = isRunning
        return item
    }

    private static func title(_ key: ToolbarKey) -> String {
        switch key {
        case .back: String(localized: "Back")
        case .home: String(localized: "Home")
        case .recents: String(localized: "Recents")
        case .rotate: String(localized: "Rotate")
        case .volumeDown: String(localized: "Volume Down")
        case .volumeUp: String(localized: "Volume Up")
        }
    }

    private var isRunning: Bool {
        if case .running = model.phase { true } else { false }
    }

    /// The phone key buttons in the toolbar are enabled only while running.
    private func updateKeyItems() {
        let running = isRunning
        let ids = Set(Self.keys.map(\.id))
        for item in window?.toolbar?.items ?? [] where ids.contains(item.itemIdentifier) {
            item.isEnabled = running
        }
    }

    /// "Mute" / "Unmute": the title says what a click does. Enabled while running with audio (not
    /// when audio is off in Settings, or the phone sends none).
    private func configureMute(_ item: NSToolbarItem) {
        let title = model.muted ? String(localized: "Unmute") : String(localized: "Mute")
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: model.muted ? "speaker.slash" : "speaker.wave.2",
                             accessibilityDescription: title)
        item.isEnabled = isRunning && model.audioActive
    }

    private func updateMuteItem() {
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == Self.muteItem {
            configureMute(item)
        }
    }

    @objc private func toggleMute(_ sender: NSToolbarItem) {
        model.muted.toggle()
    }

    /// "Screen Off" / "Screen On": the title says what a click does. Enabled while running.
    private func configureScreen(_ item: NSToolbarItem) {
        let title = model.screenOff ? String(localized: "Screen On") : String(localized: "Screen Off")
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: model.screenOff ? "iphone" : "iphone.slash", accessibilityDescription: title)
        item.isEnabled = isRunning
    }

    private func updateScreenItem() {
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == Self.screenItem {
            configureScreen(item)
        }
    }

    @objc private func toggleScreen(_ sender: NSToolbarItem) {
        model.setScreenOff(!model.screenOff)
    }

    @objc private func pressKey(_ sender: NSToolbarItem) {
        guard let key = Self.keys.first(where: { $0.id == sender.itemIdentifier })?.key else { return }
        mirrorView.input?.button(key)
    }

    private static func title(_ preset: QualityPreset) -> String {
        switch preset {
        case .balanced: String(localized: "Balanced")
        case .low: String(localized: "Low")
        default: String(localized: "High")
        }
    }

    private func updateQualityMenu() {
        for item in qualityMenu.items {
            item.state = QualityPreset.all.indices.contains(item.tag) && QualityPreset.all[item.tag] == model.preset ? .on : .off
        }
    }

    /// Sets the preset and restarts a session that is starting or running.
    @objc private func choosePreset(_ sender: NSMenuItem) {
        guard QualityPreset.all.indices.contains(sender.tag) else { return }
        let preset = QualityPreset.all[sender.tag]
        guard preset != model.preset else { return }
        model.preset = preset
        switch model.phase {
        case .starting, .running:
            let model = model
            Task { await model.start() }
        default:
            break
        }
    }
}
