import Foundation
import Testing
@testable import FileProviderShared

private struct Dir {
    let root: URL
    let uploads: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-staged-\(UUID().uuidString)")
        uploads = root.appendingPathComponent("Uploads")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func stagedUploadCopiesOnlyARegularFileInItsOwnFolder() throws {
    let d = try Dir(); defer { d.clean() }
    let fm = FileManager.default
    let staged = d.uploads.appendingPathComponent("u1")
    try fm.createDirectory(at: staged, withIntermediateDirectories: true)
    let file = staged.appendingPathComponent("a b.txt")
    try Data("hello".utf8).write(to: file)
    let out = d.root.appendingPathComponent("out-a")
    try StagedUpload.copy(file, stagedIn: d.uploads, to: out)
    #expect(try Data(contentsOf: out) == Data("hello".utf8))

    // A link to a Mac file, in place of the staged file.
    let secret = d.root.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    let link = staged.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: secret)
    #expect(throws: (any Error).self) { try StagedUpload.copy(link, stagedIn: d.uploads, to: d.root.appendingPathComponent("o1")) }
    // A linked staging folder.
    let elsewhere = d.root.appendingPathComponent("elsewhere")
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: elsewhere.appendingPathComponent("x.txt"))
    try fm.createSymbolicLink(at: d.uploads.appendingPathComponent("u2"), withDestinationURL: elsewhere)
    #expect(throws: (any Error).self) {
        try StagedUpload.copy(d.uploads.appendingPathComponent("u2/x.txt"), stagedIn: d.uploads, to: d.root.appendingPathComponent("o2"))
    }
    // Outside Uploads, climbing out, too deep or too shallow, or a folder.
    let bad = [
        secret,
        d.uploads.appendingPathComponent("u1/../../secret.txt"),
        d.uploads.appendingPathComponent("u1/a b.txt/x"),
        d.uploads.appendingPathComponent("top.txt"),
        staged,
    ]
    try Data("t".utf8).write(to: d.uploads.appendingPathComponent("top.txt"))
    for (i, url) in bad.enumerated() {
        #expect(throws: (any Error).self, "\(i)") {
            try StagedUpload.copy(url, stagedIn: d.uploads, to: d.root.appendingPathComponent("bad\(i)"))
        }
    }
    #expect(!fm.fileExists(atPath: d.root.appendingPathComponent("o1").path))

    // A FIFO is refused at once, not waited on.
    let fifo = staged.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try StagedUpload.copy(fifo, stagedIn: d.uploads, to: d.root.appendingPathComponent("o3")) }
}

// MARK: final wave: the walk rooted at the outbox (R24)

@Test func outboxWalkRefusesALinkAnywhereInTheShare() throws {
    let d = try Dir(); defer { d.clean() }
    let fm = FileManager.default
    let outbox = d.root.appendingPathComponent("Outbox")
    let share = UUID().uuidString
    try fm.createDirectory(at: outbox.appendingPathComponent("\(share)/0"), withIntermediateDirectories: true)
    let secret = d.root.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    // The file is a link.
    try fm.createSymbolicLink(at: outbox.appendingPathComponent("\(share)/0/a.txt"), withDestinationURL: secret)
    #expect(throws: (any Error).self) { try StagedUpload.copy([share, "0", "a.txt"], under: outbox, to: d.root.appendingPathComponent("o1")) }
    // The index folder is a link.
    let elsewhere = d.root.appendingPathComponent("elsewhere")
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: elsewhere.appendingPathComponent("x.txt"))
    try fm.createSymbolicLink(at: outbox.appendingPathComponent("\(share)/1"), withDestinationURL: elsewhere)
    #expect(throws: (any Error).self) { try StagedUpload.copy([share, "1", "x.txt"], under: outbox, to: d.root.appendingPathComponent("o2")) }
    // The share folder is a link.
    let other = UUID().uuidString
    try fm.createSymbolicLink(at: outbox.appendingPathComponent(other), withDestinationURL: outbox.appendingPathComponent(share))
    #expect(throws: (any Error).self) { try StagedUpload.copy([other, "1", "x.txt"], under: outbox, to: d.root.appendingPathComponent("o3")) }
    #expect(!StagedUpload.isRegularFile([share, "0", "a.txt"], under: outbox))
    // Steps that climb or are empty never reach the disk.
    for bad in [[share, "..", "secret.txt"], [share, "", "a.txt"], ["..", "secret.txt"], []] {
        #expect(throws: (any Error).self) { try StagedUpload.copy(bad, under: outbox, to: d.root.appendingPathComponent("o4")) }
    }
    for i in 1...4 { #expect(!fm.fileExists(atPath: d.root.appendingPathComponent("o\(i)").path)) }
    // A plain file in its place is taken.
    try Data("ok".utf8).write(to: outbox.appendingPathComponent("\(share)/0/b.txt"))
    try StagedUpload.copy([share, "0", "b.txt"], under: outbox, to: d.root.appendingPathComponent("o5"))
    #expect(try Data(contentsOf: d.root.appendingPathComponent("o5")) == Data("ok".utf8))
}

@Test func outboxWalkRefusesAFifoAtOnce() throws {
    let d = try Dir(); defer { d.clean() }
    let outbox = d.root.appendingPathComponent("Outbox")
    let share = UUID().uuidString
    try FileManager.default.createDirectory(at: outbox.appendingPathComponent("\(share)/0"), withIntermediateDirectories: true)
    #expect(mkfifo(outbox.appendingPathComponent("\(share)/0/pipe").path, 0o600) == 0)
    // Opened non-blocking: refused, not waited on for a writer.
    #expect(throws: (any Error).self) { try StagedUpload.copy([share, "0", "pipe"], under: outbox, to: d.root.appendingPathComponent("o")) }
    #expect(!StagedUpload.isRegularFile([share, "0", "pipe"], under: outbox))
}

@Test func outboxWalkRefusesALinkedOutboxRoot() throws {
    let d = try Dir(); defer { d.clean() }
    let fm = FileManager.default
    let elsewhere = d.root.appendingPathComponent("Downloads")
    let share = UUID().uuidString
    try fm.createDirectory(at: elsewhere.appendingPathComponent("\(share)/0"), withIntermediateDirectories: true)
    try Data("private".utf8).write(to: elsewhere.appendingPathComponent("\(share)/0/a.txt"))
    let outbox = d.root.appendingPathComponent("Outbox")
    try fm.createSymbolicLink(at: outbox, withDestinationURL: elsewhere)
    #expect(throws: (any Error).self) { try StagedUpload.copy([share, "0", "a.txt"], under: outbox, to: d.root.appendingPathComponent("o")) }
    #expect(!StagedUpload.isRegularFile([share, "0", "a.txt"], under: outbox))
    #expect(!fm.fileExists(atPath: d.root.appendingPathComponent("o").path))
}
