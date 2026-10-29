#if FULL_BUILD
import AMProtocol
import ConnectionCore
import FeatureBrowse
import FeatureFiles
import FileProvider
import FileProviderShared
import Foundation
import Observation
import os

/// The Finder sidebar's side of the app (F-04, Full build). While the connected phone shares
/// `browse.v1`, its File Provider domain is there (named after the phone) and the extension is
/// handed this app's `PhoneFilesXPC` endpoint for it; the domain goes when the phone connects
/// without `browse.v1` or is forgotten. Listings, downloads and uploads go through the
/// `BrowseModel` request paths (its read limit and deadlines included) without moving the Files
/// tab's folder. Downloads land in the App Group's `Downloads/`; the extension moves each one
/// out, and whatever is left goes at the next launch.
/// Only phone IDs, root IDs and counts are logged, never names or paths.
@MainActor
final class FileProviderBridge: SessionFeature {
    let messagePrefixes: [String] = []

    private let browse: BrowseModel
    private let downloads: URL
    private let uploads: URL
    /// The connected phone, while it shares `browse.v1`.
    private var phone: (id: String, name: String)?
    /// One anonymous listener per phone domain registered this run.
    private var services: [String: PhoneFilesService] = [:]
    private var registering = false
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "fileprovider")

    init(browse: BrowseModel, container: URL, pairedPhoneIDs: @escaping @MainActor () -> Set<String>) {
        self.browse = browse
        downloads = container.appendingPathComponent(FullBuild.downloadsFolder, isDirectory: true)
        uploads = container.appendingPathComponent(FullBuild.uploadsFolder, isDirectory: true)
        // What an earlier run left: downloads the extension never took, uploads it never cleared.
        try? FileManager.default.removeItem(at: downloads)
        try? FileManager.default.removeItem(at: uploads)
        observeEndpointRequests()
        watchRoots()
        // Domains of phones forgotten while the app was not running.
        Task {
            let paired = pairedPhoneIDs()
            for domain in (try? await NSFileProviderManager.domains()) ?? [] where !paired.contains(domain.identifier.rawValue) {
                try? await NSFileProviderManager.remove(domain)
            }
        }
    }

    // MARK: SessionFeature

    func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: phoneID), displayName: phoneName)
        guard shared.contains("browse.v1") else {
            phone = nil
            try? await NSFileProviderManager.remove(domain)
            return
        }
        phone = (phoneID, phoneName)
        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            Self.log.error("domain \(phoneID, privacy: .public) not added: \((error as NSError).code, privacy: .public)")
            return
        }
        await register(phoneID)
        // What Finder listed in an earlier session may be stale: it lists again when shown.
        try? await NSFileProviderManager(for: domain)?.reimportItems(below: .rootContainer)
    }

    /// The domain stays; its calls answer "unreachable" until the phone is back.
    func disconnected() {
        phone = nil
    }

    func message(_ envelope: AMEnvelope) async {}

    func forget(phoneID: String) async {
        if phone?.id == phoneID { phone = nil }
        services.removeValue(forKey: phoneID)?.invalidate()
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: phoneID), displayName: "")
        try? await NSFileProviderManager.remove(domain)
        Self.log.info("domain \(phoneID, privacy: .public) removed")
    }

    // MARK: endpoint

    /// Hands the extension for `phoneID`'s domain this app's endpoint for that phone, through the
    /// extension's restricted control service.
    private func register(_ phoneID: String) async {
        let service = services[phoneID] ?? PhoneFilesService(phoneID: phoneID, bridge: self)
        services[phoneID] = service
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: phoneID), displayName: "")
        do {
            guard let manager = NSFileProviderManager(for: domain),
                  let control = try await manager.service(named: NSFileProviderServiceName(FullBuild.serviceName), for: .rootContainer)
            else { throw NSFileProviderError(.providerNotFound) }
            let connection = try await control.fileProviderConnection()
            connection.remoteObjectInterface = FullBuild.controlInterface()
            connection.resume()
            let registered: Bool = await withCheckedContinuation { continuation in
                let once = OnceResult(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) }
                guard let extensionSide = proxy as? FileProviderControlXPC else { return once.resume(false) }
                extensionSide.register(appEndpoint: service.endpoint) { once.resume(true) }
            }
            connection.invalidate()
            Self.log.info("endpoint for \(phoneID, privacy: .public): \(registered ? "registered" : "refused", privacy: .public)")
        } catch {
            Self.log.error("endpoint for \(phoneID, privacy: .public) not registered: \((error as NSError).code, privacy: .public)")
        }
    }

    /// The extension was relaunched and has no endpoint: it posts the Darwin note, and the
    /// connected phone's domain gets one again.
    private func observeEndpointRequests() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<FileProviderBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in await bridge.endpointWanted() }
            },
            FullBuild.darwinEndpointNote as CFString, nil, .deliverImmediately
        )
    }

    private func endpointWanted() async {
        guard let phone, !registering else { return }
        registering = true
        await register(phone.id)
        registering = false
    }

    /// The working set (the roots) is signalled whenever the phone's roots change.
    private func watchRoots() {
        withObservationTracking {
            _ = browse.roots
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.rootsChanged()
                self?.watchRoots()
            }
        }
    }

    private func rootsChanged() {
        guard let phone else { return }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: phone.id), displayName: phone.name)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    // MARK: PhoneFilesXPC, for `phoneID`'s domain

    func roots(for phoneID: String) async -> Result<Data, PhoneFilesError> {
        guard phone?.id == phoneID, browse.available else { return .failure(.unreachable) }
        // Just connected: the roots are on their way (the model's own deadline is 15 s).
        for _ in 0..<150 where !browse.rootsLoaded {
            try? await Task.sleep(for: .milliseconds(100))
            guard phone?.id == phoneID else { return .failure(.unreachable) }
        }
        guard browse.rootsLoaded else { return .failure(.unreachable) }
        let roots = browse.roots.map { RootDTO(id: $0.id, name: $0.name, writable: $0.writable) }
        return encode(roots)
    }

    func list(for phoneID: String, rootID: String, path: String, offset: Int) async -> Result<Data, PhoneFilesError> {
        guard phone?.id == phoneID else { return .failure(.unreachable) }
        switch await browse.list(rootID: rootID, path: path, offset: offset) {
        case let .success(listing):
            let entries = listing.entries.map {
                EntryDTO(name: $0.name, isDir: $0.isDir, size: $0.size, modifiedMs: $0.modifiedMs, mime: $0.mime)
            }
            return encode(ListingDTO(entries: entries, nextOffset: Int(listing.nextOffset), more: listing.more))
        case let .failure(failure):
            return .failure(Self.error(failure))
        }
    }

    func download(for phoneID: String, rootID: String, path: String) async -> Result<URL, PhoneFilesError> {
        guard phone?.id == phoneID else { return .failure(.unreachable) }
        let slash = path.lastIndex(of: "/")
        let folder = slash.map { String(path[..<$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        guard !name.isEmpty else { return .failure(.notFound) }
        let file = downloads.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            return .failure(.failed)
        }
        var entry = AMBrowseEntry()
        entry.name = name
        switch await browse.download(entry, in: BrowseLocation(rootID: rootID, path: folder), to: file) {
        case let .success(url):
            return .success(url)
        case let .failure(failure):
            try? FileManager.default.removeItem(at: file)
            return .failure(Self.error(failure))
        }
    }

    func upload(for phoneID: String, rootID: String, dirPath: String, from url: URL) async -> Result<Data, PhoneFilesError> {
        guard phone?.id == phoneID else { return .failure(.unreachable) }
        // Only a file the extension staged in the App Group's `Uploads/`: this unsandboxed app
        // must not send any other Mac file on the extension's say-so.
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let staging = uploads.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard url.isFileURL, file.pathComponents.count > staging.count,
              Array(file.pathComponents.prefix(staging.count)) == staging
        else {
            Self.log.error("upload refused: not a staged file")
            return .failure(.denied)
        }
        switch await browse.upload(file: file, into: BrowseLocation(rootID: rootID, path: dirPath)) {
        case let .success(item):
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return encode(EntryDTO(name: item.name, isDir: false, size: item.size, modifiedMs: now, mime: ""))
        case let .failure(failure):
            return .failure(Self.error(failure))
        }
    }

    // MARK: private

    private func encode<T: Encodable>(_ value: T) -> Result<Data, PhoneFilesError> {
        guard let data = try? JSONEncoder().encode(value) else { return .failure(.failed) }
        return .success(data)
    }

    private static func error(_ failure: TransferFailure) -> PhoneFilesError {
        switch failure {
        case .browse(.notFound): .notFound
        case .browse(.denied), .browse(.revoked): .denied
        case .browse: .failed
        case .transfer(.noSpace): .noSpace
        case .transfer(.interrupted), .transfer(.disabled), .transfer(.timedOut): .unreachable
        case .transfer: .failed
        }
    }
}

/// The `PhoneFilesXPC` listener for one phone's domain. Its endpoint goes to that domain's
/// extension only, through `NSFileProviderManager.getService`.
final class PhoneFilesService: NSObject, NSXPCListenerDelegate, PhoneFilesXPC, @unchecked Sendable {
    let phoneID: String
    private let bridge: FileProviderBridge
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    @MainActor
    init(phoneID: String, bridge: FileProviderBridge) {
        self.phoneID = phoneID
        self.bridge = bridge
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    func invalidate() {
        listener.invalidate()
        for c in lock.withLock({ defer { connections = [] }; return connections }) { c.invalidate() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only connections that arrive on this listener. It is anonymous, and its endpoint was
        // handed to nobody but this phone's File Provider extension (through the extension's
        // restricted service), so that is every connection it gets, by construction.
        guard listener === self.listener else { return false }
        newConnection.exportedInterface = FullBuild.phoneFilesInterface()
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self else { return }
            self.lock.withLock { self.connections.removeAll { $0 === newConnection } }
        }
        lock.withLock { connections.append(newConnection) }
        newConnection.resume()
        return true
    }

    func roots(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        Task { @MainActor in Self.answer(await bridge.roots(for: phoneID), reply) }
    }

    func list(rootID: String, path: String, offset: Int, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        Task { @MainActor in Self.answer(await bridge.list(for: phoneID, rootID: rootID, path: path, offset: offset), reply) }
    }

    func download(rootID: String, path: String, reply: @escaping @Sendable (URL?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        Task { @MainActor in Self.answer(await bridge.download(for: phoneID, rootID: rootID, path: path), reply) }
    }

    func upload(rootID: String, dirPath: String, from url: URL, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        Task { @MainActor in
            Self.answer(await bridge.upload(for: phoneID, rootID: rootID, dirPath: dirPath, from: url), reply)
        }
    }

    private static func answer<T>(_ result: Result<T, PhoneFilesError>, _ reply: (T?, Error?) -> Void) {
        switch result {
        case let .success(value): reply(value, nil)
        case let .failure(error): reply(nil, error.error)
        }
    }
}

/// Resumes a continuation once, whichever of the reply and the error handler comes first.
private final class OnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.withLock { defer { continuation = nil }; return continuation }?.resume(returning: value)
    }
}
#endif
