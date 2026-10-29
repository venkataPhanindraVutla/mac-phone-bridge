import Foundation

/// Phone files for the File Provider extension, vended by the main app over an anonymous
/// listener whose endpoint only the extension gets (through `FileProviderControlXPC`). Each
/// listener serves one phone: the File Provider domain it was registered for.
/// Errors are `PhoneFilesError`s.
@objc public protocol PhoneFilesXPC {
    /// JSON `[RootDTO]`.
    func roots(reply: @escaping @Sendable (Data?, Error?) -> Void)
    /// JSON `ListingDTO`: one page of the folder `path` of `rootID`, from `offset`.
    func list(rootID: String, path: String, offset: Int, reply: @escaping @Sendable (Data?, Error?) -> Void)
    /// The file, in the App Group container's `Downloads/`. The caller moves it away.
    func download(rootID: String, path: String, reply: @escaping @Sendable (URL?, Error?) -> Void)
    /// Sends the file at `url` (named as it should be named on the phone) into the folder
    /// `dirPath` of `rootID`, never over an existing file. JSON `EntryDTO`.
    func upload(rootID: String, dirPath: String, from url: URL, reply: @escaping @Sendable (Data?, Error?) -> Void)
}

/// Vended by the File Provider extension (`NSFileProviderServiceSource`): the app hands over
/// its `PhoneFilesXPC` endpoint.
@objc public protocol FileProviderControlXPC {
    func register(appEndpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable () -> Void)
}

public struct RootDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var writable: Bool

    public init(id: String, name: String, writable: Bool) {
        self.id = id
        self.name = name
        self.writable = writable
    }
}

public struct EntryDTO: Codable, Equatable, Sendable {
    public var name: String
    public var isDir: Bool
    public var size: UInt64
    public var modifiedMs: Int64
    public var mime: String

    public init(name: String, isDir: Bool, size: UInt64, modifiedMs: Int64, mime: String) {
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modifiedMs = modifiedMs
        self.mime = mime
    }
}

public struct ListingDTO: Codable, Equatable, Sendable {
    public var entries: [EntryDTO]
    public var nextOffset: Int
    public var more: Bool

    public init(entries: [EntryDTO], nextOffset: Int, more: Bool) {
        self.entries = entries
        self.nextOffset = nextOffset
        self.more = more
    }
}

/// Why a `PhoneFilesXPC` call failed, as an `NSError` in `domain` with no user info.
public enum PhoneFilesError: Int, Error, Sendable {
    /// No phone, another phone, or the phone does not browse now.
    case unreachable = 1
    case notFound = 2
    /// Read-only root, revoked access, or the phone said no.
    case denied = 3
    case noSpace = 4
    case failed = 5

    public static let domain = "io.github.anmirror.phonefiles"

    public var error: NSError { NSError(domain: Self.domain, code: rawValue) }

    public init?(_ error: (any Error)?) {
        guard let error = error as NSError?, error.domain == Self.domain else { return nil }
        self.init(rawValue: error.code)
    }
}

public enum FullBuild {
    /// The extension's `NSFileProviderServiceSource` name.
    public static let serviceName = "io.github.anmirror.mac.fileprovider.control"
    /// Posted by the Share extension after it wrote to `Outbox/`.
    public static let darwinOutboxNote = "io.github.anmirror.mac.outbox"
    /// Posted by the File Provider extension when it needs the app's endpoint and has none
    /// (it was relaunched): the app registers again for the connected phone.
    public static let darwinEndpointNote = "io.github.anmirror.mac.fileprovider.endpoint"

    /// Folders in the App Group container.
    public static let outboxFolder = "Outbox"
    public static let downloadsFolder = "Downloads"
    public static let uploadsFolder = "Uploads"

    /// App Group `UserDefaults` keys, written by the app on connect: the phone "Send to" names.
    public static let phoneIDKey = "sharePhoneID"
    public static let phoneNameKey = "sharePhoneName"

    /// The extensions' `Info.plist` key holding the App Group ID (`$(APP_GROUP_ID)`).
    public static let appGroupInfoKey = "AMAppGroupID"

    /// The App Group ID from `bundle`'s `Info.plist`; nil when it is not set (an unsigned build).
    public static func appGroupID(in bundle: Bundle) -> String? {
        appGroupID(fromInfoValue: bundle.object(forInfoDictionaryKey: appGroupInfoKey))
    }

    /// The value when it names a team's group; an unsigned build expands
    /// `$(DEVELOPMENT_TEAM).io.github.anmirror` to `.io.github.anmirror`.
    static func appGroupID(fromInfoValue value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, !id.hasPrefix(".") else { return nil }
        return id
    }

    /// The `PhoneFilesXPC` interface, with the classes each argument may decode as: strings,
    /// data and URLs only (errors are plain `NSError`s).
    public static func phoneFilesInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PhoneFilesXPC.self)
        let data = classes(NSData.self), string = classes(NSString.self), url = classes(NSURL.self)
        interface.setClasses(data, for: #selector(PhoneFilesXPC.roots(reply:)), argumentIndex: 0, ofReply: true)
        let list = #selector(PhoneFilesXPC.list(rootID:path:offset:reply:))
        interface.setClasses(string, for: list, argumentIndex: 0, ofReply: false)
        interface.setClasses(string, for: list, argumentIndex: 1, ofReply: false)
        interface.setClasses(data, for: list, argumentIndex: 0, ofReply: true)
        let download = #selector(PhoneFilesXPC.download(rootID:path:reply:))
        interface.setClasses(string, for: download, argumentIndex: 0, ofReply: false)
        interface.setClasses(string, for: download, argumentIndex: 1, ofReply: false)
        interface.setClasses(url, for: download, argumentIndex: 0, ofReply: true)
        let upload = #selector(PhoneFilesXPC.upload(rootID:dirPath:from:reply:))
        interface.setClasses(string, for: upload, argumentIndex: 0, ofReply: false)
        interface.setClasses(string, for: upload, argumentIndex: 1, ofReply: false)
        interface.setClasses(url, for: upload, argumentIndex: 2, ofReply: false)
        interface.setClasses(data, for: upload, argumentIndex: 0, ofReply: true)
        return interface
    }

    /// The `FileProviderControlXPC` interface: its one argument is an endpoint.
    public static func controlInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FileProviderControlXPC.self)
        interface.setClasses(classes(NSXPCListenerEndpoint.self),
                             for: #selector(FileProviderControlXPC.register(appEndpoint:reply:)),
                             argumentIndex: 0, ofReply: false)
        return interface
    }

    private static func classes(_ c: AnyClass) -> Set<AnyHashable> {
        // swiftlint:disable:next force_cast
        NSSet(object: c) as! Set<AnyHashable>
    }
}
