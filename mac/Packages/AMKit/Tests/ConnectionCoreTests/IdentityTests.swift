import AMProtocol
import Foundation
import Security
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
    let label = "io.github.anmirror.mac.identity.test"
    defer { removeKeychainIdentity(label: label) }
    let provider = KeychainIdentityProvider(label: label)
    let a = try provider.identity()
    let b = try provider.identity()
    #expect(a.fingerprint == b.fingerprint)
    // A second provider instance (as after a relaunch) reuses the key and certificate.
    let c = try KeychainIdentityProvider(label: label).identity()
    #expect(a.fingerprint == c.fingerprint)
    #expect(certificateCount(label: label) == 1, "a new certificate appeared")
    #expect(a.fingerprint.count == 32)
}

/// Removes the test key and its certificate so the opt-in test leaves the keychain as it was.
private func removeKeychainIdentity(label: String) {
    let keyQuery: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrApplicationTag as String: Data(label.utf8),
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: false,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(keyQuery as CFDictionary, &found) == errSecSuccess, let found,
          let attributes = SecKeyCopyAttributes(found as! SecKey) as? [String: Any],
          let hash = attributes[kSecAttrApplicationLabel as String] as? Data else { return }
    SecItemDelete([
        kSecClass as String: kSecClassCertificate,
        kSecAttrPublicKeyHash as String: hash,
        kSecUseDataProtectionKeychain as String: false,
    ] as CFDictionary)
    var delete = keyQuery
    delete[kSecReturnRef as String] = nil
    delete[kSecMatchLimit as String] = nil
    SecItemDelete(delete as CFDictionary)
}

private func certificateCount(label: String) -> Int {
    let keyQuery: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: Data(label.utf8),
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseDataProtectionKeychain as String: false,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(keyQuery as CFDictionary, &found) == errSecSuccess, let found,
          let attributes = SecKeyCopyAttributes(found as! SecKey) as? [String: Any],
          let hash = attributes[kSecAttrApplicationLabel as String] as? Data else { return -1 }
    var certs: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass as String: kSecClassCertificate,
        kSecAttrPublicKeyHash as String: hash,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecUseDataProtectionKeychain as String: false,
    ] as CFDictionary, &certs)
    return status == errSecSuccess ? (certs as? [Any])?.count ?? 0 : 0
}
