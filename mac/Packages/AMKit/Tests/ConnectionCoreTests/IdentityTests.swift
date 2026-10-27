import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

@Test func p12IdentityLoadsFixture() throws {
    let identity = try testIdentity("mac")
    #expect(identity.fingerprint == (try vectorFingerprint("mac")))
    #expect(identity.fingerprint == PairingCrypto.fingerprint(certificateDER: identity.certificateDER))
}

@Test func p12IdentityRejectsWrongPassword() {
    #expect(throws: (any Error).self) {
        try P12IdentityProvider(url: identityURL("mac"), password: "wrong").identity()
    }
}

/// Opt-in only: writes a key and certificate to the login keychain.
/// Run with `AM_KEYCHAIN_TESTS=1 swift test --filter keychainIdentityIsStable`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AM_KEYCHAIN_TESTS"] == "1"))
func keychainIdentityIsStable() throws {
    let provider = KeychainIdentityProvider(label: "io.github.anmirror.mac.identity.test")
    let a = try provider.identity()
    let b = try provider.identity()
    #expect(a.fingerprint == b.fingerprint)
    #expect(a.fingerprint.count == 32)
}
