import AMProtocol
import CryptoKit
import Foundation

public enum PairingVerdict: Equatable, Sendable {
    case verified(code: String)
    case rejected(AMErrorCode)
}

public enum PairingOutcome: Equatable, Sendable {
    case waiting, paired, cancelled, timedOut
}

/// Pure state machine for SPEC section 5.3, with no I/O and no clock of its own.
/// States: open -> verified(at:) -> paired | cancelled | timedOut. The secret is "burned"
/// (every later verify returns pairingExpired) after 3 bad proofs, 1 successful verify, or
/// once `lifetime` has passed. Boundaries are inclusive: exactly +300 s and exactly +60 s are
/// still in time.
public final class MacPairingFlow: @unchecked Sendable {
    public static let maxBadAttempts = 3
    public static let confirmationTimeout: TimeInterval = 60

    public let secret: Data

    private enum State {
        case open
        case verified(at: Date, local: Bool, remote: Bool)
        case paired, cancelled, timedOut
    }

    private let lock = NSLock()
    private let macFingerprint: Data
    private let openedAt: Date
    private let lifetime: TimeInterval
    private var state: State = .open
    private var badAttempts = 0
    private var burned = false

    public init(macFingerprint: Data, now: Date, lifetime: TimeInterval = 300,
                secret: Data = PairingCrypto.randomBytes(32)) {
        self.macFingerprint = macFingerprint
        self.openedAt = now
        self.lifetime = lifetime
        self.secret = secret
    }

    public func verify(_ request: AMPairRequest, phoneFingerprint: Data, now: Date) -> PairingVerdict {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(openedAt) > lifetime { burned = true }
        if burned { return .rejected(.pairingExpired) }
        guard case .open = state else { return .rejected(.pairingExpired) }
        guard request.protocolVersion == Handshake.protocolVersion else {
            return .rejected(.protocolMismatch)
        }
        let key = SymmetricKey(data: secret)
        let expected = PairingCrypto.secretProof(
            secret: secret, macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint)
        // Constant-time: MAC both proofs under the secret and let CryptoKit compare the MACs
        // (equal iff the proofs are equal), never `Data ==` on the proofs themselves.
        let given = HMAC<SHA256>.authenticationCode(for: request.secretProof, using: key)
        let ok = HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: expected, using: key)
        guard ok else {
            badAttempts += 1
            if badAttempts >= Self.maxBadAttempts { burned = true }
            return .rejected(.badPairingSecret)
        }
        burned = true
        state = .verified(at: now, local: false, remote: false)
        return .verified(code: PairingCrypto.confirmationCode(
            macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint))
    }

    public func localDecision(_ accepted: Bool, now: Date) -> PairingOutcome {
        decide(accepted, isLocal: true, now: now)
    }

    public func remoteDecision(_ accepted: Bool, now: Date) -> PairingOutcome {
        decide(accepted, isLocal: false, now: now)
    }

    private func decide(_ accepted: Bool, isLocal: Bool, now: Date) -> PairingOutcome {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .paired: return .paired
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .open:
            // No verified phone, so there is nothing to confirm.
            state = .cancelled
            burned = true
            return .cancelled
        case let .verified(at, local, remote):
            if now.timeIntervalSince(at) > Self.confirmationTimeout {
                state = .timedOut
                return .timedOut
            }
            guard accepted else {
                state = .cancelled
                return .cancelled
            }
            let l = local || isLocal
            let r = remote || !isLocal
            if l && r {
                state = .paired
                return .paired
            }
            state = .verified(at: at, local: l, remote: r)
            return .waiting
        }
    }
}
