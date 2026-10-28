import Testing
@testable import FeatureNotify

@Test(arguments: [
    ("Google", "G-482913 is your Google verification code.", "482913"),
    ("WhatsApp", "Your WhatsApp code: 123-456", "123456"),
    ("Bank", "Your OTP is 7391. Do not share it.", "7391"),
    ("Uber", "Your Uber code is 1234 5678", "12345678"),
    ("Login", "Use 004219 to sign in", "004219"),
    ("Bank", "Rs 4500 debited from a/c XX1234 on 28/10. OTP not required.", nil),
    ("Ana", "See you at 12:30, code red lol", nil),
    ("Delivery", "Order 12345678901 shipped", nil),
    ("Ana", "call me on 98765 43210", nil),
    ("Calendar", "Meeting 2026-10-28 login link", nil),
    ("Ana", "hi 👋", nil),
] as [(String, String, String?)])
func detectsCodes(title: String, text: String, expected: String?) {
    #expect(OneTimeCode.detect(title: title, text: text) == expected)
}
