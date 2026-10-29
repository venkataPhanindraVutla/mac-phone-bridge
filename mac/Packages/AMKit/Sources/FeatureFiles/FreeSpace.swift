import Foundation

public enum FreeSpace {
    /// Bytes free for important data on `url`'s volume, or nil when unknown.
    public static func available(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
