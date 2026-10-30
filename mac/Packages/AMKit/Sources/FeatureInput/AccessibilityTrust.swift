import ApplicationServices

/// Whether this app may post events (Privacy & Security › Accessibility).
@MainActor
public protocol AccessibilityTrust: AnyObject {
    /// With `prompt`, macOS shows its "would like to control this computer" alert when not yet
    /// trusted. Only turning pointer control on asks with `prompt`.
    func isTrusted(prompt: Bool) -> Bool
}

/// Known limitation: an ad-hoc signed build (the contributor default) has a new code identity
/// on every rebuild, so macOS forgets its Accessibility grant and the user must allow it again.
/// A build signed with a team keeps the grant.
@MainActor
public final class SystemAccessibilityTrust: AccessibilityTrust {
    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        // The value of kAXTrustedCheckOptionPrompt.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
