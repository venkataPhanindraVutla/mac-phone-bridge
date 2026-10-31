import AMProtocol
import AppKit
import AVFoundation

/// The mirror copy (Global Constraints). Keys live in the app's `Localizable.xcstrings` (`bundle: .main`).
public enum MirrorCopy {
    public static var starting: String { String(localized: "Starting…", bundle: .main) }
    public static var notShowing: String { String(localized: "Not showing the phone screen.", bundle: .main) }
    public static var showAgain: String { String(localized: "Show Again", bundle: .main) }
    public static var phoneScreen: String { String(localized: "Phone screen", bundle: .main) }

    /// The menu notice when the phone's mirroring is not available; nil when it is (or unknown).
    public static func notice(_ availability: AMFeatureAvailability?) -> String? {
        guard let availability, !availability.enabled else { return nil }
        switch availability.reason {
        case .offByUser: return offByUser
        case .needsSetup: return String(localized: "Set up Full mode in the phone app to show its screen.", bundle: .main)
        case .unavailable: return String(localized: "Showing the phone screen needs Android 11 or later.", bundle: .main)
        default: return nil
        }
    }

    /// The window's line for an ended session; nil for the plain "Not showing the phone screen." placeholder.
    public static func failure(_ reason: MirrorEndReason) -> String? {
        switch reason {
        case .timeout: return String(localized: "The phone didn't respond.", bundle: .main)
        case let .phone(r):
            switch r {
            case .needsSetup:
                return String(localized: "Wireless debugging is off on the phone. Tap “Re-enable Full mode” in the phone app.",
                              bundle: .main)
            case .adbFailed: return String(localized: "Couldn't reach Wireless debugging on the phone.", bundle: .main)
            case .helperFailed: return String(localized: "The phone couldn't start sharing its screen.", bundle: .main)
            case .linkFailed: return String(localized: "The connection to the phone dropped.", bundle: .main)
            case .linkSlow: return String(localized: "The connection was too slow to show the phone screen.", bundle: .main)
            case .turnedOff: return offByUser
            case .unavailable: return String(localized: "Showing the phone screen needs Android 11 or later.", bundle: .main)
            default: return nil
            }
        case .disconnected, .macSleep, .user: return nil
        }
    }

    /// The window's note after the H.265 fallback.
    public static var h265Note: String { String(localized: "This phone can't send H.265. Using H.264.", bundle: .main) }

    /// The "Measure Delay…" results alert: its title, and its two lines.
    public static var delayTitle: String { String(localized: "Delay", bundle: .main) }

    public static func delayRoundTrip(_ r: DelayResult) -> String {
        let m = Int(r.medianMs.rounded()), p = Int(r.p95Ms.rounded())
        return String(localized: "Round trip: median \(m) ms, 95th percentile \(p) ms, \(r.trials) taps (\(r.misses) missed).",
                      bundle: .main)
    }

    public static func delayFrameRate(_ r: DelayResult) -> String {
        let f = r.fpsMean.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Frame rate: \(f) fps.", bundle: .main)
    }

    /// The alert's text: the round trip and frame rate, or that the test screen never showed.
    public static func delayMessage(_ r: DelayResult) -> String {
        guard r.testScreenOpened else { return String(localized: "The test screen didn't open on the phone.", bundle: .main) }
        return delayRoundTrip(r) + "\n" + delayFrameRate(r)
    }

    private static var offByUser: String {
        String(localized: "Turn on “Allow your Mac to show this screen” in the phone app.", bundle: .main)
    }
}

/// Hosts the video layer (`AVSampleBufferDisplayLayer`, aspect fit) and, over it, the placeholder
/// or failure line with "Show Again", and the input method's composition at the bottom.
///
/// Input: the mouse, scroll, keys (through `interpretKeyEvents`, so input methods work) and ⌘
/// shortcuts go to `input`. Held input is let go when the view resigns first responder, leaves
/// its window, or its window resigns key or closes. Typed text is never logged.
///
/// Files dragged from the Finder are taken while the model's `canDropFiles` (a session runs and
/// the phone takes files) and handed to `MirrorModel.dropFiles`. File names are never logged.
@MainActor
public final class MirrorView: NSView {
    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Called by "Show Again".
    public var onShowAgain: (() -> Void)?
    /// Where input goes; set by `bind(_:closeWindow:)` (or a test).
    public internal(set) var input: InputMapper?

    private let line = NSTextField(wrappingLabelWithString: "")
    /// A note over the top of the picture (the H.265 fallback); hidden when there is none.
    private let note = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let overlay = NSStackView()
    /// The input method's composition, shown and never sent until committed.
    private let marked = NSTextField(labelWithString: "")
    private var markedText = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    /// The composition is being dropped: whatever the input method hands back now is not sent.
    private var discarding = false
    private var windowObservers: [NSObjectProtocol] = []
    /// The model bound by `bind(_:closeWindow:)`: where dropped files go, and told when the
    /// window closes.
    private weak var boundModel: MirrorModel?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)

        line.alignment = .center
        line.textColor = .white
        line.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        line.maximumNumberOfLines = 0
        button.title = MirrorCopy.showAgain
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(showAgain)
        overlay.orientation = .vertical
        overlay.spacing = 12
        overlay.alignment = .centerX
        overlay.addArrangedSubview(line)
        overlay.addArrangedSubview(button)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        note.alignment = .center
        note.textColor = .white
        note.drawsBackground = true
        note.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)

        marked.font = .systemFont(ofSize: NSFont.systemFontSize + 4)
        marked.textColor = .white
        marked.drawsBackground = true
        marked.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        marked.alignment = .center
        marked.lineBreakMode = .byTruncatingHead
        marked.isHidden = true
        marked.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marked)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            marked.centerXAnchor.constraint(equalTo: centerXAnchor),
            marked.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            marked.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            marked.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            note.centerXAnchor.constraint(equalTo: centerXAnchor),
            note.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(MirrorCopy.phoneScreen)
        show(.idle, canStart: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Sends this view's input to `model`'s session while it runs, and lets the model release held
    /// input when the session ends or its size changes. `closeWindow` is ⌘W.
    public func bind(_ model: MirrorModel, closeWindow: @escaping @MainActor () -> Void) {
        let mapper = InputMapper(
            send: { [weak model] bytes in model?.session?.sendControl(bytes) },
            videoSize: { [weak model] in
                guard let model, case let .running(width, height) = model.phase, width > 0, height > 0 else { return nil }
                return CGSize(width: width, height: height)
            },
            pasteboardText: { NSPasteboard.general.string(forType: .string) },
            onPasteSent: { [weak model] text in model?.onPasteSent?(text) },
            closeWindow: closeWindow
        )
        input = mapper
        model.releaseInput = { [weak mapper] in mapper?.releaseAll() }
        boundModel = model
    }

    /// A sink that draws on this view's layer, for a new session.
    public func makeSink() -> any FrameSink {
        LayerFrameSink(renderer: displayLayer.sampleBufferRenderer)
    }

    /// Shows the placeholder or failure line for `phase` (none while running).
    public func show(_ phase: MirrorModel.Phase, canStart: Bool) {
        switch phase {
        case .running:
            overlay.isHidden = true
        case .starting:
            overlay.isHidden = false
            line.stringValue = MirrorCopy.starting
            button.isHidden = true
        case .idle:
            overlay.isHidden = false
            line.stringValue = MirrorCopy.notShowing
            button.isHidden = false
        case let .ended(reason):
            overlay.isHidden = false
            line.stringValue = MirrorCopy.failure(reason) ?? MirrorCopy.notShowing
            button.isHidden = false
        }
        button.isEnabled = canStart
        // The last picture stays under a starting session; anything else hides behind the line.
        displayLayer.opacity = phase == .starting || phase.isRunning ? 1 : 0.25
    }

    /// Shows `text` as a note over the top of the picture; nil hides it.
    public func showNote(_ text: String?) {
        note.stringValue = text ?? ""
        note.isHidden = text == nil
    }

    /// The note shown, if any (internal, for tests).
    var noteShown: String? { note.isHidden ? nil : note.stringValue }

    @objc private func showAgain() { onShowAgain?() }

    // MARK: focus and release

    public override var acceptsFirstResponder: Bool { true }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            dropComposition()
            input?.releaseAll()
        }
        return resigned
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        input?.releaseAll()
        dropComposition()
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers = []
        if let newWindow {
            // On close the phone's screen comes back on before the release's UP (the stop follows).
            windowObservers = Self.observeRelease(of: newWindow, beforeClose: { [weak self] in
                self?.boundModel?.screenOnBeforeClose()
            }) { [weak self] in self?.input?.releaseAll() }
        }
    }

    /// Calls `release` when `window` resigns key or closes, and `beforeClose` just before it on
    /// close. Built here, nonisolated, so the blocks handed to NotificationCenter carry no
    /// main-actor isolation; they run on the main queue.
    nonisolated static func observeRelease(of window: NSWindow, center: NotificationCenter = .default,
                                           beforeClose: (@MainActor @Sendable () -> Void)? = nil,
                                           _ release: @escaping @MainActor @Sendable () -> Void) -> [NSObjectProtocol] {
        [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            let closing = name == NSWindow.willCloseNotification ? beforeClose : nil
            return center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    closing?()
                    release()
                }
            }
        }
    }

    // MARK: mouse and scroll

    /// `event`'s location in this view, with the origin at the top left (as the video's).
    private func topLeft(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        input?.mouseDown(at: topLeft(event), viewSize: bounds.size)
    }

    public override func mouseDragged(with event: NSEvent) {
        input?.mouseDragged(to: topLeft(event), viewSize: bounds.size)
    }

    public override func mouseUp(with event: NSEvent) {
        input?.mouseUp(at: topLeft(event), viewSize: bounds.size)
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        input?.rightMouse(down: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        input?.rightMouse(down: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        window?.makeFirstResponder(self)
        input?.middleMouse(down: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        input?.middleMouse(down: false)
    }

    public override func scrollWheel(with event: NSEvent) {
        input?.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                      at: topLeft(event), viewSize: bounds.size)
    }

    // MARK: keys

    public override func keyDown(with event: NSEvent) {
        // Every keyDown, repeats included, goes through the input method: text to insertText,
        // commands to doCommand(by:), compositions to setMarkedText.
        interpretKeyEvents([event])
    }

    /// ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z, ⌘⇧Z and ⌘W while the mirror has the focus; every other ⌘ key goes on
    /// to the Mac's menus and never reaches the phone.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // With no running session only ⌘W is taken; the rest go on to the menus, whose items
        // are disabled then (`validateUserInterfaceItem`).
        guard event.type == .keyDown, let input, window?.firstResponder === self,
              let action = KeyMap.shortcut(characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags),
              action == .closeWindow || input.isActive
        else { return super.performKeyEquivalent(with: event) }
        input.shortcut(action)
        return true
    }

    // The Edit menu's items, for when the menus see a shortcut before the view does: the same
    // actions, so a shortcut is handled once whichever way it comes.
    @objc func paste(_ sender: Any?) { input?.shortcut(.paste) }
    @objc func copy(_ sender: Any?) { input?.shortcut(.copy) }
    @objc func cut(_ sender: Any?) { input?.shortcut(.cut) }
    public override func selectAll(_ sender: Any?) { input?.shortcut(KeyMap.selectAll) }
    @objc func undo(_ sender: Any?) { input?.shortcut(KeyMap.undo) }
    @objc func redo(_ sender: Any?) { input?.shortcut(KeyMap.redo) }

    /// The Edit menu's actions are enabled only while a session runs.
    static let phoneEditActions: Set<Selector> = [
        #selector(paste(_:)), #selector(copy(_:)), #selector(cut(_:)),
        #selector(selectAll(_:)), #selector(undo(_:)), #selector(redo(_:)),
    ]

    // MARK: composition

    /// The composition on screen; nil when there is none (internal, for tests).
    var markedOverlayText: String? { marked.isHidden ? nil : marked.stringValue }

    private func showComposition() {
        marked.stringValue = markedText.string
        marked.isHidden = markedText.length == 0
    }

    /// Forgets the composition without sending it (focus lost, view moved).
    private func dropComposition() {
        guard markedText.length > 0 else { return }
        markedText = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        showComposition()
        discarding = true
        defer { discarding = false }
        inputContext?.discardMarkedText()
    }
}

// AppKit calls the client on the main thread only; `@preconcurrency` checks that at run time.
extension MirrorView: @preconcurrency NSTextInputClient {
    private static func plain(_ string: Any) -> NSAttributedString {
        if let attributed = string as? NSAttributedString { return attributed }
        return NSAttributedString(string: string as? String ?? "")
    }

    /// Committed text: sent (typed or pasted); any composition is over. A replacement range with
    /// no composition (press-and-hold accents: "é" replacing the "e" already sent) deletes the
    /// replaced characters on the phone first.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plain(string).string
        let replaced = markedText.length == 0 && replacementRange.location != NSNotFound ? replacementRange.length : 0
        markedText = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        showComposition()
        guard !discarding else { return }
        if replaced > 0 { input?.deleteBackward(replaced) }
        input?.commit(text)
    }

    public override func doCommand(by selector: Selector) {
        input?.command(selector)
    }

    /// The composition: shown at the bottom, never sent.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plain(string)
        markedSelection = selectedRange
        showComposition()
    }

    /// The input method ends the composition: what is marked is committed.
    public func unmarkText() {
        let text = markedText.string
        markedText = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        showComposition()
        if !text.isEmpty, !discarding { input?.commit(text) }
    }

    public func selectedRange() -> NSRange {
        markedText.length > 0 ? markedSelection : NSRange(location: 0, length: 0)
    }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let whole = NSRange(location: 0, length: markedText.length)
        let clipped = NSIntersectionRange(whole, range)
        guard range.location != NSNotFound, clipped.length > 0 || range.length == 0, clipped.location <= markedText.length else {
            return nil
        }
        actualRange?.pointee = clipped
        return markedText.attributedSubstring(from: clipped)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The composition's rect on screen, so the candidate window sits by it.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange().location == NSNotFound ? NSRange(location: 0, length: 0) : markedRange()
        layoutSubtreeIfNeeded()
        var rect = marked.frame
        if marked.isHidden || rect.isEmpty {
            // No composition shown yet: a line's height at the bottom centre.
            let height = marked.intrinsicContentSize.height
            rect = NSRect(x: bounds.midX, y: 16, width: 1, height: height > 0 ? height : 20)
        }
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

// MARK: file drop

extension MirrorView {
    /// A file drag would be taken now (internal, for tests).
    var acceptsFileDrop: Bool { boundModel?.canDropFiles == true }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showDropTarget(false)
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        showDropTarget(false)
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        takes(Self.fileURLs(sender))
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showDropTarget(false)
        let urls = Self.fileURLs(sender)
        guard takes(urls) else { return false }
        return boundModel?.dropFiles(urls) ?? false
    }

    /// Copy while a drop would be taken, with the system's focus ring colour around the picture;
    /// otherwise no drop, as AppKit shows it.
    private func dragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let take = takes(Self.fileURLs(sender))
        showDropTarget(take)
        return take ? .copy : []
    }

    /// A drop is taken now and carries at least one file (folders alone don't go; with files,
    /// they are left to the app, which says so).
    private func takes(_ urls: [URL]) -> Bool {
        acceptsFileDrop && urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
    }

    private func showDropTarget(_ on: Bool) {
        layer?.borderWidth = on ? 3 : 0
        layer?.borderColor = on ? NSColor.keyboardFocusIndicatorColor.cgColor : nil
    }

    private static func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

extension MirrorView: NSUserInterfaceValidations {
    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, Self.phoneEditActions.contains(action) else { return true }
        return input?.isActive == true
    }
}

extension MirrorModel.Phase {
    var isRunning: Bool { if case .running = self { true } else { false } }
}
