import Testing
@testable import FeatureMirror

@Suite struct TextRouterTests {
    @Test func asciiGoesAsInjectText() {
        #expect(TextRouter.route("hello") == [.inject("hello")])
        #expect(TextRouter.route(" ~!az09{}") == [.inject(" ~!az09{}")])
        #expect(TextRouter.route("") == [])
    }

    @Test func emojiGoesAsClipboardPaste() {
        #expect(TextRouter.route("👋🏽") == [.paste("👋🏽")])
        #expect(TextRouter.route("hi 🇮🇳") == [.paste("hi 🇮🇳")])
    }

    @Test func nonLatinGoesAsPaste() {
        #expect(TextRouter.route("こんにちは") == [.paste("こんにちは")])
        #expect(TextRouter.route("привет") == [.paste("привет")])
        #expect(TextRouter.route("café") == [.paste("café")])
        // Control characters (a newline, a tab, DEL) are outside U+0020–U+007E too.
        #expect(TextRouter.route("a\nb") == [.paste("a\nb")])
        #expect(TextRouter.route("\t") == [.paste("\t")])
        #expect(TextRouter.route("\u{7F}") == [.paste("\u{7F}")])
    }

    /// AppKit's private-use function-key characters (F1 U+F704, F5 U+F708, F19 U+F716, Help U+F746,
    /// the top of the range U+F8FF) are dropped; text around them is kept.
    @Test func functionKeyCharactersAreDropped() {
        for key in ["\u{F704}", "\u{F708}", "\u{F716}", "\u{F746}", "\u{F700}", "\u{F8FF}"] {
            #expect(TextRouter.droppingFunctionKeys(key) == "", "\(key.unicodeScalars.first!.value)")
        }
        #expect(TextRouter.droppingFunctionKeys("a\u{F708}b") == "ab")
        #expect(TextRouter.droppingFunctionKeys("日\u{F746}本") == "日本")
        // Just outside the range is text.
        #expect(TextRouter.droppingFunctionKeys("\u{F6FF}\u{F900}") == "\u{F6FF}\u{F900}")
        #expect(TextRouter.droppingFunctionKeys("hello") == "hello")
    }

    @Test func longTextSplitsAt300BytesOnScalarBoundary() {
        // ASCII: 700 bytes in chunks of 300, 300 and 100, in order.
        let ascii = String(repeating: "abcdefghij", count: 70)
        let routes = TextRouter.route(ascii)
        let chunks = routes.compactMap { if case let .inject(s) = $0 { s } else { nil } }
        #expect(chunks.count == routes.count)
        #expect(chunks.map(\.utf8.count) == [300, 300, 100])
        #expect(chunks.joined() == ascii)

        // The cut itself never splits a scalar: 299 ASCII bytes then a 4-byte emoji moves the emoji on.
        let mixed = String(repeating: "a", count: 299) + "😀" + String(repeating: "é", count: 200)
        let cut = TextRouter.chunks(mixed, maxBytes: ScrcpyControl.injectTextMaxBytes)
        #expect(cut.allSatisfy { $0.utf8.count <= 300 })
        #expect(cut.first?.utf8.count == 299)
        #expect(cut.joined() == mixed)
        #expect(cut.map(\.unicodeScalars.count).reduce(0, +) == mixed.unicodeScalars.count)
        // Exactly 300 bytes is one chunk.
        #expect(TextRouter.chunks(String(repeating: "x", count: 300), maxBytes: 300).count == 1)
    }
}
