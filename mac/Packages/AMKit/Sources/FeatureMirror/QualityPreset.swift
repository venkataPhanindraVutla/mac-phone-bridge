import Foundation

/// The helper's `max_size`, `video_bit_rate` and `max_fps` (Global Constraints).
public struct QualityPreset: Equatable, Sendable, Hashable {
    /// The preset's name, for logs; the window shows its own localized title.
    public let name: String
    public let maxSize: UInt32
    public let bitRate: UInt32
    public let maxFps: UInt32

    public init(name: String, maxSize: UInt32, bitRate: UInt32, maxFps: UInt32) {
        self.name = name
        self.maxSize = maxSize
        self.bitRate = bitRate
        self.maxFps = maxFps
    }

    public static let high = QualityPreset(name: "high", maxSize: 1920, bitRate: 8_000_000, maxFps: 60)
    public static let balanced = QualityPreset(name: "balanced", maxSize: 1280, bitRate: 4_000_000, maxFps: 60)
    public static let low = QualityPreset(name: "low", maxSize: 960, bitRate: 2_000_000, maxFps: 30)
    /// High, Balanced, Low.
    public static let all: [QualityPreset] = [.high, .balanced, .low]
}
