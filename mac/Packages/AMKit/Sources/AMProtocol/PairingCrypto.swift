import CryptoKit
import Foundation
import Security

/// Fingerprints, pairing proofs, confirmation codes and rotating IDs.
/// Definitions: protocol/SPEC.md sections 4, 5.1 and 6.
public enum PairingCrypto {
    private static let proofLabel = Data("anmirror-pair-v1".utf8)
    private static let sasLabel = Data("anmirror-sas-v1".utf8)
    private static let ridLabel = Data("anmirror-rid-v1".utf8)
    private static let epochSeconds: Int64 = 900

    /// SHA-256 of the certificate DER, 32 raw bytes.
    public static func fingerprint(certificateDER: Data) -> Data {
        Data(SHA256.hash(data: certificateDER))
    }

    public static func secretProof(secret: Data, macFingerprint: Data, phoneFingerprint: Data) -> Data {
        let message = proofLabel + macFingerprint + phoneFingerprint
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(mac)
    }

    /// Six digits, zero-padded.
    public static func confirmationCode(macFingerprint: Data, phoneFingerprint: Data) -> String {
        let h = Array(SHA256.hash(data: sasLabel + macFingerprint + phoneFingerprint))
        let value = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
        let digits = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// 16 lowercase hex characters for the 15-minute epoch containing `unixSeconds`.
    public static func rotatingID(discoveryKey: Data, unixSeconds: Int64) -> String {
        rotatingID(discoveryKey: discoveryKey, epoch: floorDiv(unixSeconds, epochSeconds))
    }

    /// Accepts the epoch before, of, and after `unixSeconds`.
    public static func matchesRotatingID(_ rid: String, discoveryKey: Data, unixSeconds: Int64) -> Bool {
        let epoch = floorDiv(unixSeconds, epochSeconds)
        let given = Data(rid.utf8)
        var matched = false
        for e in (epoch - 1)...(epoch + 1) {
            let expected = Data(rotatingID(discoveryKey: discoveryKey, epoch: e).utf8)
            if expected.count == given.count && constantTimeEqual(expected, given) { matched = true }
        }
        return matched
    }

    public static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    // MARK: private

    private static func rotatingID(discoveryKey: Data, epoch: Int64) -> String {
        var be = UInt64(bitPattern: epoch).bigEndian
        let epochBytes = withUnsafeBytes(of: &be) { Data($0) }
        let mac = HMAC<SHA256>.authenticationCode(
            for: ridLabel + epochBytes, using: SymmetricKey(data: discoveryKey))
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
