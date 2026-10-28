import AMProtocol
import Foundation

/// Text for the menu bar, the menu and VoiceOver. Strings are looked up in the main bundle (the
/// app's Localizable.xcstrings); where there is none, as in package tests, the English default
/// shown here is used.
public enum StatusFormatter {
    /// "82%" or "82% ⚡︎" (menu-bar title).
    public static func menuTitle(_ s: PhoneStatus) -> String {
        s.charging ? "\(s.batteryPercent)% ⚡︎" : "\(s.batteryPercent)%"
    }

    /// "Battery 82%, charging · Wi-Fi · Signal 3 of 4" (menu line).
    public static func detail(_ s: PhoneStatus) -> String {
        let battery = s.charging
            ? String(localized: "Battery \(s.batteryPercent)%, charging", bundle: .main)
            : String(localized: "Battery \(s.batteryPercent)%, not charging", bundle: .main)
        let signal = s.signalLevel < 0
            ? String(localized: "No service", bundle: .main)
            : String(localized: "Signal \(s.signalLevel) of 4", bundle: .main)
        return [battery, networkName(s.network), signal].joined(separator: " · ")
    }

    /// Full words, no symbols, for VoiceOver.
    public static func accessibilityLabel(_ s: PhoneStatus) -> String {
        let battery = s.charging
            ? String(localized: "Phone battery \(s.batteryPercent) percent, charging", bundle: .main)
            : String(localized: "Phone battery \(s.batteryPercent) percent, not charging", bundle: .main)
        let signal = s.signalLevel < 0
            ? String(localized: "no cellular service", bundle: .main)
            : String(localized: "signal \(s.signalLevel) of 4 bars", bundle: .main)
        return [battery, networkName(s.network), signal].joined(separator: ", ")
    }

    static func networkName(_ kind: AMNetworkKind) -> String {
        switch kind {
        case .wifi: String(localized: "Wi-Fi", bundle: .main)
        case .cellular: String(localized: "Mobile data", bundle: .main)
        case .none: String(localized: "No network", bundle: .main)
        case .other: String(localized: "Other network", bundle: .main)
        default: String(localized: "Network unknown", bundle: .main)
        }
    }
}
