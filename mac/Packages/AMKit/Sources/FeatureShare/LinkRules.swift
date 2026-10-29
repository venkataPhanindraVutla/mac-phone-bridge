import Foundation

/// Which text is a `share.link` (SPEC section 15): one `http` or `https` URL with a host, at
/// most 8,192 bytes of UTF-8 once trimmed. Anything else goes, and is handled, as `share.text`.
/// Close to the phone's `ShareClassifier.linkOrNull`, but stricter: the phone's `java.net.URI`
/// accepts non-ASCII characters (`https://example.com/café`), this does not. Such a link from
/// the phone is handled as text here: it lands on the pasteboard instead of opening.
public enum LinkRules {
    public static let maxBytes = 8_192

    /// `s` trimmed, as a URL, when it is a link; else nil.
    public static func link(_ s: String) -> URL? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maxBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              // No repairs: text that is not already a valid URL is not a link.
              let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true), !host.isEmpty
        else { return nil }
        return url
    }
}
