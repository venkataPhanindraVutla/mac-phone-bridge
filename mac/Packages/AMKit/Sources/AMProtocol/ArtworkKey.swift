import CryptoKit
import Foundation

/// Identifies a piece of media artwork: lowercase hex of the first 8 bytes of SHA-256 over the
/// JPEG bytes, or "" when there is no artwork. protocol/SPEC.md section 20.
public enum ArtworkKey {
    public static func of(_ jpeg: Data) -> String {
        guard !jpeg.isEmpty else { return "" }
        return SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
