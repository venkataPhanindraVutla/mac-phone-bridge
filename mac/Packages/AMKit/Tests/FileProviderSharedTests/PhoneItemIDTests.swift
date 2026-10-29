import Testing
@testable import FileProviderShared

@Test func itemIDRoundTripsRootAndPath() {
    let cases: [(String, String)] = [
        ("primary", "DCIM/Camera/IMG_0001.jpg"),
        ("tree:primary%3ADocuments", "a/b c/100% sure.txt"),
        ("r1", "Fotos 📷/Ferien 🏖/x.png"),
        ("r/1", "%2F/%%/a%20b"),
        ("r1", "trailing space /é"),
    ]
    for (root, path) in cases {
        let id = PhoneItemID.encode(rootID: root, path: path)
        #expect(id.hasPrefix("r/"))
        // Exactly two separators: the root and the path are encoded, `/` included.
        #expect(id.split(separator: "/", omittingEmptySubsequences: false).count == 3, "\(id)")
        let decoded = PhoneItemID.decode(id)
        #expect(decoded?.rootID == root)
        #expect(decoded?.path == path)
    }
    // Different paths never share an ID.
    #expect(PhoneItemID.encode(rootID: "r", path: "a/b") != PhoneItemID.encode(rootID: "r", path: "a%2Fb"))
    #expect(PhoneItemID.encode(rootID: "r/a", path: "b") != PhoneItemID.encode(rootID: "r", path: "a/b"))
}

@Test func rootPathIsEmpty() {
    let id = PhoneItemID.encode(rootID: "primary", path: "")
    #expect(id == "r/primary/")
    let decoded = PhoneItemID.decode(id)
    #expect(decoded?.rootID == "primary")
    #expect(decoded?.path == "")
}

@Test func foreignIDDecodesToNil() {
    let foreign = [
        "",
        "NSFileProviderRootContainerItemIdentifier",
        "NSFileProviderWorkingSetContainerItemIdentifier",
        "NSFileProviderTrashContainerItemIdentifier",
        "r",
        "r/",
        "r//a",               // no root ID
        "r/primary",          // no path separator
        "x/primary/a",        // another scheme
        "R/primary/a",
        "r/primary/a/b",      // a raw `/` in the path is not this encoding
        "r/primary/%ZZ",      // not percent-encoding
        "r/primary/a%2",
        "r/primary/a b",      // a raw space is not this encoding
        "r/primary/%61",      // `a` encoded: not the canonical form
        "/r/primary/a",
    ]
    for id in foreign { #expect(PhoneItemID.decode(id) == nil, "\(id)") }
}
