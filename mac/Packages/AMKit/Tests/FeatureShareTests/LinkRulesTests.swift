import Foundation
import Testing
@testable import FeatureShare

@Test func linkOpensOnlyHttpAndHttps() {
    #expect(LinkRules.link("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
    #expect(LinkRules.link("http://example.com")?.absoluteString == "http://example.com")
    #expect(LinkRules.link("HTTPS://Example.com/x")?.host() == "Example.com")
    // Trimmed.
    #expect(LinkRules.link("  https://example.com/\n")?.absoluteString == "https://example.com/")
    for other in ["ftp://example.com/f", "file:///etc/passwd", "mailto:a@example.com", "javascript:alert(1)",
                  "tel:+15550100", "example.com", "", "   "] {
        #expect(LinkRules.link(other) == nil, "\(other)")
    }
}

@Test func linkRulesRejectOverlongAndHostless() {
    // A host is required.
    #expect(LinkRules.link("https://") == nil)
    #expect(LinkRules.link("https:///path") == nil)
    #expect(LinkRules.link("http:example.com") == nil)
    // A link is one URL: text around it, or inside it, makes it text.
    #expect(LinkRules.link("see https://example.com") == nil)
    #expect(LinkRules.link("https://example.com and more") == nil)
    #expect(LinkRules.link("https://exa mple.com") == nil)
    // At most 8,192 bytes of UTF-8, counted after trimming.
    let base = "https://example.com/"
    let fits = base + String(repeating: "a", count: LinkRules.maxBytes - base.utf8.count)
    #expect(fits.utf8.count == 8_192)
    #expect(LinkRules.link(fits) != nil)
    #expect(LinkRules.link("  " + fits + "  ") != nil)
    #expect(LinkRules.link(fits + "a") == nil)
}
