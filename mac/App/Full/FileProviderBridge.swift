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
/// `browse.v1`, its File Provider domain is there (named after the phone) and connected, and the
/// extension is handed this app's `PhoneFilesXPC` endpoint for it. On disconnect the domain is
/// disconnected ("Your phone isn't connected."); it goes when the phone connects without
/// `browse.v1` or is forgotten. Domain work runs in order in its own task, never holding up the
/// session's work queue. Listings, downloads and uploads go through the `BrowseModel` request
/// paths (its read limit and deadlines included) without touching the Files tab. Downloads land
/// in the App Group's `Downloads/`; the extension moves each one out, and whatever is left goes
/// at the next launch.
/// Only phone IDs, root IDs and counts are logged, never names or paths.
@MainActor
final class FileProviderBridge: SessionFeature {
    let messagePrefixes: [String] = []

    private let browse: BrowseModel
    private let downloads: URL
    /// Where the extension stages uploads (read only through `StagedUpload`).
    private let uploads: URL
    /// The app's own copies of staged uploads, sent from here.
    private let sending: URL
    /// The connected phone, while it shares `browse.v1`.
    private var phone: (id: String, name: String)?
    /// One anonymous listener per phone domain registered this run.
    private var services: [String: PhoneFilesService] = [:]
    private var registering: Set<String> = []
    /// Domain work (add, connect, disconnect, remove, register), one after another.
    private var domainWork: Task<Void, Never>?
    /// The connected phone's endpoint note, while observed.
    private var observedNote: String?
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "fileprovider")
    /// The longest a register handshake with the extension may take.
    private static let registerTimeout: Duration = .seconds(10)

    init(browse: BrowseModel, container: URL, pairedPhoneIDs: @escaping @MainActor () -> Set<String>) {
        self.browse = browse
        downloads = container.appendingPathComponent(FullBuild.downloadsFolder, isDirectory: true)
        uploads = container.appendingPathComponent(FullBuild.uploadsFolder, isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        sending = caches.appendingPathComponent("io.github.anmirror.mac/finder-uploads", isDirectory: true)
        // What an earlier run left: downloads the extension never took, uploads never cleared.
        for folder in [downloads, uploads, sending] { try? FileManager.default.removeItem(at: folder) }
        watchRoots()
        // Domains of phones forgotten while the app was not running.
        enqueue {
            let paired = pairedPhoneIDs()
            for domain in (try? await NSFileProviderManager.domains()) ?? [] where !paired.contains(domain.identifier.rawValue) {
                _ = try? await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            }
        }
    }

    // MARK: SessionFeature

    func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        let domain = Self.domain(phoneID, name: phoneName)
        guard shared.contains("browse.v1") else {
            phone = nil
            observeEndpointNote(for: nil)
            services.removeValue(forKey: phoneID)?.invalidate()
            enqueue { _ = try? await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) }
            return
        }
        phone = (phoneID, phoneName)
        observeEndpointNote(for: phoneID)
        enqueue { [weak self] in
            do {
                try await NSFileProviderManager.add(domain)
            } catch {
                Self.log.error("domain \(phoneID, privacy: .public) not added: \((error as NSError).code, privacy: .public)")
                return
            }
            guard let self, self.phone?.id == phoneID, let manager = NSFileProviderManager(for: domain) else { return }
            try? await manager.reconnect()
            await self.register(phoneID)
            // The roots are checked again; folders list afresh when Finder opens them.
            try? await manager.signalEnumerator(for: .workingSet)
        }
    }

    /// The domain stays, disconnected: Finder says why and the extension is not called.
    func disconnected() {
        guard let phone else { return }
        self.phone = nil
        observeEndpointNote(for: nil)
        let domain = Self.domain(phone.id, name: phone.name)
        let reason = String(localized: "Your phone isn't connected.")
        enqueue { try? await NSFileProviderManager(for: domain)?.disconnect(reason: reason, options: []) }
    }

    func message(_ envelope: AMEnvelope) async {}

    func forget(phoneID: String) async {
        if phone?.id == phoneID {
            phone = nil
            observeEndpointNote(for: nil)
        }
        services.removeValue(forKey: phoneID)?.invalidate()
        let domain = Self.domain(phoneID, name: "")
        enqueue {
            _ = try? await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            Self.log.info("domain \(phoneID, privacy: .public) removed")
        }
    }

    // MARK: domain work

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = domainWork
        domainWork = Task {
            await previous?.value
            await work()
        }
    }

    private static func domain(_ phoneID: String, name: String) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: phoneID), displayName: name)
    }

    /// Hands the extension for `phoneID`'s domain this app's endpoint for that phone, through the
    /// extension's restricted control service, within `registerTimeout`.
    private func register(_ phoneID: String) async {
        guard !registering.contains(phoneID) else { return }
        registering.insert(phoneID)
        defer { registering.remove(phoneID) }
        let service = services[phoneID] ?? PhoneFilesService(phoneID: phoneID, bridge: self)
        services[phoneID] = service
        let registered = await Self.withTimeout(Self.registerTimeout) {
            await Self.handOver(service, phoneID: phoneID)
        }
        Self.log.info("endpoint for \(phoneID, privacy: .public): \(registered ? "registered" : "not registered", privacy: .public)")
    }

    private static func handOver(_ service: PhoneFilesService, phoneID: String) async -> Bool {
        do {
            guard let manager = NSFileProviderManager(for: domain(phoneID, name: "")),
                  let control = try await manager.service(named: NSFileProviderServiceName(FullBuild.serviceName), for: .rootContainer)
            else { return false }
            let connection = try await control.fileProviderConnection()
            // Pinned to our extension when the app is signed with a team; an ad hoc build has none.
            if let requirement = CodeRequirement.peer(identifier: CodeRequirement.fileProviderID, team: SigningTeam.current) {
                connection.setCodeSigningRequirement(requirement)
            }
            connection.remoteObjectInterface = FullBuild.controlInterface()
            connection.resume()
            defer { connection.invalidate() }
            // Ends at the extension's reply, the connection's error, or the timeout's cancel.
            let once = OnceResult()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) }
                    guard let extensionSide = proxy as? FileProviderControlXPC else { return once.resume(false) }
                    extensionSide.register(appEndpoint: service.endpoint) { once.resume(true) }
                }
            } onCancel: {
                once.resume(false)
            }
        } catch {
            log.error("endpoint for \(phoneID, privacy: .public): \((error as NSError).code, privacy: .public)")
            return false
        }
    }

    /// `work`'s answer, or false once `limit` has passed: the work is cancelled then. The timer
    /// stops when the work ends first.
    private static func withTimeout(_ limit: Duration, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        let once = OnceResult()
        let timer = CancelBox()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let worker = Task { @MainActor in
                let result = await work()
                timer.cancel()
                once.resume(result)
            }
            let sleeper = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                worker.cancel()
                once.resume(false)
            }
            timer.set { sleeper.cancel() }
        }
    }

    /// Observes the endpoint note of `phoneID`'s domain only (none for nil): an extension that
    /// was relaunched asks for the endpoint again.
    private func observeEndpointNote(for phoneID: String?) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedNote {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(old as CFString), nil)
        }
        observedNote = phoneID.map(FullBuild.endpointNote(for:))
        guard let name = observedNote else { return }
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let note = name.rawValue as String
                let bridge = Unmanaged<FileProviderBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in bridge.endpointWanted(note) }
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    private func endpointWanted(_ note: String) {
        // Only the connected phone's domain gets an endpoint.
        guard let phone, note == FullBuild.endpointNote(for: phone.id) else { return }
        // The extension holds a live connection already: nothing to hand over.
        if services[phone.id]?.hasLiveConnection == true { return }
        let id = phone.id
        enqueue { [weak self] in await self?.register(id) }
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
        NSFileProviderManager(for: Self.domain(phone.id, name: phone.name))?.signalEnumerator(for: .workingSet) { _ in }
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

    /// Cancelling the calling task (the extension's `cancel`) cancels the read (R20).
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
        // Quiet: a Finder read never puts a notice in the Files tab.
        switch await browse.download(entry, in: BrowseLocation(rootID: rootID, path: folder), to: file, quiet: true) {
        case let .success(url):
            return .success(url)
        case let .failure(failure):
            try? FileManager.default.removeItem(at: file)
            return .failure(Self.error(failure))
        }
    }

    /// Takes the staged file through `StagedUpload` (no link followed, a regular file only) into
    /// the app's own folder, and sends that copy. Cancelling the calling task cancels the send.
    func upload(for phoneID: String, rootID: String, dirPath: String, from url: URL) async -> Result<Data, PhoneFilesError> {
        guard phone?.id == phoneID else { return .failure(.unreachable) }
        let folder = sending.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        let uploads = uploads
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try StagedUpload.copy(url, stagedIn: uploads, to: copy)
            }.value
        } catch {
            Self.log.error("upload refused: not a staged file")
            return .failure(.denied)
        }
        switch await browse.upload(file: copy, into: BrowseLocation(rootID: rootID, path: dirPath)) {
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
        case .transfer(.cancelled): .cancelled
        case .transfer(.interrupted), .transfer(.disabled), .transfer(.timedOut): .unreachable
        case .transfer: .failed
        }
    }
}

/// The `PhoneFilesXPC` listener for one phone's domain. Its endpoint goes to that domain's
/// extension only, through `NSFileProviderManager.getService`. Downloads and uploads run as one
/// task per extension token, cancelled by `cancel(token:)` (ruling R20).
final class PhoneFilesService: NSObject, NSXPCListenerDelegate, PhoneFilesXPC, @unchecked Sendable {
    let phoneID: String
    private let bridge: FileProviderBridge
    private let listener = NSXPCListener.anonymous()
    private let tokens = CancelTokens()
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

    /// The extension holds a connection the system has not invalidated.
    var hasLiveConnection: Bool { lock.withLock { !connections.isEmpty } }

    func invalidate() {
        listener.invalidate()
        for c in lock.withLock({ defer { connections = [] }; return connections }) { c.invalidate() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only connections that arrive on this listener. It is anonymous, and its endpoint was
        // handed to nobody but this phone's File Provider extension (through the extension's
        // restricted service), so that is every connection it gets, by construction.
        guard listener === self.listener else { return false }
        // Pinned to our extension when the app is signed with a team. An ad hoc or unsigned
        // build has no team to pin, and a requirement would refuse every peer.
        if let requirement = CodeRequirement.peer(identifier: CodeRequirement.fileProviderID, team: SigningTeam.current) {
            newConnection.setCodeSigningRequirement(requirement)
        }
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

    func download(rootID: String, path: String, token: String, reply: @escaping @Sendable (URL?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        run(token, reply) { await bridge.download(for: phoneID, rootID: rootID, path: path) }
    }

    func upload(rootID: String, dirPath: String, from url: URL, token: String,
                reply: @escaping @Sendable (Data?, Error?) -> Void) {
        let (bridge, phoneID) = (bridge, phoneID)
        run(token, reply) { await bridge.upload(for: phoneID, rootID: rootID, dirPath: dirPath, from: url) }
    }

    func cancel(token: String) {
        tokens.cancel(token)
    }

    /// Runs `work` as the task `token` names, so `cancel(token:)` reaches it.
    private func run<T: Sendable>(_ token: String, _ reply: @escaping @Sendable (T?, Error?) -> Void,
                                  _ work: @escaping @MainActor @Sendable () async -> Result<T, PhoneFilesError>) {
        let box = CancelBox()
        let tokens = tokens
        tokens.begin(token) { box.cancel() }
        let task = Task { @MainActor in
            let result = await work()
            tokens.end(token)
            Self.answer(result, reply)
        }
        box.set { task.cancel() }
    }

    private static func answer<T>(_ result: Result<T, PhoneFilesError>, _ reply: (T?, Error?) -> Void) {
        switch result {
        case let .success(value): reply(value, nil)
        case let .failure(error): reply(nil, error.error)
        }
    }
}

/// Resumes a continuation once, whichever answer comes first; an answer before the
/// continuation is set is kept for it.
private final class OnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answer: Bool?
    private var done = false

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let early: Bool? = lock.withLock {
            if let answer { done = true; return answer }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !done, answer == nil else { return nil }
            guard let c = continuation else {
                answer = value
                return nil
            }
            done = true
            continuation = nil
            return c
        }
        waiting?.resume(returning: value)
    }
}
#endif
