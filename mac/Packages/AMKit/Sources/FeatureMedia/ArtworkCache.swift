import Foundation

/// The phone's track artwork by key (SPEC section 20), in memory only: the most recent `limit`
/// keys put, oldest dropped first. The phone sends each key once per connection, so the cache
/// is cleared on disconnect.
public struct ArtworkCache: Sendable {
    public let limit: Int
    /// Keys from oldest to newest put.
    private var order: [String] = []
    private var items: [String: Data] = [:]

    public init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    /// Keeps `jpeg` under `key` as the newest; the empty key (no artwork) holds nothing.
    public mutating func put(_ key: String, _ jpeg: Data) {
        guard !key.isEmpty else { return }
        if items[key] != nil { order.removeAll { $0 == key } }
        order.append(key)
        items[key] = jpeg
        while order.count > limit { items[order.removeFirst()] = nil }
    }

    public func get(_ key: String) -> Data? { items[key] }

    public mutating func clear() {
        order = []
        items = [:]
    }
}
