import Foundation
import Testing
@testable import FileProviderShared

@Test func xpcInterfacesAllowOnlyTheirArgumentClasses() {
    // Building them checks every selector and argument index (a wrong one raises).
    let files = FullBuild.phoneFilesInterface()
    let list = #selector(PhoneFilesXPC.list(rootID:path:offset:reply:))
    #expect(files.classes(for: list, argumentIndex: 0, ofReply: false) == [NSString.self as AnyObject as! AnyHashable])
    #expect(files.classes(for: list, argumentIndex: 0, ofReply: true) == [NSData.self as AnyObject as! AnyHashable])
    let upload = #selector(PhoneFilesXPC.upload(rootID:dirPath:from:reply:))
    #expect(files.classes(for: upload, argumentIndex: 2, ofReply: false) == [NSURL.self as AnyObject as! AnyHashable])
    let control = FullBuild.controlInterface()
    let register = #selector(FileProviderControlXPC.register(appEndpoint:reply:))
    #expect(control.classes(for: register, argumentIndex: 0, ofReply: false)
        == [NSXPCListenerEndpoint.self as AnyObject as! AnyHashable])
}

@Test func dtosAndErrorsRoundTrip() throws {
    let listing = ListingDTO(entries: [EntryDTO(name: "a b.txt", isDir: false, size: 5_000_000_000,
                                                modifiedMs: 1_700_000_000_000, mime: "text/plain")],
                             nextOffset: 1, more: false)
    #expect(try JSONDecoder().decode(ListingDTO.self, from: JSONEncoder().encode(listing)) == listing)
    let roots = [RootDTO(id: "primary", name: "Phone", writable: true)]
    #expect(try JSONDecoder().decode([RootDTO].self, from: JSONEncoder().encode(roots)) == roots)

    #expect(PhoneFilesError(PhoneFilesError.notFound.error) == .notFound)
    #expect(PhoneFilesError(CocoaError(.fileNoSuchFile)) == nil)
    #expect(PhoneFilesError(nil) == nil)
    #expect(PhoneFilesError.denied.error.userInfo.isEmpty)
}

@Test func appGroupIDNeedsATeam() {
    #expect(FullBuild.appGroupID(fromInfoValue: "ABCDE12345.io.github.anmirror") == "ABCDE12345.io.github.anmirror")
    // Unsigned builds expand `$(DEVELOPMENT_TEAM).io.github.anmirror` to a leading dot.
    #expect(FullBuild.appGroupID(fromInfoValue: ".io.github.anmirror") == nil)
    #expect(FullBuild.appGroupID(fromInfoValue: "") == nil)
    #expect(FullBuild.appGroupID(fromInfoValue: nil) == nil)
    #expect(FullBuild.appGroupID(in: .main) == nil, "the test runner has no group")
}
