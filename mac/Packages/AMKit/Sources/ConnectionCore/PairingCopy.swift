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

extension PairingCopy {
    /// The 60 s confirmation window ran out before the user pressed Confirm (not a refusal).
    public static var confirmationTimedOut: LocalizedStringResource {
        LocalizedStringResource("pairing.error.timedOut",
            defaultValue: "Time ran out before you confirmed. Show a new code.", bundle: .main)
    }
}

/// User-facing text for a server that could not start (the menu's first line).
public enum StartupCopy {
    public static func message(for error: any Error) -> LocalizedStringResource {
        // errSecUserCanceled (Deny on the Keychain prompt), errSecAuthFailed, errSecInteractionNotAllowed.
        let denied: Bool
        switch error {
        case IdentityError.identityUnavailable: denied = true
        case let IdentityError.keychain(status): denied = [-128, -25293, -25308].contains(status)
        default: denied = false
        }
        if denied {
            return LocalizedStringResource("startup.error.keychain",
                defaultValue: "Can't start: allow Keychain access and reopen the app.", bundle: .main)
        }
        return LocalizedStringResource("startup.error.generic",
            defaultValue: "Can't start. Quit and reopen the app.", bundle: .main)
    }

    /// No listener could be opened, even on any free port.
    public static var listener: LocalizedStringResource {
        LocalizedStringResource("startup.error.listener",
            defaultValue: "Can't listen for phones. Check your network and reopen the app.", bundle: .main)
    }
}
