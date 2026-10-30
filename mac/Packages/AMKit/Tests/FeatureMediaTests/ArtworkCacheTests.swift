import Foundation
import Testing
@testable import FeatureMedia

private func jpeg(_ n: Int) -> Data { Data("jpeg\(n)".utf8) }

@Test func keepsEightMostRecent() {
    var cache = ArtworkCache()
    for n in 0..<10 { cache.put("k\(n)", jpeg(n)) }
    #expect(cache.get("k0") == nil)
    #expect(cache.get("k1") == nil)
    for n in 2..<10 { #expect(cache.get("k\(n)") == jpeg(n)) }
    // Putting a kept key again makes it the newest: the next put drops k3, not k2.
    cache.put("k2", jpeg(2))
    cache.put("k10", jpeg(10))
    #expect(cache.get("k2") == jpeg(2))
    #expect(cache.get("k3") == nil)
    #expect(cache.get("k10") == jpeg(10))
    // A smaller limit.
    var small = ArtworkCache(limit: 2)
    small.put("a", jpeg(1))
    small.put("b", jpeg(2))
    small.put("c", jpeg(3))
    #expect(small.get("a") == nil)
    #expect(small.get("b") == jpeg(2))
    #expect(small.get("c") == jpeg(3))
}

@Test func clearEmpties() {
    var cache = ArtworkCache()
    cache.put("k1", jpeg(1))
    cache.put("k2", jpeg(2))
    cache.clear()
    #expect(cache.get("k1") == nil)
    #expect(cache.get("k2") == nil)
    // The empty key never holds anything.
    cache.put("", jpeg(3))
    #expect(cache.get("") == nil)
}
