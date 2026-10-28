import Foundation

/// Per-phone notification settings, persisted by the app.
public struct NotifySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mutedPackages: Set<String>
    /// package -> app name, for the Settings list.
    public var seenApps: [String: String]

    public init(enabled: Bool = true, mutedPackages: Set<String> = [], seenApps: [String: String] = [:]) {
        self.enabled = enabled
        self.mutedPackages = mutedPackages
        self.seenApps = seenApps
    }
}
