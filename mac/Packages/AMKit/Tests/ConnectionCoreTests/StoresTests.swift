import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

private func phone(_ n: UInt8) -> PairedPhone {
    let der = Data(repeating: n, count: 16)
    let fp = PairingCrypto.fingerprint(certificateDER: der)
    return PairedPhone(id: fp.map { String(format: "%02x", $0) }.joined(), name: "P\(n)", model: "M",
                       certificateDER: der, pairedAt: Date(timeIntervalSince1970: 1))
}

@Test func pairedPhoneFingerprintMatchesId() {
    let p = phone(1)
    #expect(p.fingerprint.map { String(format: "%02x", $0) }.joined() == p.id)
}

@Test func pairedPhoneStoreSavesReplacesAndRemoves() throws {
    let s = InMemoryPairedPhoneStore()
    try s.save(phone(1)); try s.save(phone(2))
    #expect(try s.all().count == 2)
    var renamed = phone(1); renamed.name = "New"
    try s.save(renamed)
    #expect(try s.all().count == 2)
    #expect(try s.all().first { $0.id == renamed.id }?.name == "New")
    try s.remove(id: renamed.id)
    #expect(try s.all().map(\.id) == [phone(2).id])
}

@Test func secretStoreCreatesKeyOnceAndKeepsIt() throws {
    let s = InMemorySecretStore()
    let a = try s.discoveryKey()
    #expect(a.count == 32)
    #expect(try s.discoveryKey() == a)
    #expect(try InMemorySecretStore().discoveryKey() != a)
}
