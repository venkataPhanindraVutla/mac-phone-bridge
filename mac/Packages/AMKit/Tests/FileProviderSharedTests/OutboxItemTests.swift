import Foundation
import Testing
@testable import FileProviderShared

private let phone = "aa11"
private let now: Int64 = 1_800_000_000_000

private func envelope(_ items: [OutboxItem], phoneID: String = phone, createdMs: Int64 = now) -> OutboxEnvelope {
    OutboxEnvelope(phoneID: phoneID, createdMs: createdMs, items: items)
}

private let everything: Set<String> = ["files.v1", "share.v1"]
private let shareID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
/// A file as the Share extension names it: share-relative.
private func shared(_ n: Int, _ name: String) -> String { "\(shareID)/\(n)/\(name)" }
private let none: @Sendable (String) -> Bool = { _ in false }

@Test func outboxRoundTrips() throws {
    let original = envelope([
        .file(shared(0, "a b.pdf")),
        .link("https://example.com/x?y=1"),
        .text("hello 👋\nworld"),
    ])
    let data = try original.encoded()
    let decoded = try OutboxEnvelope.decode(data)
    #expect(decoded == original)
    #expect(decoded.items.map(\.kind) == [.file, .link, .text])
    #expect(decoded.items[0].path == shared(0, "a b.pdf"))
    #expect(decoded.items[1].url == "https://example.com/x?y=1")
    #expect(decoded.items[2].text == "hello 👋\nworld")
    // The envelope's fields as the extension writes them.
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["phoneID", "createdMs", "items"])

    // Not an envelope, or too large to be one: nothing decodes.
    #expect(throws: (any Error).self) { try OutboxEnvelope.decode(Data("[]".utf8)) }
    #expect(throws: (any Error).self) { try OutboxEnvelope.decode(Data(count: OutboxEnvelope.maxBytes + 1)) }
}

@Test func outboxWaitsForItsOwnPhone() {
    let e = envelope([.text("hi")])
    let paired: Set<String> = [phone, "bb22"]
    // Not connected, or another phone connected: it waits.
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: paired, nowMs: now, isSendable: none) == .keep)
    #expect(e.decision(connectedPhoneID: "bb22", shared: everything, pairedPhoneIDs: paired, nowMs: now, isSendable: none) == .keep)
    // Its phone: delivered.
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: paired, nowMs: now, isSendable: none)
        == .deliver(OutboxDelivery(files: [], shares: [.text("hi")], skipped: 0, kept: [])))
}

@Test func outboxDropsForgottenPhoneAndOldItems() {
    let e = envelope([.text("hi")])
    // Its phone was forgotten: dropped, whoever is connected.
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: ["bb22"], nowMs: now, isSendable: none) == .drop)
    #expect(e.decision(connectedPhoneID: "bb22", shared: everything, pairedPhoneIDs: ["bb22"], nowMs: now, isSendable: none) == .drop)
    // Older than 24 h: dropped, even for its phone.
    let day = OutboxEnvelope.maxAgeMs
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now + day + 1, isSendable: none) == .drop)
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: [phone], nowMs: now + day + 1, isSendable: none) == .drop)
    // Just inside 24 h: still delivered.
    if case .deliver = e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now + day, isSendable: none) {} else {
        Issue.record("an item 24 h old is still sent")
    }
}

@Test func outboxFollowsTheSharedCapabilities() {
    let e = envelope([.file(shared(0, "f")), .link("https://example.com"), .text("t")])
    let sendable: (String) -> Bool = { _ in true }
    // Files need files.v1; links and text need share.v1. What is blocked waits (R21).
    #expect(e.decision(connectedPhoneID: phone, shared: ["files.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [shared(0, "f")], shares: [], skipped: 0, kept: [.link("https://example.com"), .text("t")])))
    #expect(e.decision(connectedPhoneID: phone, shared: ["share.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [], shares: [.link("https://example.com"), .text("t")], skipped: 0, kept: [.file(shared(0, "f"))])))
    // A phone with neither gets nothing now.
    #expect(e.decision(connectedPhoneID: phone, shared: ["browse.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .keep)
    // Items missing their field are skipped.
    let broken = envelope([OutboxItem(kind: .file), OutboxItem(kind: .link), OutboxItem(kind: .text, text: "")])
    #expect(broken.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [], shares: [], skipped: 3, kept: [])))
}

@Test func outboxSendsOnlyRegularFilesInTheShare() throws {
    let fm = FileManager.default
    let outbox = fm.temporaryDirectory.appendingPathComponent("am-outbox-\(UUID().uuidString)")
    let share = outbox.appendingPathComponent(shareID)
    try fm.createDirectory(at: share, withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: share.appendingPathComponent("4/locked.txt").path)
        try? fm.removeItem(at: outbox)
    }
    func put(_ n: Int, _ name: String) throws -> URL {
        let folder = share.appendingPathComponent("\(n)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
    let file = try put(0, "a.txt")
    try Data("a".utf8).write(to: file)
    // A link the planter put in the share, to a file it could not copy itself.
    let secret = outbox.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    try fm.createSymbolicLink(at: try put(1, "link.txt"), withDestinationURL: secret)
    try fm.createDirectory(at: try put(2, "folder"), withIntermediateDirectories: true)
    try fm.createDirectory(at: try put(3, "Thing.app").appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let locked = try put(4, "locked.txt")
    try Data("b".utf8).write(to: locked)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

    #expect(OutboxFiles.isSendable(shared(0, "a.txt"), in: outbox))
    #expect(!OutboxFiles.isSendable(shared(1, "link.txt"), in: outbox), "a link is never followed")
    #expect(!OutboxFiles.isSendable(shared(2, "folder"), in: outbox))
    #expect(!OutboxFiles.isSendable(shared(3, "Thing.app"), in: outbox))
    #expect(!OutboxFiles.isSendable(shared(4, "locked.txt"), in: outbox))
    #expect(!OutboxFiles.isSendable(shared(5, "gone.txt"), in: outbox))
    #expect(!OutboxFiles.isSendable(file.path, in: outbox), "an absolute path is no share path")

    let paths = [shared(0, "a.txt"), shared(1, "link.txt"), shared(2, "folder"), shared(3, "Thing.app"),
                 shared(4, "locked.txt"), shared(5, "gone.txt")]
    let e = envelope(paths.map { .file($0) })
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now,
                       isSendable: { OutboxFiles.isSendable($0, in: outbox) })
        == .deliver(OutboxDelivery(files: [shared(0, "a.txt")], shares: [], skipped: 5, kept: [])))
}

// MARK: fix round 1 (R21, future shares, sheet checks)

@Test func blockedItemsWaitInARewrittenEnvelope() {
    let e = envelope([.file(shared(0, "f")), .link("https://example.com"), .text("t")])
    let sendable: (String) -> Bool = { _ in true }
    // Files go now; links and text wait for share.v1 (kept, same phone and time).
    #expect(e.decision(connectedPhoneID: phone, shared: ["files.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [shared(0, "f")], shares: [], skipped: 0,
                                   kept: [.link("https://example.com"), .text("t")])))
    // Nothing can go and nothing is dropped: left as it is.
    #expect(e.decision(connectedPhoneID: phone, shared: ["browse.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .keep)
    // While files are blocked, a file is kept unchecked: it may be back by then.
    let gone = envelope([.file(shared(1, "gone")), .text("t")])
    #expect(gone.decision(connectedPhoneID: phone, shared: ["share.v1"], pairedPhoneIDs: [phone], nowMs: now,
                          isSendable: { _ in false })
        == .deliver(OutboxDelivery(files: [], shares: [.text("t")], skipped: 0, kept: [.file(shared(1, "gone"))])))
    // With files.v1, a vanished file is dropped.
    #expect(gone.decision(connectedPhoneID: phone, shared: ["files.v1"], pairedPhoneIDs: [phone], nowMs: now,
                          isSendable: { _ in false })
        == .deliver(OutboxDelivery(files: [], shares: [], skipped: 1, kept: [.text("t")])))
    // The kept items' envelope is the same share.
    let kept = e.keeping([.text("t")])
    #expect(kept.phoneID == e.phoneID)
    #expect(kept.createdMs == e.createdMs)
    #expect(kept.items == [.text("t")])
}

@Test func futureSharesAreDropped() {
    let e = envelope([.text("hi")], createdMs: now + OutboxEnvelope.maxFutureMs + 1)
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now, isSendable: none) == .drop)
    let soon = envelope([.text("hi")], createdMs: now + OutboxEnvelope.maxFutureMs)
    #expect(soon.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now, isSendable: none)
        == .deliver(OutboxDelivery(files: [], shares: [.text("hi")], skipped: 0, kept: [])))
}

@Test func theSheetRefusesTooLongTextAndNothing() {
    #expect(OutboxEnvelope.check([.text("hi"), .file(shared(0, "a"))]) == .ok)
    #expect(OutboxEnvelope.check([]) == .nothingToSend)
    #expect(OutboxEnvelope.check([.text("")]) == .nothingToSend)
    let max = String(repeating: "a", count: OutboxEnvelope.maxTextBytes)
    #expect(OutboxEnvelope.check([.text(max)]) == .ok)
    // Bytes, not characters: é is two.
    let over = String(repeating: "é", count: OutboxEnvelope.maxTextBytes / 2 + 1)
    #expect(OutboxEnvelope.check([.file(shared(0, "a")), .text(over)]) == .textTooLong)
}

@Test func pendingRewritesNameTheirOriginal() {
    let pending = OutboxFiles.pendingName(for: "ABC.json")
    #expect((pending as NSString).pathExtension == "pending")
    #expect(!pending.hasSuffix(".json"), "the drain never reads it")
    #expect(OutboxFiles.original(ofPending: pending) == "ABC.json")
    #expect(OutboxFiles.original(ofPending: "ABC.json") == nil)
    #expect(OutboxFiles.original(ofPending: "x.pending") == nil, "not a rewrite of an outbox file")
}

// MARK: final wave: R24, share-relative paths only

private func decodes(_ path: String) -> Bool {
    let e = OutboxEnvelope(phoneID: phone, createdMs: now, items: [.text("t"), .file(path)])
    guard let data = try? e.encoded() else { return false }
    return (try? OutboxEnvelope.decode(data)) != nil
}

@Test func envelopeRejectsAbsoluteAndDotDotPaths() {
    #expect(!decodes("/Users/me/Desktop/secret.pdf"))
    #expect(!decodes("/\(shareID)/0/a.txt"))
    #expect(!decodes("\(shareID)/0/../../../../Desktop/secret.pdf"))
    #expect(!decodes("\(shareID)/../0/a.txt"))
    #expect(!decodes("../\(shareID)/0/a.txt"))
    #expect(!decodes("\(shareID)/0/.."))
    #expect(!decodes("\(shareID)/0/."))
    #expect(!decodes("\(shareID)//a.txt"))
    #expect(!decodes("\(shareID)/0/"))
    #expect(!decodes(""))
}

@Test func envelopeAcceptsOnlyShareRelativePaths() {
    #expect(decodes(shared(0, "a b.pdf")))
    #expect(decodes(shared(49, "IMG_0001.HEIC")))
    #expect(decodes("\(shareID.lowercased())/3/x"))
    // Not of the shape `<share UUID>/<n>/<name>`.
    #expect(!decodes("a.txt"))
    #expect(!decodes("\(shareID)/a.txt"))
    #expect(!decodes("\(shareID)/0/sub/a.txt"))
    #expect(!decodes("not-a-uuid-at-all-but-36-characters!/0/a.txt"))
    #expect(!decodes("\(shareID)/x/a.txt"))
    #expect(!decodes("\(shareID)/-1/a.txt"))
    #expect(!decodes("\(shareID)/12345/a.txt"))
    #expect(!decodes("\(shareID)/0/" + String(repeating: "a", count: 256)))
    // A file item with no path decodes (it is skipped when sent); links and text are not paths.
    let e = OutboxEnvelope(phoneID: phone, createdMs: now, items: [OutboxItem(kind: .file), .link("/etc/passwd")])
    #expect((try? OutboxEnvelope.decode(try e.encoded())) != nil)
    #expect(envelope([.file(shared(0, "a")), .file(shared(1, "b")), .text("t")]).shareFolders == [shareID])
}

@Test func extensionStagesACopyTheAppCanTake() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("am-stage-\(UUID().uuidString)")
    let outbox = root.appendingPathComponent("Outbox")
    try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("report final.pdf")
    try Data("pdf".utf8).write(to: source)
    let share = UUID()
    let path = try OutboxFiles.stage(source, in: outbox, share: share, index: 2)
    #expect(path == "\(share.uuidString)/2/report final.pdf")
    #expect(decodes(path))
    #expect(OutboxFiles.isSendable(path, in: outbox))
    // The app's copy is the bytes the extension staged.
    let copy = root.appendingPathComponent("copy")
    try StagedUpload.copy(try #require(OutboxFiles.steps(ofShared: path)), under: outbox, to: copy)
    #expect(try Data(contentsOf: copy) == Data("pdf".utf8))
    // A folder or a package is not staged.
    let folder = root.appendingPathComponent("Album", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try OutboxFiles.stage(folder, in: outbox, share: share, index: 3) }
}

@Test func orphanShareFoldersAreFoundAfterTheGrace() throws {
    let fm = FileManager.default
    let outbox = fm.temporaryDirectory.appendingPathComponent("am-orphans-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: outbox) }
    let named = UUID().uuidString, orphan = UUID().uuidString
    for name in [named, orphan, "not-a-share"] {
        try fm.createDirectory(at: outbox.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: outbox.appendingPathComponent("\(UUID().uuidString).json"))
    let later = Int64(Date().timeIntervalSince1970 * 1000) + OutboxFiles.orphanGraceMs + 1000
    let found = OutboxFiles.orphanFolders(in: outbox, referenced: [named], nowMs: later)
    #expect(found.map(\.lastPathComponent) == [orphan])
    // Just made: the extension may still be writing its envelope.
    #expect(OutboxFiles.orphanFolders(in: outbox, referenced: [named], nowMs: later - OutboxFiles.orphanGraceMs - 2000).isEmpty)
}
