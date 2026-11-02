import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

@Test func pairingCopyCoversEveryErrorCode() {
    for code in AMErrorCode.allCases where code != .unspecified {
        if case .UNRECOGNIZED = code { continue }
        let text = String(localized: PairingCopy.message(for: code))
        #expect(!text.isEmpty, "no copy for \(code)")
    }
    #expect(String(localized: PairingCopy.message(for: .pairingExpired))
        == "This code has expired. Show a new code on your Mac.")
}

@Test func timedOutConfirmationHasItsOwnCopy() {
    let text = String(localized: PairingCopy.confirmationTimedOut)
    #expect(text == "Time ran out before you confirmed. Show a new code.")
    #expect(text != String(localized: PairingCopy.message(for: .pairingRejected)))
}

@Test func startupFailuresGetPlainCopy() {
    // The user said no to the Keychain prompt (errSecUserCanceled), or it could not be shown.
    for status: OSStatus in [-128, -25293, -25308] {
        #expect(String(localized: StartupCopy.message(for: IdentityError.keychain(status)))
            == "Can't start: allow Keychain access and reopen the app.")
    }
    #expect(String(localized: StartupCopy.message(for: IdentityError.identityUnavailable))
        == "Can't start: allow Keychain access and reopen the app.")
    #expect(String(localized: StartupCopy.message(for: IdentityError.keychain(-1)))
        == "Can't start. Quit and reopen the app.")
    #expect(String(localized: StartupCopy.message(for: IdentityError.noIdentityInFile))
        == "Can't start. Quit and reopen the app.")
    #expect(String(localized: StartupCopy.listener)
        == "Can't listen for phones. Check your network and reopen the app.")
    // Nothing raw: no type names or status codes.
    let text = String(localized: StartupCopy.message(for: IdentityError.keychain(-1)))
    #expect(!text.contains("keychain(") && !text.contains("-1"))
}
