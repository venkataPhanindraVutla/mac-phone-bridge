import Foundation
import Testing
@testable import FeatureFiles

private let vectors = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // FeatureFilesTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // AMKit
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // mac
    .deletingLastPathComponent() // repo
    .appendingPathComponent("protocol/vectors/filenames.json")

private struct FilenamesFile: Decodable {
    struct Sanitize: Decodable { let `in`: String; let out: String }
    struct Unique: Decodable { let name: String; let taken: [String]; let out: String }
    let sanitize: [Sanitize]
    let unique: [Unique]
}

/// Swift `String ==` is canonical equivalence; the vectors need the exact scalars.
private func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

@Test func sanitizeMatchesVectors() throws {
    let file = try JSONDecoder().decode(FilenamesFile.self, from: Data(contentsOf: vectors))
    #expect(file.sanitize.count >= 20)
    for c in file.sanitize {
        let out = FileNameSanitizer.sanitize(c.in)
        #expect(scalars(out) == scalars(c.out), "sanitize \(c.in.debugDescription) gave \(out.debugDescription)")
        #expect(out.utf8.count <= 255)
    }
    #expect(file.unique.count >= 10)
    for u in file.unique {
        let taken = Set(u.taken.map(FileNameSanitizer.key))
        let out = FileNameSanitizer.unique(u.name) { taken.contains(FileNameSanitizer.key($0)) }
        #expect(scalars(out) == scalars(u.out), "unique \(u.name.debugDescription) gave \(out.debugDescription)")
    }
}

@Test func uniqueStopsAtTheFirstFreeCounter() {
    var asked: [String] = []
    let out = FileNameSanitizer.unique("a.txt") { name in
        asked.append(name)
        return name != "a (3).txt"
    }
    #expect(out == "a (3).txt")
    #expect(asked == ["a.txt", "a (1).txt", "a (2).txt", "a (3).txt"])
}
