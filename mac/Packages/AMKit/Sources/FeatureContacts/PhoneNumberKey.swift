import Foundation

/// Turns a phone number as written anywhere (a contact, a notification title) into a key that two
/// spellings of the same number share: its digits, last 10.
public enum PhoneNumberKey {
    /// Digits only (so spaces, punctuation, bidi marks and no-break spaces all drop out), the last
    /// 10 of them, which ignores a country code or a trunk prefix. Nil with fewer than 7 digits:
    /// short codes and emergency numbers never match a contact.
    public static func key(_ raw: String) -> String? {
        let digits = raw.unicodeScalars.compactMap { s -> Character? in
            guard s.properties.numericType == .decimal, let v = s.properties.numericValue else { return nil }
            return Character(String(Int(v)))
        }
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }
}
