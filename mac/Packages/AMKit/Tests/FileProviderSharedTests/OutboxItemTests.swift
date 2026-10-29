import Foundation
import Testing
@testable import FileProviderShared

private let phone = "aa11"
private let now: Int64 = 1_800_000_000_000

private func envelope(_ items: [OutboxItem], phoneID: String = phone, createdMs: Int64 = now) -> OutboxEnvelope {
    OutboxEnvelope(phoneID: phoneID, createdMs: createdMs, items: items)
}

private let everything: Set<String> = ["files.v1", "share.v1"]

@Test func outboxRoundTrips() throws {
    let original = envelope([
        .file("/Users/me/Desktop/a b.pdf"),
        .link("https://example.com/x?y=1"),
        .text("hello 👋\nworld"),
    ])
    let data = try original.encoded()
    let decoded = try OutboxEnvelope.decode(data)
    #expect(decoded == original)
    #expect(decoded.items.map(\.kind) == [.file, .link, .text])
    #expect(decoded.items[0].path == "/Users/me/Desktop/a b.pdf")
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
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: paired, nowMs: now) == .keep)
    #expect(e.decision(connectedPhoneID: "bb22", shared: everything, pairedPhoneIDs: paired, nowMs: now) == .keep)
    // Its phone: delivered.
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: paired, nowMs: now)
        == .deliver(OutboxDelivery(files: [], shares: [.text("hi")], skipped: 0, kept: [])))
}

@Test func outboxDropsForgottenPhoneAndOldItems() {
    let e = envelope([.text("hi")])
    // Its phone was forgotten: dropped, whoever is connected.
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: ["bb22"], nowMs: now) == .drop)
    #expect(e.decision(connectedPhoneID: "bb22", shared: everything, pairedPhoneIDs: ["bb22"], nowMs: now) == .drop)
    // Older than 24 h: dropped, even for its phone.
    let day = OutboxEnvelope.maxAgeMs
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now + day + 1) == .drop)
    #expect(e.decision(connectedPhoneID: nil, shared: [], pairedPhoneIDs: [phone], nowMs: now + day + 1) == .drop)
    // Just inside 24 h: still delivered.
    if case .deliver = e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now + day) {} else {
        Issue.record("an item 24 h old is still sent")
    }
}

@Test func outboxFollowsTheSharedCapabilities() {
    let e = envelope([.file("/f"), .link("https://example.com"), .text("t")])
    let sendable: (String) -> Bool = { _ in true }
    // Files need files.v1; links and text need share.v1. What is blocked waits (R21).
    #expect(e.decision(connectedPhoneID: phone, shared: ["files.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: ["/f"], shares: [], skipped: 0, kept: [.link("https://example.com"), .text("t")])))
    #expect(e.decision(connectedPhoneID: phone, shared: ["share.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [], shares: [.link("https://example.com"), .text("t")], skipped: 0, kept: [.file("/f")])))
    // A phone with neither gets nothing now.
    #expect(e.decision(connectedPhoneID: phone, shared: ["browse.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .keep)
    // Items missing their field are skipped.
    let broken = envelope([OutboxItem(kind: .file), OutboxItem(kind: .link), OutboxItem(kind: .text, text: "")])
    #expect(broken.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: [], shares: [], skipped: 3, kept: [])))
}

@Test func outboxSendsOnlyRegularReadableFiles() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("am-outbox-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("locked.txt").path)
        try? fm.removeItem(at: dir)
    }
    let file = dir.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: file)
    let link = dir.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: file)
    let folder = dir.appendingPathComponent("folder", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let package = dir.appendingPathComponent("Thing.app", isDirectory: true)
    try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let locked = dir.appendingPathComponent("locked.txt")
    try Data("b".utf8).write(to: locked)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    let missing = dir.appendingPathComponent("gone.txt")

    #expect(OutboxFiles.isSendable(file.path))
    #expect(OutboxFiles.isSendable(link.path), "a link to a file is that file")
    #expect(!OutboxFiles.isSendable(folder.path))
    #expect(!OutboxFiles.isSendable(package.path))
    #expect(!OutboxFiles.isSendable(locked.path))
    #expect(!OutboxFiles.isSendable(missing.path))
    #expect(!OutboxFiles.isSendable("relative/a.txt"))

    let e = envelope([.file(file.path), .file(folder.path), .file(package.path), .file(locked.path), .file(missing.path)])
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now)
        == .deliver(OutboxDelivery(files: [file.path], shares: [], skipped: 4, kept: [])))
}

// MARK: fix round 1 (R21, future shares, sheet checks)

@Test func blockedItemsWaitInARewrittenEnvelope() {
    let e = envelope([.file("/f"), .link("https://example.com"), .text("t")])
    let sendable: (String) -> Bool = { _ in true }
    // Files go now; links and text wait for share.v1 (kept, same phone and time).
    #expect(e.decision(connectedPhoneID: phone, shared: ["files.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .deliver(OutboxDelivery(files: ["/f"], shares: [], skipped: 0,
                                   kept: [.link("https://example.com"), .text("t")])))
    // Nothing can go and nothing is dropped: left as it is.
    #expect(e.decision(connectedPhoneID: phone, shared: ["browse.v1"], pairedPhoneIDs: [phone], nowMs: now, isSendable: sendable)
        == .keep)
    // While files are blocked, a file is kept unchecked: it may be back by then.
    let gone = envelope([.file("/gone"), .text("t")])
    #expect(gone.decision(connectedPhoneID: phone, shared: ["share.v1"], pairedPhoneIDs: [phone], nowMs: now,
                          isSendable: { _ in false })
        == .deliver(OutboxDelivery(files: [], shares: [.text("t")], skipped: 0, kept: [.file("/gone")])))
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
    #expect(e.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now) == .drop)
    let soon = envelope([.text("hi")], createdMs: now + OutboxEnvelope.maxFutureMs)
    #expect(soon.decision(connectedPhoneID: phone, shared: everything, pairedPhoneIDs: [phone], nowMs: now)
        == .deliver(OutboxDelivery(files: [], shares: [.text("hi")], skipped: 0, kept: [])))
}

@Test func theSheetRefusesTooLongTextAndNothing() {
    #expect(OutboxEnvelope.check([.text("hi"), .file("/a")]) == .ok)
    #expect(OutboxEnvelope.check([]) == .nothingToSend)
    #expect(OutboxEnvelope.check([.text("")]) == .nothingToSend)
    let max = String(repeating: "a", count: OutboxEnvelope.maxTextBytes)
    #expect(OutboxEnvelope.check([.text(max)]) == .ok)
    // Bytes, not characters: é is two.
    let over = String(repeating: "é", count: OutboxEnvelope.maxTextBytes / 2 + 1)
    #expect(OutboxEnvelope.check([.file("/a"), .text(over)]) == .textTooLong)
}

@Test func pendingRewritesNameTheirOriginal() {
    let pending = OutboxFiles.pendingName(for: "ABC.json")
    #expect((pending as NSString).pathExtension == "pending")
    #expect(!pending.hasSuffix(".json"), "the drain never reads it")
    #expect(OutboxFiles.original(ofPending: pending) == "ABC.json")
    #expect(OutboxFiles.original(ofPending: "ABC.json") == nil)
    #expect(OutboxFiles.original(ofPending: "x.pending") == nil, "not a rewrite of an outbox file")
}
