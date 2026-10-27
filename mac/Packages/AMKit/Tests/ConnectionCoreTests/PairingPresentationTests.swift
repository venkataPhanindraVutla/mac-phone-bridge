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
