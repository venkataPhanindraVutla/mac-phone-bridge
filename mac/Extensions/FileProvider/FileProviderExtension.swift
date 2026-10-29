import FileProvider
import FileProviderShared
import Foundation
import os

/// Shows a paired phone in Finder's sidebar (F-04): one domain per phone, named after it. Every
/// listing, download and upload goes to the main app over XPC (`PhoneFilesXPC`), which serves
/// it from the phone while that phone is connected and browsing. Read-only browsing plus
/// downloads and uploads: nothing is renamed, moved or deleted from Finder.
/// Only counts and outcome codes are logged, never names or paths.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing,
    @unchecked Sendable {
    let domain: NSFileProviderDomain
    let app = AppLink()
    static let log = Logger(subsystem: "io.github.anmirror.mac.fileprovider", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
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
                let item = try await self.item(identifier)
                done.call((item, nil))
            } catch {
                done.call((nil, error))
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
        default:
            guard let (rootID, path) = PhoneItemID.decode(containerItemIdentifier.rawValue) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FolderEnumerator(app: app, rootID: rootID, path: path)
        }
    }

    // MARK: contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let done = Once<(URL?, NSFileProviderItem?, Error?)> { completionHandler($0.0, $0.1, $0.2) }
        let progress = Progress(totalUnitCount: 1)
        let domain = domain
        let task = Task {
            do {
                guard let (rootID, path) = PhoneItemID.decode(itemIdentifier.rawValue), !path.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let item = try await self.item(itemIdentifier)
                let downloaded = try await self.app.download(rootID: rootID, path: path)
                // Into the extension's own temporary folder (same volume as the domain), from
                // which the system clones and unlinks it; the App Group copy goes at once.
                guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
                let temp = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: downloaded, to: temp)
                } catch {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw error
                }
                if !done.call((temp, item, nil)) { try? FileManager.default.removeItem(at: temp) }
                progress.completedUnitCount = 1
            } catch {
                Self.log.info("fetch failed: \(Self.code(error), privacy: .public)")
                done.call((nil, nil, error))
            }
        }
        progress.cancellationHandler = {
            task.cancel()
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
        // Folders, links and anything without contents are not created on the phone.
        guard let url, itemTemplate.contentType != .folder, itemTemplate.contentType != .symbolicLink,
              let (rootID, dirPath) = PhoneItemID.decode(itemTemplate.parentItemIdentifier.rawValue)
        else {
            done.call((nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)))
            return progress
        }
        let name = itemTemplate.filename
        let task = Task {
            // The app sends the file under its own name, so it goes as `Uploads/<uuid>/<name>`;
            // the folder is removed once the app is done with it.
            var staged: URL?
            do {
                let folder = try self.app.groupFolder(FullBuild.uploadsFolder).appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                staged = folder
                let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
                try FileManager.default.copyItem(at: url, to: file)
                let entry = try await self.app.upload(rootID: rootID, dirPath: dirPath, from: file)
                let roots = try await self.app.roots()
                let writable = roots.first { $0.id == rootID }?.writable ?? false
                let item = PhoneItem.entry(entry, rootID: rootID, folderPath: dirPath, writable: writable)
                done.call((item, [], false, nil))
                progress.completedUnitCount = 1
            } catch {
                Self.log.info("create failed: \(Self.code(error), privacy: .public)")
                done.call((nil, [], false, error))
            }
            if let staged { try? FileManager.default.removeItem(at: staged) }
        }
        progress.cancellationHandler = {
            task.cancel()
            done.call((nil, [], false, CocoaError(.userCancelled)))
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
        -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress(totalUnitCount: 1)
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

    /// The item for `identifier`: the phone, a root, or an entry found in its folder's listing.
    private func item(_ identifier: NSFileProviderItemIdentifier) async throws -> PhoneItem {
        if identifier == .rootContainer { return PhoneItem.container(named: domain.displayName) }
        guard let (rootID, path) = PhoneItemID.decode(identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        let roots = try await app.roots()
        guard let root = roots.first(where: { $0.id == rootID }) else { throw NSFileProviderError(.noSuchItem) }
        if path.isEmpty { return PhoneItem.root(root) }
        let (folder, name) = split(path)
        var offset = 0
        // A folder is listed page by page until the name turns up; at most 20 pages.
        for _ in 0..<20 {
            let page = try await app.list(rootID: rootID, path: folder, offset: offset)
            if let entry = page.entries.first(where: { $0.name == name }) {
                return PhoneItem.entry(entry, rootID: rootID, folderPath: folder, writable: root.writable)
            }
            guard page.more, page.nextOffset > offset else { break }
            offset = page.nextOffset
        }
        throw NSFileProviderError(.noSuchItem)
    }

    static func code(_ error: any Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }
}

/// The extension's link to the main app: the control service the app reaches through
/// `NSFileProviderManager.getService`, and the app's `PhoneFilesXPC` connection it hands over.
final class AppLink: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, FileProviderControlXPC,
    @unchecked Sendable {
    let serviceName = NSFileProviderServiceName(FullBuild.serviceName)
    let isRestricted = true

    private let lock = NSLock()
    private var listener: NSXPCListener?
    private var connection: NSXPCConnection?
    private var cachedRoots: [RootDTO]?

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
        newConnection.exportedInterface = FullBuild.controlInterface()
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: FileProviderControlXPC

    func register(appEndpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable () -> Void) {
        let c = NSXPCConnection(listenerEndpoint: appEndpoint)
        c.remoteObjectInterface = FullBuild.phoneFilesInterface()
        c.invalidationHandler = { [weak self, weak c] in
            guard let self else { return }
            self.lock.withLock {
                if self.connection === c {
                    self.connection = nil
                    self.cachedRoots = nil
                }
            }
        }
        c.resume()
        let old = lock.withLock {
            let old = connection
            connection = c
            cachedRoots = nil
            return old
        }
        old?.invalidate()
        FileProviderExtension.log.info("app registered")
        reply()
    }

    func invalidate() {
        let (l, c) = lock.withLock {
            defer { listener = nil; connection = nil }
            return (listener, connection)
        }
        l?.invalidate()
        c?.invalidate()
    }

    // MARK: calls

    func groupFolder(_ name: String) throws -> URL {
        guard let group = FullBuild.appGroupID(in: .main),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw NSFileProviderError(.serverUnreachable) }
        return container.appendingPathComponent(name, isDirectory: true)
    }

    /// The phone's roots, from the app once per connection (the app signals the working set
    /// when they change, and that call asks again).
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

    func download(rootID: String, path: String) async throws -> URL {
        try await call { app, reply in app.download(rootID: rootID, path: path, reply: reply) }
    }

    func upload(rootID: String, dirPath: String, from url: URL) async throws -> EntryDTO {
        let data: Data = try await call { app, reply in app.upload(rootID: rootID, dirPath: dirPath, from: url, reply: reply) }
        return try JSONDecoder().decode(EntryDTO.self, from: data)
    }

    /// One call to the app, its errors as File Provider errors.
    private func call<T: Sendable>(_ make: @escaping (PhoneFilesXPC, @escaping @Sendable (T?, Error?) -> Void) -> Void)
        async throws -> T {
        let connection = try await appConnection()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once<Result<T, Error>> { continuation.resume(with: $0) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.call(.failure(NSFileProviderError(.serverUnreachable)))
            }
            guard let app = proxy as? PhoneFilesXPC else {
                once.call(.failure(NSFileProviderError(.serverUnreachable)))
                return
            }
            make(app) { value, error in
                if let value {
                    once.call(.success(value))
                } else {
                    once.call(.failure(Self.fileProviderError(error)))
                }
            }
        }
    }

    /// The app's connection; when there is none (the extension was relaunched, or the app is
    /// not running), the app is asked to register again and given 3 seconds.
    private func appConnection() async throws -> NSXPCConnection {
        if let c = lock.withLock({ connection }) { return c }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(FullBuild.darwinEndpointNote as CFString), nil, nil, true)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if let c = lock.withLock({ connection }) { return c }
        }
        throw NSFileProviderError(.serverUnreachable)
    }

    private static func fileProviderError(_ error: (any Error)?) -> any Error {
        switch PhoneFilesError(error) {
        case .notFound: NSFileProviderError(.noSuchItem)
        case .denied: CocoaError(.fileReadNoPermission)
        case .noSpace: NSFileProviderError(.insufficientQuota)
        case .failed: CocoaError(.fileReadUnknown)
        case .unreachable, nil: NSFileProviderError(.serverUnreachable)
        }
    }
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
