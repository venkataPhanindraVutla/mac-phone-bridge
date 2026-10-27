import AMProtocol
import Foundation
import Testing
@testable import ConnectionCore

private let macFP = Data((0..<32).map { UInt8($0) })
private let phoneFP = Data((0..<32).map { UInt8(100 + $0) })
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func makeFlow() -> MacPairingFlow {
    MacPairingFlow(macFingerprint: macFP, now: t0, secret: Data(repeating: 7, count: 32))
}

private func request(_ flow: MacPairingFlow, version: UInt32 = 1, good: Bool = true) -> AMPairRequest {
    var r = AMPairRequest()
    r.protocolVersion = version
    r.secretProof = good
        ? PairingCrypto.secretProof(secret: flow.secret, macFingerprint: macFP, phoneFingerprint: phoneFP)
        : Data(repeating: 0, count: 32)
    r.deviceName = "Pixel"
    r.deviceModel = "Pixel 8"
    return r
}

private func verified(_ flow: MacPairingFlow, at now: Date = t0) -> PairingVerdict {
    flow.verify(request(flow), phoneFingerprint: phoneFP, now: now)
}

@Test func validProofIsVerifiedWithMatchingCode() {
    let flow = makeFlow()
    let expected = PairingCrypto.confirmationCode(macFingerprint: macFP, phoneFingerprint: phoneFP)
    #expect(verified(flow) == .verified(code: expected))
}

@Test func defaultSecretIs32RandomBytes() {
    let a = MacPairingFlow(macFingerprint: macFP, now: t0)
    let b = MacPairingFlow(macFingerprint: macFP, now: t0)
    #expect(a.secret.count == 32)
    #expect(a.secret != b.secret)
}

@Test func wrongProtocolVersionIsRejected() {
    let flow = makeFlow()
    #expect(flow.verify(request(flow, version: 2), phoneFingerprint: phoneFP, now: t0) == .rejected(.protocolMismatch))
}

@Test func badProofIsRejected() {
    let flow = makeFlow()
    #expect(flow.verify(request(flow, good: false), phoneFingerprint: phoneFP, now: t0) == .rejected(.badPairingSecret))
}

@Test func proofBoundToPhoneFingerprint() {
    let flow = makeFlow()
    let other = Data(repeating: 9, count: 32)
    #expect(flow.verify(request(flow), phoneFingerprint: other, now: t0) == .rejected(.badPairingSecret))
}

@Test func threeBadProofsBurnTheSecret() {
    let flow = makeFlow()
    for _ in 0..<3 {
        #expect(flow.verify(request(flow, good: false), phoneFingerprint: phoneFP, now: t0) != .verified(code: ""))
    }
    #expect(verified(flow) == .rejected(.pairingExpired))
}

@Test func twoBadProofsDoNotBurnTheSecret() {
    let flow = makeFlow()
    for _ in 0..<2 { _ = flow.verify(request(flow, good: false), phoneFingerprint: phoneFP, now: t0) }
    if case .verified = verified(flow) {} else { Issue.record("expected verified") }
}

@Test func secretIsSingleUse() {
    let flow = makeFlow()
    if case .verified = verified(flow) {} else { Issue.record("expected verified") }
    #expect(verified(flow) == .rejected(.pairingExpired))
}

@Test func secretExpiresAfterFiveMinutes() {
    let late = makeFlow()
    #expect(verified(late, at: t0.addingTimeInterval(300.001)) == .rejected(.pairingExpired))
    let edge = makeFlow()
    if case .verified = verified(edge, at: t0.addingTimeInterval(300)) {} else { Issue.record("300 s inclusive") }
    let early = makeFlow()
    if case .verified = verified(early, at: t0.addingTimeInterval(299)) {} else { Issue.record("299 s valid") }
}

@Test func expiredSecretStaysExpiredEvenForEarlierClock() {
    let flow = makeFlow()
    _ = verified(flow, at: t0.addingTimeInterval(301))
    #expect(verified(flow, at: t0) == .rejected(.pairingExpired))
}

@Test func pairsOnlyWhenBothSidesAccept() {
    let a = makeFlow()
    _ = verified(a)
    #expect(a.localDecision(true, now: t0) == .waiting)
    #expect(a.remoteDecision(true, now: t0) == .paired)
    let b = makeFlow()
    _ = verified(b)
    #expect(b.remoteDecision(true, now: t0) == .waiting)
    #expect(b.localDecision(true, now: t0) == .paired)
}

@Test func eitherSideDecliningCancels() {
    let a = makeFlow()
    _ = verified(a)
    #expect(a.localDecision(false, now: t0) == .cancelled)
    #expect(a.remoteDecision(true, now: t0) == .cancelled)
    let b = makeFlow()
    _ = verified(b)
    #expect(b.localDecision(true, now: t0) == .waiting)
    #expect(b.remoteDecision(false, now: t0) == .cancelled)
}

@Test func decisionBeforeVerificationCancels() {
    let flow = makeFlow()
    #expect(flow.localDecision(true, now: t0) == .cancelled)
}

@Test func confirmationTimesOutAfter60Seconds() {
    let late = makeFlow()
    _ = verified(late)
    #expect(late.localDecision(true, now: t0.addingTimeInterval(60.001)) == .timedOut)
    #expect(late.remoteDecision(true, now: t0.addingTimeInterval(61)) == .timedOut)
    let edge = makeFlow()
    _ = verified(edge)
    #expect(edge.localDecision(true, now: t0.addingTimeInterval(60)) == .waiting)
    #expect(edge.remoteDecision(true, now: t0.addingTimeInterval(60)) == .paired)
}

@Test func timeoutCountsFromVerificationNotFromOpen() {
    let flow = makeFlow()
    let v = t0.addingTimeInterval(200)
    _ = verified(flow, at: v)
    #expect(flow.localDecision(true, now: v.addingTimeInterval(60)) == .waiting)
}

@Test func secondDecisionAfterTimeoutTimesOut() {
    let flow = makeFlow()
    _ = verified(flow)
    #expect(flow.localDecision(true, now: t0.addingTimeInterval(10)) == .waiting)
    #expect(flow.remoteDecision(true, now: t0.addingTimeInterval(61)) == .timedOut)
}
