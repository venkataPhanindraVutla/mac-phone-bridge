import FileProvider
import FileProviderShared
import Foundation
import os
import Security

/// Shows a paired phone in Finder's sidebar (F-04): one domain per phone, named after it. Every
/// listing, download and upload goes to the main app over XPC (`PhoneFilesXPC`), which serves
/// it from the phone while that phone is connected and browsing. Read-only browsing plus
/// downloads and new files: Finder's renames, moves and deletes are refused the File Provider
/// way (ruling R19), and its cancels reach the app (R20).
/// Only counts and outcome codes are logged, never names or paths.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing,
    @unchecked Sendable {
    let domain: NSFileProviderDomain
    let app: AppLink
    /// What enumeration has seen, so lookups and downloads need no listing.
    let cache = EntryCache()
    static let log = Logger(subsystem: "io.github.anmirror.mac.fileprovider", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        app = AppLink(domainID: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {
        app.invalidate()
    }

    // MARK: items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let done = Once<(NSFileProviderItem?, Error?)> { completionHandler($0.0, $0.1) }
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                done.call((try await self.resolve(identifier), nil))
            } catch {
                done.call((nil, Self.nsError(error, .read)))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
            done.call((nil, CocoaError(.userCancelled)))
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet:
            return RootsEnumerator(app: app, changes: true)
        case .rootContainer:
            return RootsEnumerator(app: app, changes: false)
        case .trashContainer:
            // There is no trash on the phone side.
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        default:
            guard let (rootID, path) = PhoneItemID.decode(containerItemIdentifier.rawValue) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FolderEnumerator(app: app, cache: cache, rootID: rootID, path: path)
        }
    }

    // MARK: contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let done = Once<(URL?, NSFileProviderItem?, Error?)> { completionHandler($0.0, $0.1, $0.2) }
        let progress = Progress(totalUnitCount: 1)
        let domain = domain
        let token = UUID().uuidString
        let task = Task {
            do {
                guard let (rootID, path) = PhoneItemID.decode(itemIdentifier.rawValue), !path.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let item = try await self.resolve(itemIdentifier)
                let downloaded = try await self.app.download(rootID: rootID, path: path, token: token)
                // Into the extension's own temporary folder (same volume as the domain), from
                // which the system clones and unlinks it; the App Group copy goes at once.
                let temp: URL
                do {
                    guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
                    temp = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                    try FileManager.default.moveItem(at: downloaded, to: temp)
                } catch {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw error
                }
                if !done.call((temp, item, nil)) { try? FileManager.default.removeItem(at: temp) }
                progress.completedUnitCount = 1
            } catch {
                Self.log.info("fetch failed: \(Self.code(error), privacy: .public)")
                done.call((nil, nil, Self.nsError(error, .read)))
            }
        }
        progress.cancellationHandler = { [app] in
            task.cancel()
            app.cancel(token: token)
            done.call((nil, nil, CocoaError(.userCancelled)))
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        let done = Once<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?)> {
            completionHandler($0.0, $0.1, $0.2, $0.3)
        }
        let progress = Progress(totalUnitCount: 1)
        let kind: FinderPolicy.CreateKind = switch itemTemplate.contentType {
        case .some(.folder): .folder
        case .some(.symbolicLink), .some(.aliasFile): .other
        default: .file
        }
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier
        let token = UUID().uuidString
        let task = Task {
            do {
                let item = try await self.create(kind: kind, named: name, in: parent, contents: url,
                                                 mayAlreadyExist: mayAlreadyExist, token: token)
                done.call((item, [], false, nil))
                progress.completedUnitCount = 1
            } catch {
                Self.log.info("create failed: \(Self.code(error), privacy: .public)")
                done.call((nil, [], false, Self.nsError(error, .create)))
            }
        }
        progress.cancellationHandler = { [app] in
            task.cancel()
            app.cancel(token: token)
            done.call((nil, [], false, CocoaError(.userCancelled)))
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        let done = Once<(NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?)> {
            completionHandler($0.0, $0.1, $0.2, $0.3)
        }
        let identifier = item.itemIdentifier
        let task = Task {
            let known = try? await self.resolve(identifier)
            switch FinderPolicy.answer(to: .modify, known: known) {
            case let .unchanged(server): done.call((server, [], false, nil))
            case .rejectDeletion: done.call((nil, [], false, Self.nsError(.cannotSynchronize)))
            case let .error(e): done.call((nil, [], false, Self.nsError(e)))
            }
        }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = {
            task.cancel()
            done.call((nil, [], false, CocoaError(.userCancelled)))
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let done = Once<Error?> { completionHandler($0) }
        let task = Task {
            let known = try? await self.resolve(identifier)
            switch FinderPolicy.answer(to: .delete, known: known) {
            case let .rejectDeletion(server): done.call(NSError.fileProviderErrorForRejectedDeletion(of: server))
            case .unchanged: done.call(Self.nsError(.cannotSynchronize))
            case let .error(e): done.call(Self.nsError(e))
            }
        }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = {
            task.cancel()
            done.call(CocoaError(.userCancelled))
        }
        return progress
    }

    // MARK: service

    /// The control service through which the app hands over its endpoint. Restricted: only a
    /// process that manages this domain (the app) can get it.
    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void)
        -> Progress {
        completionHandler([app], nil)
        return Progress(totalUnitCount: 1)
    }

    // MARK: private

    /// The item for `identifier`: the phone, a root, or an entry, from what enumeration saw or
    /// else its folder's listing. A folder too long to search is "cannot synchronize", never
    /// "no such item".
    private func resolve(_ identifier: NSFileProviderItemIdentifier) async throws -> PhoneItem {
        if identifier == .rootContainer { return PhoneItem.container(named: domain.displayName) }
        guard let (rootID, path) = PhoneItemID.decode(identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        let roots = try await app.roots()
        guard let root = roots.first(where: { $0.id == rootID }) else { throw NSFileProviderError(.noSuchItem) }
        if path.isEmpty { return PhoneItem.root(root) }
        if let cached = cache.entry(for: identifier.rawValue) {
            return PhoneItem.entry(cached.entry, rootID: rootID, folderPath: cached.folderPath, writable: root.writable)
        }
        let (folder, name) = split(path)
        switch try await search(name, rootID: rootID, folder: folder) {
        case let .found(entry):
            return PhoneItem.entry(entry, rootID: rootID, folderPath: folder, writable: root.writable)
        case .absent:
            throw NSFileProviderError(.noSuchItem)
        case .gaveUp:
            throw NSFileProviderError(.cannotSynchronize)
        }
    }

    /// Looks `name` up in the folder's listing; every page seen is cached.
    private func search(_ name: String, rootID: String, folder: String) async throws -> EntrySearch {
        try await EntrySearch.find(name) { offset in
            let page = try await self.app.list(rootID: rootID, path: folder, offset: offset)
            self.cache.store(page.entries, rootID: rootID, folderPath: folder)
            return page
        }
    }

    private func create(kind: FinderPolicy.CreateKind, named name: String, in parent: NSFileProviderItemIdentifier,
                        contents url: URL?, mayAlreadyExist: Bool, token: String) async throws -> PhoneItem? {
        let roots = try await app.roots()
        // At the top level, items are the phone's roots: never created, only matched.
        if parent == .rootContainer {
            guard mayAlreadyExist, kind == .folder, let root = roots.first(where: { $0.name == name }) else {
                if mayAlreadyExist { return nil }
                throw Refusal(.excludedFromSync)
            }
            return PhoneItem.root(root)
        }
        guard let (rootID, dirPath) = PhoneItemID.decode(parent.rawValue),
              let root = roots.first(where: { $0.id == rootID })
        else {
            if mayAlreadyExist { return nil }
            throw Refusal(.excludedFromSync)
        }
        let existing: EntryDTO?
        switch try await search(name, rootID: rootID, folder: dirPath) {
        case let .found(entry): existing = entry
        case .absent: existing = nil
        case .gaveUp: throw Refusal(.cannotSynchronize)
        }
        switch FinderPolicy.create(kind: kind, mayAlreadyExist: mayAlreadyExist, rootWritable: root.writable,
                                   existing: existing) {
        case let .existing(entry):
            return PhoneItem.entry(entry, rootID: rootID, folderPath: dirPath, writable: root.writable)
        case .notMatched:
            return nil
        case let .collision(entry):
            let item = PhoneItem.entry(entry, rootID: rootID, folderPath: dirPath, writable: root.writable)
            throw NSError.fileProviderErrorForCollision(with: item)
        case let .refuse(error):
            throw Refusal(error)
        case .upload:
            guard let url else { throw Refusal(.excludedFromSync) }
            let entry = try await upload(url, named: name, rootID: rootID, dirPath: dirPath, token: token)
            cache.store([entry], rootID: rootID, folderPath: dirPath)
            return PhoneItem.entry(entry, rootID: rootID, folderPath: dirPath, writable: root.writable)
        }
    }

    /// The app sends the file under its own name, so it goes as `Uploads/<uuid>/<name>`; the
    /// folder is removed once the app is done with it.
    private func upload(_ url: URL, named name: String, rootID: String, dirPath: String, token: String) async throws
        -> EntryDTO {
        let folder = try app.groupFolder(FullBuild.uploadsFolder).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: url, to: file)
        return try await app.upload(rootID: rootID, dirPath: dirPath, from: file, token: token)
    }

    /// A decision to refuse, as an error until it reaches the completion handler.
    struct Refusal: Error {
        let error: FinderError
        init(_ error: FinderError) { self.error = error }
    }

    /// Any error as one the File Provider contract allows (ruling R19).
    static func nsError(_ error: any Error, _ operation: FinderPolicy.Operation) -> NSError {
        switch error {
        case let refusal as Refusal: return nsError(refusal.error)
        case let call as AppCallError: return nsError(FinderPolicy.error(for: call.error, during: operation))
        case is CancellationError: return nsError(.userCancelled)
        default:
            let e = error as NSError
            if e.domain == NSFileProviderErrorDomain || e.domain == NSCocoaErrorDomain { return e }
            return nsError(.cannotSynchronize)
        }
    }

    static func nsError(_ error: FinderError) -> NSError {
        switch error {
        case .noSuchItem: NSFileProviderError(.noSuchItem) as NSError
        case .serverUnreachable: NSFileProviderError(.serverUnreachable) as NSError
        case .cannotSynchronize: NSFileProviderError(.cannotSynchronize) as NSError
        case .excludedFromSync: NSFileProviderError(.excludedFromSync) as NSError
        case .insufficientQuota: NSFileProviderError(.insufficientQuota) as NSError
        case .noPermission: CocoaError(.fileReadNoPermission) as NSError
        case .userCancelled: CocoaError(.userCancelled) as NSError
        }
    }

    static func code(_ error: any Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }
}

/// An app call that failed: the app's `PhoneFilesError`, or nil when the app did not answer.
struct AppCallError: Error {
    let error: PhoneFilesError?
}

/// The extension's link to the main app: the control service the app reaches through
/// `NSFileProviderManager.getService`, and the app's `PhoneFilesXPC` connection it hands over.
final class AppLink: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, FileProviderControlXPC,
    @unchecked Sendable {
    let serviceName = NSFileProviderServiceName(FullBuild.serviceName)
    let isRestricted = true
    /// The domain (the phone ID) this link serves.
    let domainID: String

    private let lock = NSLock()
    private var listener: NSXPCListener?
    private let slot = ConnectionSlot<NSXPCConnection>()
    private var cachedRoots: [RootDTO]?
    /// The app must be the Full app signed by this extension's team (when signed with one).
    private static let appRequirement = CodeRequirement.peer(identifier: CodeRequirement.appID, team: SigningTeam.current)

    init(domainID: String) {
        self.domainID = domainID
        super.init()
    }

    // MARK: NSFileProviderServiceSource

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        lock.withLock {
            if let listener { return listener.endpoint }
            let l = NSXPCListener.anonymous()
            l.delegate = self
            l.resume()
            listener = l
            return l.endpoint
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only connections that arrive on this anonymous listener. Its endpoint exists nowhere
        // but here and in the restricted service the system hands to processes that manage the
        // domain (`getService`), so that is every connection by construction.
        guard lock.withLock({ listener === self.listener }) else { return false }
        // Pinned to the app when this build is signed with a team; an ad hoc build has no team.
        if let requirement = Self.appRequirement { newConnection.setCodeSigningRequirement(requirement) }
        newConnection.exportedInterface = FullBuild.controlInterface()
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: FileProviderControlXPC

    func register(appEndpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable () -> Void) {
        let c = NSXPCConnection(listenerEndpoint: appEndpoint)
        c.remoteObjectInterface = FullBuild.phoneFilesInterface()
        if let requirement = Self.appRequirement { c.setCodeSigningRequirement(requirement) }
        c.invalidationHandler = { [weak self, weak c] in
            guard let self, let c else { return }
            self.slot.dropped(c)
            self.lock.withLock { self.cachedRoots = nil }
        }
        c.resume()
        lock.withLock { cachedRoots = nil }
        // A connection with calls still out is invalidated only once they end.
        slot.replace(with: c)?.invalidate()
        FileProviderExtension.log.info("app registered")
        reply()
    }

    func invalidate() {
        let l = lock.withLock {
            defer { listener = nil }
            return listener
        }
        l?.invalidate()
        while let c = slot.begin() {
            _ = slot.end(c)
            slot.dropped(c)
            c.invalidate()
        }
    }

    // MARK: calls

    func groupFolder(_ name: String) throws -> URL {
        guard let group = FullBuild.appGroupID(in: .main),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw AppCallError(error: .unreachable) }
        return container.appendingPathComponent(name, isDirectory: true)
    }

    /// The phone's roots, from the app once per connection unless `fresh` (the working set asks
    /// afresh whenever the app signals it).
    func roots(fresh: Bool = false) async throws -> [RootDTO] {
        if !fresh, let cached = lock.withLock({ cachedRoots }) { return cached }
        let data: Data = try await call { app, reply in app.roots(reply: reply) }
        let roots = try JSONDecoder().decode([RootDTO].self, from: data)
        lock.withLock { cachedRoots = roots }
        return roots
    }

    func list(rootID: String, path: String, offset: Int) async throws -> ListingDTO {
        let data: Data = try await call { app, reply in app.list(rootID: rootID, path: path, offset: offset, reply: reply) }
        return try JSONDecoder().decode(ListingDTO.self, from: data)
    }

    func download(rootID: String, path: String, token: String) async throws -> URL {
        try await call { app, reply in app.download(rootID: rootID, path: path, token: token, reply: reply) }
    }

    func upload(rootID: String, dirPath: String, from url: URL, token: String) async throws -> EntryDTO {
        let data: Data = try await call { app, reply in
            app.upload(rootID: rootID, dirPath: dirPath, from: url, token: token, reply: reply)
        }
        return try JSONDecoder().decode(EntryDTO.self, from: data)
    }

    /// Finder gave up: the app stops the call `token` names. Nothing waits for it.
    func cancel(token: String) {
        guard let c = slot.begin() else { return }
        (c.remoteObjectProxy as? PhoneFilesXPC)?.cancel(token: token)
        slot.end(c)?.invalidate()
    }

    /// One call to the app. Failures are `AppCallError`s.
    private func call<T: Sendable>(_ make: @escaping (PhoneFilesXPC, @escaping @Sendable (T?, Error?) -> Void) -> Void)
        async throws -> T {
        let connection = try await appConnection()
        let slot = slot
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once<Result<T, Error>> { result in
                slot.end(connection)?.invalidate()
                continuation.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.call(.failure(AppCallError(error: nil)))
            }
            guard let app = proxy as? PhoneFilesXPC else {
                once.call(.failure(AppCallError(error: nil)))
                return
            }
            make(app) { value, error in
                if let value {
                    once.call(.success(value))
                } else {
                    once.call(.failure(AppCallError(error: PhoneFilesError(error) ?? .failed)))
                }
            }
        }
    }

    /// The app's connection, counted as one call out; when there is none (the extension was
    /// relaunched, or the app is not running), the app is asked for its endpoint for this
    /// domain and given 3 seconds.
    private func appConnection() async throws -> NSXPCConnection {
        if let c = slot.begin() { return c }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(FullBuild.endpointNote(for: domainID) as CFString),
                                             nil, nil, true)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let c = slot.begin() { return c }
        }
        throw AppCallError(error: .unreachable)
    }
}

/// This process's signing team; nil when ad hoc or unsigned.
enum SigningTeam {
    static let current: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}

/// A completion handler called at most once, from any thread, with its arguments as one value.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((T) -> Void)?

    init(_ handler: @escaping (T) -> Void) {
        self.handler = handler
    }

    /// Calls the handler unless it was called already; false then.
    @discardableResult
    func call(_ value: T) -> Bool {
        guard let h = lock.withLock({ defer { handler = nil }; return handler }) else { return false }
        h(value)
        return true
    }
}
