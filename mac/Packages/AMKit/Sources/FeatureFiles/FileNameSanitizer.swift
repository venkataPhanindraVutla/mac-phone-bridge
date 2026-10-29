import Foundation

/// The file-name rule of SPEC section 16, the same on both sides (`protocol/vectors/filenames.json`).
/// It works on Unicode scalars, as the rule does, never on grapheme clusters.
public enum FileNameSanitizer {
    static let maxBytes = 255
    static let extensionMaxBytes = 16

    /// A safe single path component: no directories, no control or bidi characters, no leading
    /// dots or spaces, never empty, at most 255 bytes of UTF-8 with a short extension kept.
    public static func sanitize(_ raw: String) -> String {
        var s = Array(raw.unicodeScalars)
        if let slash = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) { s = Array(s[(slash + 1)...]) }
        s.removeAll(where: isRemoved)
        s = Array(s.drop(while: { $0 == "." || $0 == " " }))
        while s.last == " " { s.removeLast() }
        guard !s.isEmpty else { return "file" }
        var name = string(s)
        if name.utf8.count > maxBytes {
            let (stem, ext) = split(s)
            name = string(stripTrailingDotsAndSpaces(cut(stem, maxBytes - utf8Count(ext)))) + string(ext)
        }
        return name
    }

    /// `name` if `exists` says it is free, else `stem (n).ext` with the smallest free n >= 1,
    /// still within 255 bytes. `exists` should compare by `key`, as the rule says.
    public static func unique(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let (stem, ext) = split(Array(name.unicodeScalars))
        var n = 1
        while true {
            let suffix = " (\(n))" + string(ext)
            let candidate = string(stripTrailingDotsAndSpaces(cut(stem, maxBytes - suffix.utf8.count))) + suffix
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Two names collide when their keys are equal: lowercase(NFC(name)), locale-independent.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: private

    private static func isRemoved(_ c: Unicode.Scalar) -> Bool {
        c.value <= 0x1F || c.value == 0x7F || (0x202A...0x202E).contains(c.value) || (0x2066...0x2069).contains(c.value)
    }

    /// (stem, extension) where the extension starts at the last dot (not the first scalar) and
    /// is at most 16 bytes; otherwise (name, []).
    private static func split(_ s: [Unicode.Scalar]) -> ([Unicode.Scalar], [Unicode.Scalar]) {
        if let dot = s.lastIndex(of: "."), dot > 0, utf8Count(Array(s[dot...])) <= extensionMaxBytes {
            return (Array(s[..<dot]), Array(s[dot...]))
        }
        return (s, [])
    }

    /// The longest prefix of at most `maxBytes` bytes of UTF-8.
    private static func cut(_ s: [Unicode.Scalar], _ maxBytes: Int) -> [Unicode.Scalar] {
        var used = 0
        var out: [Unicode.Scalar] = []
        for c in s {
            let n = UTF8.width(c)
            if used + n > maxBytes { break }
            out.append(c)
            used += n
        }
        return out
    }

    private static func stripTrailingDotsAndSpaces(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var s = s
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s
    }

    private static func utf8Count(_ s: [Unicode.Scalar]) -> Int { s.reduce(0) { $0 + UTF8.width($1) } }

    private static func string(_ s: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return String(view)
    }
}
