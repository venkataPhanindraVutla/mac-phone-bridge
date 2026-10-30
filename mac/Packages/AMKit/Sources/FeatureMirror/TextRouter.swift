/// How committed text reaches the phone.
public enum TextRoute: Equatable, Sendable {
    /// INJECT_TEXT (printable ASCII; at most 300 bytes each).
    case inject(String)
    /// SET_CLIPBOARD with paste: the phone's key injection cannot type it (emoji, other scripts,
    /// control characters), but every app can take a paste.
    case paste(String)
}

public enum TextRouter {
    /// Printable ASCII (every scalar U+0020–U+007E) is injected, in chunks of at most 300 bytes;
    /// anything else is one paste.
    public static func route(_ committed: String) -> [TextRoute] {
        guard !committed.isEmpty else { return [] }
        guard committed.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return [.paste(committed)] }
        return chunks(committed, maxBytes: ScrcpyControl.injectTextMaxBytes).map(TextRoute.inject)
    }

    /// `s` cut into pieces of at most `maxBytes` UTF-8 bytes, each cut at a Unicode scalar boundary.
    static func chunks(_ s: String, maxBytes: Int) -> [String] {
        var out: [String] = []
        var piece = String.UnicodeScalarView()
        var bytes = 0
        for scalar in s.unicodeScalars {
            let n = UTF8.width(scalar)
            if bytes + n > maxBytes, !piece.isEmpty {
                out.append(String(piece))
                piece = String.UnicodeScalarView()
                bytes = 0
            }
            piece.append(scalar)
            bytes += n
        }
        if !piece.isEmpty { out.append(String(piece)) }
        return out
    }
}
