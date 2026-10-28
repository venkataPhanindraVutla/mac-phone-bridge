import AMProtocol
import Foundation

/// What a redeemed bulk token was issued for: the connection's role and the transfer or
/// request it belongs to (SPEC section 13).
public struct BulkGrant: Equatable, Sendable {
    public let role: AMBulkRole
    public let context: String

    public init(role: AMBulkRole, context: String) {
        self.role = role
        self.context = context
    }
}

/// The Mac's outstanding bulk tokens: 32 random bytes each, single use, valid for
/// `lifetime` seconds (SPEC section 13). Not thread-safe; used on the main actor.
public final class BulkTokens {
    private struct Entry {
        let grant: BulkGrant
        let expires: Date
    }

    private let lifetime: TimeInterval
    private let now: () -> Date
    private let random: () -> Data
    private var entries: [Data: Entry] = [:]

    public init(lifetime: TimeInterval = 60, now: @escaping () -> Date = Date.init,
                random: @escaping () -> Data = { PairingCrypto.randomBytes(32) }) {
        self.lifetime = lifetime
        self.now = now
        self.random = random
    }

    public func issue(role: AMBulkRole, context: String) -> Data {
        let at = now()
        entries = entries.filter { $0.value.expires > at }
        let token = random()
        entries[token] = Entry(grant: BulkGrant(role: role, context: context), expires: at.addingTimeInterval(lifetime))
        return token
    }

    /// The grant for `token`, or nil if it is unknown, expired or was issued for another
    /// role. Any attempt uses the token up, so a wrong role cannot be retried.
    public func redeem(_ token: Data, role: AMBulkRole) -> BulkGrant? {
        guard let entry = entries.removeValue(forKey: token),
              entry.expires > now(),
              entry.grant.role == role
        else { return nil }
        return entry.grant
    }

    public func revoke(context: String) {
        entries = entries.filter { $0.value.grant.context != context }
    }

    public func revokeAll() {
        entries.removeAll()
    }
}
