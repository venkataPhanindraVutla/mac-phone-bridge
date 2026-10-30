import AMProtocol
import Foundation

/// Tells one paired phone's beacon from everything else on the air (SPEC section 22): the 8-byte
/// BLE ID for this Mac's discovery key and that phone's fingerprint, for the epoch before, of or
/// after now. A matcher is for one phone and one key; the IDs are computed once per epoch.
public struct BeaconMatcher: Sendable {
    private let discoveryKey: Data
    private let phoneFingerprint: Data
    private let cache = IDCache()

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
            let expected = id(epoch: e)
            var diff: UInt8 = 0
            for i in 0..<8 { diff |= expected[i] ^ given[i] }
            matched = matched || diff == 0
        }
        return matched
    }

    /// How many IDs have been computed (internal, for tests).
    var computedCount: Int { cache.computed }

    private func id(epoch: Int64) -> [UInt8] {
        cache.id(epoch: epoch) {
            [UInt8](PairingCrypto.bleID(discoveryKey: discoveryKey, phoneFingerprint: phoneFingerprint, epoch: epoch))
        }
    }
}

/// The last few epochs' IDs. Beacons arrive on the main actor, but the matcher is `Sendable`, so
/// the cache takes a lock.
private final class IDCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int64: [UInt8]] = [:]
    private var made = 0

    var computed: Int { lock.withLock { made } }

    func id(epoch: Int64, make: () -> [UInt8]) -> [UInt8] {
        lock.withLock {
            if let id = ids[epoch] { return id }
            let id = make()
            made += 1
            // Only epochs around now are ever asked for again.
            if ids.count >= 6 { ids = ids.filter { abs($0.key - epoch) <= 2 } }
            ids[epoch] = id
            return id
        }
    }
}
