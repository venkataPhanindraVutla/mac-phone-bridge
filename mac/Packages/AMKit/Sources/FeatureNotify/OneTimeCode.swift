/// Detects a one-time code (OTP) in a notification. Pure and stateless; English only.
public enum OneTimeCode {
    private static let keywordPattern =
        #"(?i)\b(?:code|otp|verification|verify|passcode|password|pin|one-time|one time|2fa|security code|login|log in|sign in|authentication)\b"#
    // Order matters: Google form, then digit groups, then a plain 4-8 digit run.
    private static let candidatePattern =
        #"G-\d{6}(?!\d)|\d{3,4}[ -]\d{3,4}(?!\d)|\d{4,8}(?!\d)"#
    private static let currencyMarkers = ["$", "€", "£", "₹", "rs", "inr", "usd", "eur"]

    /// Returns the code with spaces and dashes removed (and any `G-` prefix dropped), or nil.
    public static func detect(title: String, text: String) -> String? {
        let haystack = title + "\n" + text
        guard let keywordRegex = try? Regex(keywordPattern),
              let candidateRegex = try? Regex(candidatePattern) else { return nil }

        let chars = Array(haystack)
        func offset(_ i: String.Index) -> Int { haystack.distance(from: haystack.startIndex, to: i) }

        let keywords = haystack.matches(of: keywordRegex).map { (offset($0.range.lowerBound), offset($0.range.upperBound)) }
        guard !keywords.isEmpty else { return nil }

        var best: (distance: Int, code: String)?
        for match in haystack.matches(of: candidateRegex) {
            let start = offset(match.range.lowerBound), end = offset(match.range.upperBound)
            guard isStandalone(chars, start: start, end: end) else { continue }
            let distance = keywords.map { k in
                k.1 <= start ? start - k.1 : (end <= k.0 ? k.0 - end : 0)
            }.min()!
            if best == nil || distance < best!.distance {
                let raw = String(haystack[match.range])
                let code = raw.hasPrefix("G-") ? String(raw.dropFirst(2)) : raw.filter { $0 != " " && $0 != "-" }
                best = (distance, code)
            }
        }
        return best?.code
    }

    /// Rejects amounts, times, dates, phone-number-like runs, and tokens glued to letters.
    private static func isStandalone(_ c: [Character], start: Int, end: Int) -> Bool {
        let joiners: Set<Character> = [":", "/", ".", ","]
        let isGoogle = c[start] == "G"
        if start > 0, c[start - 1].isLetter || c[start - 1].isNumber { return false }  // "XX1234", inside a longer run
        if start > 0, joiners.contains(c[start - 1]) { return false }                // "12:3045", "1.2345"
        if end + 1 < c.count, joiners.contains(c[end]), c[end + 1].isNumber { return false }  // "1234/56"
        if !isGoogle {
            // Neighbouring digit group joined by one space/dash: "98765 43210", "2026-10-28".
            let plain = !c[start..<end].contains { $0 == " " || $0 == "-" }
            if plain {
                if end + 1 < c.count, c[end] == " " || c[end] == "-", c[end + 1].isNumber { return false }
                if start > 1, c[start - 1] == " " || c[start - 1] == "-", c[start - 2].isNumber { return false }
            }
        }
        // Currency marker within 2 characters before the amount ("Rs 4500", "$4500").
        let window = String(c[max(0, start - 4)..<start]).lowercased()
        for marker in currencyMarkers where window.hasSuffix(marker) || window.hasSuffix(marker + " ") {
            return false
        }
        return true
    }
}
