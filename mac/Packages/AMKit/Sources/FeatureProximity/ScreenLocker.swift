import Foundation

/// Locks the Mac's screen. Nothing here ever unlocks it (PRD F-15).
@MainActor
public protocol ScreenLocker: AnyObject {
    /// Whether this macOS can lock this way; false shows "Locking isn't available on this macOS version".
    var available: Bool { get }
    /// Locks now. False when locking isn't available.
    func lock() -> Bool
}

/// Locks through `SACLockScreenImmediate` in the private login framework, the call behind the
/// Lock Screen menu item. It is looked up at run time with `dlopen`/`dlsym`, so the binary links
/// no private symbol, and a macOS without it reads as unavailable and never locks. No synthetic
/// Ctrl-Cmd-Q and no Accessibility.
@MainActor
public final class LoginFrameworkLocker: ScreenLocker {
    public static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    public static let symbolName = "SACLockScreenImmediate"

    private typealias LockFunction = @convention(c) () -> Int32
    private let lockFunction: LockFunction?

    /// `path` and `symbol` are for tests.
    public init(path: String = LoginFrameworkLocker.frameworkPath, symbol: String = LoginFrameworkLocker.symbolName) {
        lockFunction = Self.resolve(path: path, symbol: symbol)
    }

    public var available: Bool { lockFunction != nil }

    public func lock() -> Bool {
        guard let lockFunction else { return false }
        // Its result isn't documented; asking for the lock is what counts.
        _ = lockFunction()
        return true
    }

    /// The handle stays open for the life of the process.
    private static func resolve(path: String, symbol: String) -> LockFunction? {
        guard let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: LockFunction.self)
    }
}
