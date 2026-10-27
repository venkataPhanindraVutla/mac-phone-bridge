import AMProtocol
import Foundation

/// User-facing text for pairing failures. Keys live in the app's `Localizable.xcstrings`
/// (`bundle: .main`); the default values are the English copy.
public enum PairingCopy {
    public static func message(for code: AMErrorCode) -> LocalizedStringResource {
        switch code {
        case .pairingExpired:
            LocalizedStringResource("pairing.error.expired",
                defaultValue: "This code has expired. Show a new code on your Mac.", bundle: .main)
        case .badPairingSecret:
            LocalizedStringResource("pairing.error.badSecret",
                defaultValue: "That code didn't match. Scan the code on your Mac again.", bundle: .main)
        case .pairingRejected:
            LocalizedStringResource("pairing.error.rejected",
                defaultValue: "Pairing was declined. Start again from your Mac.", bundle: .main)
        case .notPaired:
            LocalizedStringResource("pairing.error.notPaired",
                defaultValue: "This phone isn't paired with that Mac. Pair it again.", bundle: .main)
        case .protocolMismatch:
            LocalizedStringResource("pairing.error.protocolMismatch",
                defaultValue: "The Mac and phone apps are different versions. Update both apps.", bundle: .main)
        case .busy:
            LocalizedStringResource("pairing.error.busy",
                defaultValue: "That Mac is already connected to another phone.", bundle: .main)
        case .unspecified, .UNRECOGNIZED:
            LocalizedStringResource("pairing.error.unknown",
                defaultValue: "Something went wrong. Try again.", bundle: .main)
        }
    }
}
