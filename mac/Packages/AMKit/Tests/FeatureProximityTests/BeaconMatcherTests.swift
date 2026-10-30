import AMProtocol
import Foundation
import Testing
@testable import FeatureProximity

private let key = Data((0..<32).map { UInt8($0) })
private let phoneA = Data(repeating: 0xA1, count: 32)
private let phoneB = Data(repeating: 0xB2, count: 32)
/// 30 s into an epoch.
private let unix: Int64 = 2_000_000_000 / 900 * 900 + 30
private let epoch = PairingCrypto.epoch(unixSeconds: unix)

private func id(_ phone: Data, _ epoch: Int64) -> Data {
    PairingCrypto.bleID(discoveryKey: key, phoneFingerprint: phone, epoch: epoch)
}

@Test func currentAndNextEpochIdsMatch() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    #expect(m.matches(id(phoneA, epoch), unixSeconds: unix))
    #expect(m.matches(id(phoneA, epoch + 1), unixSeconds: unix))
}

@Test func previousEpochIdStillMatches() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    #expect(m.matches(id(phoneA, epoch - 1), unixSeconds: unix))
    // Just after a boundary the phone may not have rotated yet.
    let boundary = (epoch + 1) * 900
    #expect(m.matches(id(phoneA, epoch), unixSeconds: boundary))
}

@Test func twoEpochsAwayDoesNotMatch() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    #expect(!m.matches(id(phoneA, epoch - 2), unixSeconds: unix))
    #expect(!m.matches(id(phoneA, epoch + 2), unixSeconds: unix))
}

@Test func otherPairedPhoneDoesNotCountAsNear() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    for e in (epoch - 1)...(epoch + 1) { #expect(!m.matches(id(phoneB, e), unixSeconds: unix)) }
    // Another Mac's key with the same phone doesn't match either.
    let otherMac = BeaconMatcher(discoveryKey: Data(repeating: 7, count: 32), phoneFingerprint: phoneA)
    #expect(!otherMac.matches(id(phoneA, epoch), unixSeconds: unix))
}

@Test func wrongLengthIsIgnored() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    let good = id(phoneA, epoch)
    #expect(!m.matches(Data(), unixSeconds: unix))
    #expect(!m.matches(good.prefix(7), unixSeconds: unix))
    #expect(!m.matches(good + Data([0]), unixSeconds: unix))
    // A slice whose indices don't start at 0 still compares by content.
    let padded = Data([9, 9]) + good
    #expect(m.matches(padded.suffix(8), unixSeconds: unix))
}

@Test func idsAreComputedOncePerEpoch() {
    let m = BeaconMatcher(discoveryKey: key, phoneFingerprint: phoneA)
    for _ in 0..<100 { _ = m.matches(id(phoneA, epoch), unixSeconds: unix) }
    #expect(m.computedCount == 3)
    // The next epoch needs one more.
    _ = m.matches(id(phoneA, epoch + 1), unixSeconds: unix + 900)
    #expect(m.computedCount == 4)
    // Hours later the old ones are dropped and it keeps working.
    for step in Int64(2)...20 { #expect(m.matches(id(phoneA, epoch + step), unixSeconds: unix + step * 900)) }
}
