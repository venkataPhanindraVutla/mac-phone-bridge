import Testing
@testable import FeatureContacts

@Test func keyUsesLast10Digits() {
    #expect(PhoneNumberKey.key("+91 98765 43210") == "9876543210")
    #expect(PhoneNumberKey.key("(415) 555-0100") == "4155550100")
    #expect(PhoneNumberKey.key("112") == nil)
}

@Test func keyKeepsShortButPlausibleNumbers() {
    #expect(PhoneNumberKey.key("555-0100") == "5550100")
    #expect(PhoneNumberKey.key("") == nil)
    #expect(PhoneNumberKey.key("123456") == nil)
}

@Test func keyIgnoresBidiMarksAndNoBreakSpaces() {
    #expect(PhoneNumberKey.key("\u{2066}+91 98765 43210\u{2069}") == "9876543210")
    #expect(PhoneNumberKey.key("+91\u{00A0}98765\u{00A0}43210") == "9876543210")
    #expect(PhoneNumberKey.key("\u{200E}(415)\u{202F}555\u{2011}0100") == "4155550100")
}

@Test func keyReadsNonAsciiDigits() {
    // Arabic-Indic digits, as some phones format numbers.
    #expect(PhoneNumberKey.key("٩٨٧٦٥٤٣٢١٠") == "9876543210")
}
