import Foundation

/// File Provider item identifiers for phone files: `r/<rootID>/<path>`, with the root ID and the
/// `/`-separated path (SPEC section 19, `""` being the root) both percent-encoded down to the URI
/// unreserved characters, so `/` and `%` in either cannot be confused with the separators.
///
/// A decoded path is only ever handed back to the phone, which validates it as it would any
/// browse path. It is never used on the Mac's own disk.
public enum PhoneItemID {
    private static let prefix = "r/"
    /// RFC 3986 unreserved characters, ASCII only: everything else is encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(rootID: String, path: String) -> String {
        prefix + escape(rootID) + "/" + escape(path)
    }

    /// The root ID and path of an ID made by `encode`; nil for anything else, a File Provider
    /// container identifier included. Only the exact form `encode` makes decodes.
    public static func decode(_ id: String) -> (rootID: String, path: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let rootID = String(parts[0]).removingPercentEncoding, !rootID.isEmpty,
              let path = String(parts[1]).removingPercentEncoding,
              encode(rootID: rootID, path: path) == id
        else { return nil }
        return (rootID, path)
    }

    private static func escape(_ s: String) -> String {
        // Never nil for valid Swift strings (they are Unicode scalars).
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
