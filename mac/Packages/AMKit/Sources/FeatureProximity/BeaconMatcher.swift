import AMProtocol
import Foundation

/// Tells one paired phone's beacon from everything else on the air (SPEC section 22): the 8-byte
/// BLE ID for this Mac's discovery key and that phone's fingerprint, for the epoch before, of or
/// after now.
public struct BeaconMatcher: Sendable {
    private let discoveryKey: Data
    private let phoneFingerprint: Data

    public init(discoveryKey: Data, phoneFingerprint: Data) {
        self.discoveryKey = discoveryKey
        self.phoneFingerprint = phoneFingerprint
    }

    /// Compares with all three IDs in constant time.
    public func matches(_ serviceData: Data, unixSeconds: Int64) -> Bool {
        let given = [UInt8](serviceData)
        guard given.count == 8 else { return false }
        let epoch = PairingCrypto.epoch(unixSeconds: unixSeconds)
        var matched = false
        for e in (epoch - 1)...(epoch + 1) {
            let expected = [UInt8](PairingCrypto.bleID(
                discoveryKey: discoveryKey, phoneFingerprint: phoneFingerprint, epoch: e))
            var diff: UInt8 = 0
            for i in 0..<8 { diff |= expected[i] ^ given[i] }
            matched = matched || diff == 0
        }
        return matched
    }
}
