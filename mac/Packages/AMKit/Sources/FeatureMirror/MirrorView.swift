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
            case .turnedOff: return offByUser
            case .unavailable: return String(localized: "Showing the phone screen needs Android 11 or later.", bundle: .main)
            default: return nil
            }
        case .disconnected, .macSleep, .user: return nil
        }
    }

    private static var offByUser: String {
        String(localized: "Turn on “Allow your Mac to show this screen” in the phone app.", bundle: .main)
    }
}

/// Hosts the video layer (`AVSampleBufferDisplayLayer`, aspect fit) and, over it, the placeholder
/// or failure line with "Show Again". Input (Task 6) arrives here too.
@MainActor
public final class MirrorView: NSView {
    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Called by "Show Again".
    public var onShowAgain: (() -> Void)?

    private let line = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let overlay = NSStackView()

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
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(MirrorCopy.phoneScreen)
        show(.idle, canStart: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

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

    @objc private func showAgain() { onShowAgain?() }
}

extension MirrorModel.Phase {
    var isRunning: Bool { if case .running = self { true } else { false } }
}
