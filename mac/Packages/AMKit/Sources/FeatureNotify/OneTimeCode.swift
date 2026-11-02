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
        if end < c.count, c[end].isLetter { return false }                           // "4821ms"
        if start > 0, joiners.contains(c[start - 1]) { return false }                // "12:3045", "1.2345"
        if end + 1 < c.count, joiners.contains(c[end]), c[end + 1].isNumber { return false }  // "1234/56"
        if !isGoogle {
            // Neighbouring digit group joined by one space/dash: "98765 43210", "2026-10-28", "123-456-7890".
            if end + 1 < c.count, c[end] == " " || c[end] == "-", c[end + 1].isNumber { return false }
            if start > 1, c[start - 1] == " " || c[start - 1] == "-", c[start - 2].isNumber { return false }
        }
        // Currency marker within 2 characters before the amount ("Rs 4500", "$4500").
        // Letter markers must start a word, so "Mars 4821" / "Verify" are not amounts.
        let gap = start > 0 && c[start - 1] == " " ? 1 : 0
        let markerEnd = start - gap
        for marker in currencyMarkers {
            let chars = Array(marker)
            let markerStart = markerEnd - chars.count
            guard markerStart >= 0, String(c[markerStart..<markerEnd]).lowercased() == marker else { continue }
            if !(marker.first!.isLetter) || markerStart == 0 || !c[markerStart - 1].isLetter { return false }
        }
        // A year next to a month name ("28 Oct 2026") is a date, not a code.
        if end - start == 4, c[start...].prefix(2).elementsEqual(["1", "9"]) || c[start...].prefix(2).elementsEqual(["2", "0"]),
           isMonth(wordBefore(c, start)) || isMonth(wordAfter(c, end)) || followsMonthAndDay(c, start) { return false }
        return true
    }

    private static let months: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        "january", "february", "march", "april", "june", "july", "august", "september", "sept", "october",
        "november", "december",
    ]

    private static func isMonth(_ word: String) -> Bool { months.contains(word.lowercased()) }

    private static func wordBefore(_ c: [Character], _ start: Int) -> String {
        var i = start
        while i > 0, c[i - 1] == " " { i -= 1 }
        var word: [Character] = []
        while i > 0, c[i - 1].isLetter { word.insert(c[i - 1], at: 0); i -= 1 }
        return String(word)
    }

    /// "<month> <1-2 digit day>[,] " right before `start`: "Oct 28, 2026".
    private static func followsMonthAndDay(_ c: [Character], _ start: Int) -> Bool {
        var i = start
        while i > 0, c[i - 1] == " " { i -= 1 }
        if i > 0, c[i - 1] == "," { i -= 1 }
        var digits = 0
        while i > 0, c[i - 1].isNumber { i -= 1; digits += 1 }
        guard (1...2).contains(digits) else { return false }
        return isMonth(wordBefore(c, i))
    }

    private static func wordAfter(_ c: [Character], _ end: Int) -> String {
        var i = end
        while i < c.count, c[i] == " " { i += 1 }
        var word: [Character] = []
        while i < c.count, c[i].isLetter { word.append(c[i]); i += 1 }
        return String(word)
    }
}
