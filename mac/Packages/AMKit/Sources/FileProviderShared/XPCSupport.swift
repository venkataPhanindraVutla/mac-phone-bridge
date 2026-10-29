import Foundation

/// The app's running downloads and uploads for the extension, by the extension's token (ruling
/// R20). `cancel` runs the call's cancel action once; a cancel that arrives before its call
/// (the two hop separately) is remembered, and that call is cancelled as it begins.
public final class CancelTokens: @unchecked Sendable {
    /// Early cancels remembered at most; older ones are forgotten.
    public static let rememberedEarly = 256

    private let lock = NSLock()
    private var active: [String: @Sendable () -> Void] = [:]
    private var early: [String] = []

    public init() {}

    public var activeCount: Int { lock.withLock { active.count } }

    /// Registers the call `token` names; if it was cancelled already, `onCancel` runs now.
    public func begin(_ token: String, onCancel: @escaping @Sendable () -> Void) {
        let cancelledAlready: Bool = lock.withLock {
            if let i = early.firstIndex(of: token) {
                early.remove(at: i)
                return true
            }
            active[token] = onCancel
            return false
        }
        if cancelledAlready { onCancel() }
    }

    public func cancel(_ token: String) {
        let action: (@Sendable () -> Void)? = lock.withLock {
            if let action = active.removeValue(forKey: token) { return action }
            early.append(token)
            if early.count > Self.rememberedEarly { early.removeFirst(early.count - Self.rememberedEarly) }
            return nil
        }
        action?()
    }

    /// The call ended: a later cancel finds nothing.
    public func end(_ token: String) {
        _ = lock.withLock { active.removeValue(forKey: token) }
    }
}

/// A cancel action that may be set after a cancel was asked for: it then runs at once.
public final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var cancelled = false

    public init() {}

    public func set(_ action: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            if cancelled { return true }
            self.action = action
            return false
        }
        if now { action() }
    }

    public func cancel() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { self.action = nil }
            return self.action
        }
        action?()
    }
}

/// The extension's connection to the app, with its calls counted. A new endpoint replaces the
/// connection for new calls; the old one is invalidated once its last outstanding call ends,
/// never under one. Each method returns the connection to invalidate now, if any.
public final class ConnectionSlot<C: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: C?
    private var outstanding: [ObjectIdentifier: Int] = [:]
    /// Replaced connections waiting for their calls to end.
    private var retiring: [ObjectIdentifier: C] = [:]

    public init() {}

    /// A current connection that the system has not invalidated.
    public var hasLive: Bool { lock.withLock { current != nil } }

    /// The current connection, with one more call out on it.
    public func begin() -> C? {
        lock.withLock {
            guard let current else { return nil }
            outstanding[ObjectIdentifier(current), default: 0] += 1
            return current
        }
    }

    /// A call on `c` ended. Returns `c` when it was replaced and this was its last call.
    public func end(_ c: C) -> C? {
        lock.withLock {
            let id = ObjectIdentifier(c)
            let left = max(0, (outstanding[id] ?? 1) - 1)
            outstanding[id] = left == 0 ? nil : left
            guard left == 0, let retired = retiring.removeValue(forKey: id) else { return nil }
            return retired
        }
    }

    /// `new` takes over. Returns the old connection when it has no calls out; a busy one is
    /// returned by `end` later.
    public func replace(with new: C) -> C? {
        lock.withLock {
            let old = current
            current = new
            guard let old, old !== new else { return nil }
            let id = ObjectIdentifier(old)
            if outstanding[id] ?? 0 > 0 {
                retiring[id] = old
                return nil
            }
            return old
        }
    }

    /// The system invalidated `c`: it is forgotten.
    public func dropped(_ c: C) {
        lock.withLock {
            let id = ObjectIdentifier(c)
            if current === c { current = nil }
            retiring.removeValue(forKey: id)
            outstanding.removeValue(forKey: id)
        }
    }
}

/// Code-signing requirements that pin the XPC peer (`NSXPCConnection.setCodeSigningRequirement`).
public enum CodeRequirement {
    public static let appID = "io.github.anmirror.mac"
    public static let fileProviderID = "io.github.anmirror.mac.fileprovider"

    /// The peer must be `identifier` signed by `team`; nil without a team (an ad hoc or unsigned
    /// build has no certificate to pin, and pinning would refuse every peer).
    public static func peer(identifier: String, team: String?) -> String? {
        guard let team, team.count == 10,
              team.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return nil }
        return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
    }
}
