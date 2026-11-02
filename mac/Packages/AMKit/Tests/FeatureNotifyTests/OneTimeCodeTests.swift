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
    ("Ana", "Verify your numbers 4821", "4821"),
    ("Ana", "Your code for Mars 4821", "4821"),
    ("Ana", "Users 4821 code", "4821"),
    ("Bank", "Rs 4500 debited, OTP 1234", "1234"),
    ("Bank", "$ 4500 code", nil),
    ("Ana", "9999 and your code is 1234", "1234"),
    ("Ana", "login 1234 then 5678 code", "1234"),
    ("Calendar", "Meeting 28 Oct 2026 login link", nil),
    ("Ana", "Your login code 2026", "2026"),
    ("Ana", "call 123-456-7890 code", nil),
    ("Ana", "code 987 654 3210", nil),
    ("Ana", "Your code is 4821ms", nil),
    ("認証", "認証 code：123456を入力してください", "123456"),
    ("验证", "验证 code 123456是你的", "123456"),
    ("Ana", "Your code is 4821.", "4821"),
    ("Calendar", "Meeting Oct 28, 2026 login link", nil),
    ("Calendar", "Meeting Oct 28 2026 login link", nil),
    ("Calendar", "Meeting October 5, 2026 login link", nil),
] as [(String, String, String?)])
func detectsCodes(title: String, text: String, expected: String?) {
    #expect(OneTimeCode.detect(title: title, text: text) == expected)
}
