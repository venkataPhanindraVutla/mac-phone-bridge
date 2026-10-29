import AMProtocol
import ConnectionCore
import FeatureFiles
import Foundation
import Observation
import os
import SwiftProtobuf

/// A folder on the phone: a root and a `/`-separated path in it, `""` being the root (SPEC section 19).
public struct BrowseLocation: Hashable, Sendable {
    public let rootID: String
    public let path: String

    public init(rootID: String, path: String = "") {
        self.rootID = rootID
        self.path = path
    }

    /// The path's segments; none at the root.
    public var segments: [String] { path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }

    /// The folder this one is in; nil at the root.
    public var parent: BrowseLocation? {
        guard !path.isEmpty else { return nil }
        return BrowseLocation(rootID: rootID, path: segments.dropLast().joined(separator: "/"))
    }

    /// The path of `name` in this folder.
    public func path(of name: String) -> String { path.isEmpty ? name : "\(path)/\(name)" }

    /// The folder `name` in this one.
    public func appending(_ name: String) -> BrowseLocation { BrowseLocation(rootID: rootID, path: path(of: name)) }
}

/// Why the last thing the Files tab did, did not work.
public enum BrowseNotice: Equatable, Sendable {
    /// The phone lost access to the folder (or stopped browsing altogether).
    case revoked
    case notFound
    /// The root is read-only, or the phone said no.
    case denied
    /// The name is taken, or a file is still being written into that folder (mkdir, rename).
    case exists
    /// A delete refused (EXISTS) because files are still being written into that folder.
    case inUse
    /// The name the user typed is not a safe file name as it stands (SPEC section 16).
    case badName
    case failed
    case timedOut
}

/// Browsing the phone's files (SPEC section 19), for the Phone window's Files tab, while the phone
/// shares `browse.v1`. Each `browse.*` request gets an ID from the engine and waits up to
/// `requestTimeout` for its answer. Reads (`browse.read`) are answered by an offer the transfer
/// engine receives into the promised file (its own deadline, ruling R15); at most `maxReads` are
/// outstanding, the rest wait here (ruling R17). Writes go as targeted sends through the engine.
/// Only request IDs, root IDs, counts and outcome codes are logged, never paths or names.
@MainActor
@Observable
public final class BrowseModel: SessionFeature {
    public let messagePrefixes = ["browse."]

    /// Entries asked for per `browse.list` (the SPEC's maximum).
    public static let pageSize: UInt32 = 500
    /// `browse.read` requests outstanding at once (R17); the phone refuses past 64.
    public static let maxReads = 8

    /// The phone's browse roots, as it last listed them.
    public private(set) var roots: [AMBrowseRoot] = []
    /// The roots have come (or the phone said browsing is off) since the connect.
    public private(set) var rootsLoaded = false
    /// The folder shown; nil before one is opened and once its root is gone.
    public private(set) var location: BrowseLocation?
    /// The pages of `location` loaded so far, as the phone sorted them.
    public private(set) var entries: [AMBrowseEntry] = []
    /// More entries follow the loaded ones.
    public private(set) var hasMore = false
    /// A page is being fetched.
    public private(set) var loading = false
    public private(set) var notice: BrowseNotice?
    /// The phone's last `browse.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?
    /// The phone in session shares `browse.v1`.
    public private(set) var available = false

    @ObservationIgnored private let engine: TransferEngine
    @ObservationIgnored private let requestTimeout: Duration
    @ObservationIgnored private let outbox: AsyncStream<Outgoing>.Continuation
    @ObservationIgnored private let session = Counter()

    @ObservationIgnored private var isConnected = false
    @ObservationIgnored private var sharesBrowse = false
    /// Requests waiting for their `browse.listing` or `browse.result`, by request ID.
    @ObservationIgnored private var waiting: [UInt64: Answer<Reply>] = [:]
    /// Moves on whenever what `entries` shows changes owner (open, reload, clear): older pages are dropped.
    @ObservationIgnored private var listGeneration: UInt64 = 0
    @ObservationIgnored private var nextOffset: UInt32 = 0
    @ObservationIgnored private var rootsTimer: Task<Void, Never>?
    /// Reads not yet sent, oldest first, and reads sent whose download has not ended.
    @ObservationIgnored private var queuedReads: [Read] = []
    @ObservationIgnored private var sentReads: [UInt64: Read] = [:]
    /// Uploads under way, by transfer ID, with the folder they go into.
    @ObservationIgnored private var uploads: [String: BrowseLocation] = [:]
    /// `upload(file:into:)` calls waiting for their transfer to end, by transfer ID.
    @ObservationIgnored private var uploadWaiters: [String: Answer<Result<TransferItem, TransferFailure>>] = [:]
    @ObservationIgnored private var reloadRunning = false
    @ObservationIgnored private var reloadAgain = false
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "browse")

    public init(engine: TransferEngine,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                requestTimeout: Duration = .seconds(15)) {
        self.engine = engine
        self.requestTimeout = requestTimeout
        // One sender, so requests leave in the order they were made.
        let (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        outbox = continuation
        let session = self.session
        Task {
            for await o in stream where o.session == session.value { await send(o.type, o.message) }
        }
    }

    deinit { outbox.finish() }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        endSession()
        isConnected = true
        sharesBrowse = shared.contains("browse.v1")
        available = sharesBrowse
        if sharesBrowse { requestRoots() }
    }

    /// Every waiting request ends unanswered, and what was shown of the phone goes.
    public func disconnected() {
        endSession()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard sharesBrowse else { return }
        let p = envelope.payload
        switch MessageType(rawValue: envelope.type) {
        case .browseRoots:
            if let m = try? AMBrowseRoots(serializedBytes: p) { rootsArrived(m.roots) }
        case .browseListing:
            if let m = try? AMBrowseListing(serializedBytes: p) { waiting.removeValue(forKey: m.requestID)?.resolve(.listing(m)) }
        case .browseResult:
            guard let m = try? AMBrowseResult(serializedBytes: p) else { return }
            if sentReads[m.requestID] != nil {
                readRefused(m)
            } else {
                waiting.removeValue(forKey: m.requestID)?.resolve(.result(m))
            }
        case .browseAvailability:
            if let m = try? AMFeatureAvailability(serializedBytes: p) { availabilityArrived(m) }
        default:
            break
        }
    }

    public func forget(phoneID: String) async {}

    // MARK: API

    /// Asks the phone for its roots again (`browse.roots` answers).
    /// Nothing is sent while a roots request is still waiting for its answer.
    public func refreshRoots() {
        guard sharesBrowse, rootsTimer == nil else { return }
        if notice == .timedOut { notice = nil }
        requestRoots()
    }

    /// Shows `location`'s first page. A root the phone has not listed is not opened.
    public func open(_ location: BrowseLocation) async {
        guard sharesBrowse, roots.contains(where: { $0.id == location.rootID }) else { return }
        listGeneration &+= 1
        self.location = location
        entries = []
        hasMore = false
        nextOffset = 0
        notice = nil
        await list(from: 0, atLeast: 0, append: false)
    }

    /// The next page, if there is one and none is being fetched.
    public func loadMore() async {
        guard sharesBrowse, location != nil, hasMore, !loading else { return }
        await list(from: nextOffset, atLeast: 0, append: true)
    }

    /// Opens the folder `location` is in; nothing at a root.
    public func up() async {
        guard let parent = location?.parent else { return }
        await open(parent)
    }

    /// Fetches the pages shown again, from the first, as many entries as were loaded.
    public func reload() async {
        guard sharesBrowse, location != nil else { return }
        listGeneration &+= 1
        await list(from: 0, atLeast: entries.count, append: false)
    }

    /// `browse.mkdir` in `location`; the name must be a safe file name as typed (spaces around it
    /// aside), else `.badName` and nothing is sent.
    public func makeFolder(named name: String) async {
        guard sharesBrowse, let location else { return }
        guard let clean = checked(name) else { return }
        let path = location.path(of: clean)
        await change(.browseMkdir, naming: true) { id in
            var m = AMBrowsePath()
            m.requestID = id
            m.rootID = location.rootID
            m.path = path
            return m
        }
    }

    /// `browse.delete` of `entry` in `location` (recursive on the phone).
    public func delete(_ entry: AMBrowseEntry) async {
        guard sharesBrowse, let location else { return }
        let path = location.path(of: entry.name)
        await change(.browseDelete, naming: false, deleting: true) { id in
            var m = AMBrowsePath()
            m.requestID = id
            m.rootID = location.rootID
            m.path = path
            return m
        }
    }

    /// `browse.rename` of `entry` in `location`; the new name follows `makeFolder`'s rule.
    public func rename(_ entry: AMBrowseEntry, to newName: String) async {
        guard sharesBrowse, let location else { return }
        guard let clean = checked(newName), clean != entry.name else { return }
        let path = location.path(of: entry.name)
        await change(.browseRename, naming: true) { id in
            var m = AMBrowseRename()
            m.requestID = id
            m.rootID = location.rootID
            m.path = path
            m.newName = clean
            return m
        }
    }

    /// Fetches `entry` of `location` to exactly `file` (a file promise's file).
    public func download(_ entry: AMBrowseEntry, to file: URL) async -> Result<URL, TransferFailure> {
        guard sharesBrowse, let location else { return .failure(.transfer(!isConnected ? .interrupted : sharesBrowse ? .notFound : .disabled)) }
        return await download(entry, in: location, to: file)
    }

    /// Fetches `entry` of `folder` to exactly `file`. Waits its turn behind `maxReads` reads.
    /// Cancelling the calling task drops a read still waiting (it is never sent), or cancels its
    /// request or transfer.
    public func download(_ entry: AMBrowseEntry, in folder: BrowseLocation, to file: URL) async -> Result<URL, TransferFailure> {
        guard isConnected else { return .failure(.transfer(.interrupted)) }
        guard sharesBrowse else { return .failure(.transfer(.disabled)) }
        guard !entry.isDir else { return .failure(.browse(.badPath)) }
        let read = Read(requestID: engine.nextRequestID(), rootID: folder.rootID, path: folder.path(of: entry.name), file: file)
        let requestID = read.requestID
        let cancelled = read.cancelled
        let result = await withTaskCancellationHandler {
            // Cancelled already (the drag gave up): never queued, never sent.
            guard !Task.isCancelled else { return Result<URL, TransferFailure>.failure(.transfer(.cancelled)) }
            queuedReads.append(read)
            pumpReads()
            return await read.answer.wait() ?? .failure(.transfer(.interrupted))
        } onCancel: {
            // Marked at once, so a slot that frees before the hop below does not send it.
            cancelled.set()
            Task { @MainActor [weak self] in self?.cancelRead(requestID) }
        }
        if case let .failure(failure) = result {
            Self.log.info("read \(requestID, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        }
        return result
    }

    /// Sends the files among `urls` into `location`, never over an existing file (the phone adds a
    /// counter). Folders and packages are skipped. The folder reloads as each one arrives.
    public func upload(_ urls: [URL]) async {
        guard sharesBrowse, let location else { return }
        let files = SendableFiles.split(urls).files
        guard !files.isEmpty else { return }
        var target = AMBrowseTarget()
        target.rootID = location.rootID
        target.dirPath = location.path
        target.overwrite = false
        for id in engine.send(files: files, target: target) { uploads[id] = location }
        Self.log.info("upload of \(files.count, privacy: .public) into root \(location.rootID, privacy: .public)")
    }

    // MARK: any folder (the Full build's Finder sidebar)

    /// One page (`pageSize` entries) of the folder `path` of `rootID` from `offset`, whatever the
    /// Files tab shows: nothing shown changes, and no notice is set. Fails `INTERRUPTED` with no
    /// phone or when the session ends first, `DISABLED` when browsing is not shared or is off on
    /// the phone, `TIMED_OUT` after `requestTimeout`, else with the phone's outcome.
    public func list(rootID: String, path: String, offset: Int) async -> Result<AMBrowseListing, TransferFailure> {
        guard isConnected else { return .failure(.transfer(.interrupted)) }
        guard sharesBrowse else { return .failure(.transfer(.disabled)) }
        let from = UInt32(clamping: max(0, offset))
        let reply = await ask(.browseList) { id in
            var m = AMBrowseListRequest()
            m.requestID = id
            m.rootID = rootID
            m.path = path
            m.offset = from
            m.limit = Self.pageSize
            return m
        }
        switch reply {
        case let .listing(l) where l.outcome == .ok:
            return .success(l)
        case let .listing(l):
            Self.log.info("list in root \(rootID, privacy: .public) failed: \(l.outcome.rawValue, privacy: .public)")
            return .failure(.browse(l.outcome))
        case let .result(r):
            return .failure(.browse(r.outcome == .ok ? .io : r.outcome))
        case .timedOut:
            return .failure(.transfer(.timedOut))
        case .failed:
            let off = isConnected && phoneAvailability?.enabled == false
            return .failure(.transfer(off ? .disabled : .interrupted))
        }
    }

    /// Sends `file` into `folder`, never over an existing file (the phone adds a counter), and
    /// returns once its transfer has ended: the item when the phone has it, else why not. A
    /// folder or a package is not sent (`BAD_PATH`). The folder reloads if it is the one shown.
    public func upload(file: URL, into folder: BrowseLocation) async -> Result<TransferItem, TransferFailure> {
        guard isConnected else { return .failure(.transfer(.interrupted)) }
        guard sharesBrowse else { return .failure(.transfer(.disabled)) }
        guard SendableFiles.split([file]).files.count == 1 else { return .failure(.browse(.badPath)) }
        var target = AMBrowseTarget()
        target.rootID = folder.rootID
        target.dirPath = folder.path
        target.overwrite = false
        guard let id = engine.send(files: [file], target: target).first else { return .failure(.transfer(.io)) }
        uploads[id] = folder
        let answer = Answer<Result<TransferItem, TransferFailure>>()
        uploadWaiters[id] = answer
        Self.log.info("upload \(id, privacy: .public) into root \(folder.rootID, privacy: .public)")
        return await answer.wait() ?? .failure(.transfer(.interrupted))
    }

    /// The engine finished a transfer (`TransferEngine.onFinished`): an upload that the phone
    /// received reloads the folder it went into, if that is still the one shown.
    public func transferFinished(_ item: TransferItem) {
        if let waiter = uploadWaiters.removeValue(forKey: item.id) {
            switch item.state {
            case .done: waiter.resolve(.success(item))
            case let .failed(reason): waiter.resolve(.failure(.transfer(reason)))
            case .cancelled: waiter.resolve(.failure(.transfer(.cancelled)))
            case .queued, .waiting, .active: waiter.resolve(.failure(.transfer(.interrupted)))
            }
        }
        guard let into = uploads.removeValue(forKey: item.id), case .done = item.state, into == location else { return }
        reloadSoon()
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: private

    /// Ends what this session had: waiting requests end unanswered, queued and sent reads fail
    /// `INTERRUPTED`, and everything shown goes.
    private func endSession() {
        session.value &+= 1
        isConnected = false
        sharesBrowse = false
        available = false
        let answers = waiting
        waiting = [:]
        for a in answers.values { a.resolve(.failed) }
        let reads = queuedReads + Array(sentReads.values)
        let sent = Array(sentReads.keys)
        queuedReads = []
        sentReads = [:]
        // The engine may not have heard of the disconnect yet: its expectations go too.
        for id in sent { engine.failRequest(id, .transfer(.interrupted)) }
        for r in reads { r.answer.resolve(.failure(.transfer(.interrupted))) }
        uploads = [:]
        let uploading = uploadWaiters
        uploadWaiters = [:]
        for a in uploading.values { a.resolve(.failure(.transfer(.interrupted))) }
        rootsTimer?.cancel()
        rootsTimer = nil
        roots = []
        rootsLoaded = false
        phoneAvailability = nil
        notice = nil
        closeLocation()
    }

    private func closeLocation() {
        listGeneration &+= 1
        location = nil
        entries = []
        hasMore = false
        nextOffset = 0
        loading = false
    }

    private func requestRoots() {
        post(.browseRootsRequest, AMBrowseRootsRequest())
        rootsTimer?.cancel()
        let timeout = requestTimeout, session = session.value
        rootsTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.session.value == session else { return }
            self.rootsTimer = nil
            guard !self.rootsLoaded else { return }
            Self.log.info("roots did not come")
            self.notice = .timedOut
        }
    }

    private func rootsArrived(_ list: [AMBrowseRoot]) {
        rootsTimer?.cancel()
        rootsTimer = nil
        roots = list
        if !rootsLoaded, notice == .timedOut { notice = nil }
        rootsLoaded = true
        Self.log.info("roots: \(list.count, privacy: .public)")
        if let location, !list.contains(where: { $0.id == location.rootID }) {
            Self.log.info("root \(location.rootID, privacy: .public) is gone")
            closeLocation()
            notice = .revoked
        }
    }

    /// Browsing off on the phone (any `enabled = false`): no `browse.roots` comes then, so the
    /// roots go here. Waiting requests and reads end; the phone answers nothing while off.
    private func availabilityArrived(_ a: AMFeatureAvailability) {
        let wasOff = phoneAvailability.map { !$0.enabled } ?? false
        phoneAvailability = a
        if a.enabled {
            if wasOff {
                // Loading again: the tab shows it, and the roots timer can fire.
                rootsLoaded = false
                requestRoots()
            }
            return
        }
        Self.log.info("browsing off on the phone: \(a.reason.rawValue, privacy: .public)")
        let answers = waiting
        waiting = [:]
        for answer in answers.values { answer.resolve(.failed) }
        let queued = queuedReads
        queuedReads = []
        for r in queued { r.answer.resolve(.failure(.transfer(.disabled))) }
        for id in sentReads.keys { engine.failRequest(id, .transfer(.disabled)) }
        rootsTimer?.cancel()
        rootsTimer = nil
        roots = []
        rootsLoaded = true
        // The tab says to turn browsing on; no other notice.
        closeLocation()
        notice = nil
    }

    /// `browse.list` pages of `location` from `offset` until at least `atLeast` entries are in
    /// (one page when 0), then shown at once: appended or replacing.
    private func list(from offset: UInt32, atLeast: Int, append: Bool) async {
        guard let location else { return }
        let generation = listGeneration, session = session.value
        loading = true
        var collected: [AMBrowseEntry] = append ? entries : []
        // Names are the list's row IDs: a name already in (a folder that changed between pages
        // shifts the offsets) is kept once.
        var names = Set(collected.map(\.name))
        let start = collected.count
        var offset = offset
        while true {
            let from = offset
            let reply = await ask(.browseList) { id in
                var m = AMBrowseListRequest()
                m.requestID = id
                m.rootID = location.rootID
                m.path = location.path
                m.offset = from
                m.limit = Self.pageSize
                return m
            }
            // A newer open or reload, or another session, owns the list now.
            guard generation == listGeneration, session == self.session.value else { return }
            switch reply {
            case let .listing(l) where l.outcome == .ok:
                for e in l.entries where names.insert(e.name).inserted { collected.append(e) }
                // A page that does not move on ends the listing, whatever `more` says.
                let more = l.more && l.nextOffset > offset
                offset = l.nextOffset
                if more, collected.count - start < atLeast { continue }
                entries = collected
                hasMore = more
                nextOffset = offset
                loading = false
                return
            case let .listing(l):
                Self.log.info("list failed: \(l.outcome.rawValue, privacy: .public)")
                loading = false
                notice = Self.notice(for: l.outcome, naming: false)
                return
            case .result:
                loading = false
                notice = .failed
                return
            case .timedOut:
                loading = false
                notice = .timedOut
                return
            case .failed:
                loading = false
                return
            }
        }
    }

    /// A change (mkdir, delete, rename): on OK the folder reloads, else the notice says why.
    private func change(_ type: MessageType, naming: Bool, deleting: Bool = false,
                        _ make: (UInt64) -> any SwiftProtobuf.Message & Sendable) async {
        let session = session.value
        notice = nil
        let reply = await ask(type, make)
        guard session == self.session.value else { return }
        switch reply {
        case let .result(r) where r.outcome == .ok:
            await reload()
        case let .result(r):
            Self.log.info("\(type.rawValue, privacy: .public) failed: \(r.outcome.rawValue, privacy: .public)")
            notice = deleting && r.outcome == .exists ? .inUse : Self.notice(for: r.outcome, naming: naming)
        case .listing:
            notice = .failed
        case .timedOut:
            notice = .timedOut
        case .failed:
            break
        }
    }

    /// Sends a request with a new ID and waits for its answer, `.timedOut` after `requestTimeout`.
    private func ask(_ type: MessageType, _ make: (UInt64) -> any SwiftProtobuf.Message & Sendable) async -> Reply {
        let id = engine.nextRequestID()
        let answer = Answer<Reply>()
        waiting[id] = answer
        let timeout = requestTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let answer = self.waiting.removeValue(forKey: id) else { return }
            Self.log.info("\(type.rawValue, privacy: .public) \(id, privacy: .public) timed out")
            answer.resolve(.timedOut)
        }
        post(type, make(id))
        let reply = await answer.wait() ?? .failed
        timer.cancel()
        return reply
    }

    /// The name with spaces around it trimmed, if it is its own sanitized form and not empty;
    /// else `.badName` and nil.
    private func checked(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileNameSanitizer.sanitize(trimmed) == trimmed else {
            notice = .badName
            return nil
        }
        return trimmed
    }

    /// Reloads once per burst of finished uploads.
    private func reloadSoon() {
        guard !reloadRunning else {
            reloadAgain = true
            return
        }
        reloadRunning = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.reloadAgain = false
                await self.reload()
            } while self.reloadAgain
            self.reloadRunning = false
        }
    }

    // MARK: reads

    private func pumpReads() {
        while sharesBrowse, sentReads.count < Self.maxReads, !queuedReads.isEmpty {
            let read = queuedReads.removeFirst()
            if read.cancelled.isSet {
                read.answer.resolve(.failure(.transfer(.cancelled)))
                continue
            }
            sentReads[read.requestID] = read
            let id = read.requestID
            engine.expect(requestID: id, destination: .file(read.file)) { [weak self] result in
                self?.readEnded(id, result)
            }
            var m = AMBrowsePath()
            m.requestID = id
            m.rootID = read.rootID
            m.path = read.path
            post(.browseRead, m)
        }
    }

    private func readEnded(_ id: UInt64, _ result: Result<URL, TransferFailure>) {
        guard let read = sentReads.removeValue(forKey: id) else { return }
        read.answer.resolve(result)
        pumpReads()
    }

    /// `browse.result` instead of an offer: the download ends with that outcome.
    private func readRefused(_ r: AMBrowseResult) {
        guard r.outcome != .ok else { return }
        notice = Self.notice(for: r.outcome, naming: false)
        engine.failRequest(r.requestID, .browse(r.outcome))
    }

    private func cancelRead(_ id: UInt64) {
        if let i = queuedReads.firstIndex(where: { $0.requestID == id }) {
            queuedReads.remove(at: i).answer.resolve(.failure(.transfer(.cancelled)))
        } else if sentReads[id] != nil {
            engine.cancelRequest(id)
        }
    }

    private func post(_ type: MessageType, _ message: any SwiftProtobuf.Message & Sendable) {
        guard sharesBrowse else { return }
        outbox.yield(Outgoing(session: session.value, type: type, message: message))
    }

    private static func notice(for outcome: AMBrowseOutcome, naming: Bool) -> BrowseNotice? {
        switch outcome {
        case .ok: nil
        case .notFound: .notFound
        case .exists: .exists
        case .denied: .denied
        case .revoked: .revoked
        case .badPath: naming ? .badName : .failed
        case .io, .unspecified, .UNRECOGNIZED: .failed
        }
    }
}

// MARK: private types

private enum Reply: Sendable {
    case listing(AMBrowseListing)
    case result(AMBrowseResult)
    /// The session ended, or the phone stopped browsing, before an answer came.
    case failed
    case timedOut
}

private struct Outgoing: Sendable {
    let session: UInt64
    let type: MessageType
    let message: any SwiftProtobuf.Message & Sendable
}

@MainActor
private final class Counter {
    var value: UInt64 = 0
}

/// One `browse.read`, queued or sent.
@MainActor
private final class Read {
    let requestID: UInt64
    let rootID: String
    let path: String
    let file: URL
    let answer = Answer<Result<URL, TransferFailure>>()
    /// Set by the calling task's cancellation handler, on whatever thread it runs.
    nonisolated let cancelled = CancelFlag()

    init(requestID: UInt64, rootID: String, path: String, file: URL) {
        self.requestID = requestID
        self.rootID = rootID
        self.path = path
        self.file = file
    }
}

/// A flag set once from any thread.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// One answer, given at most once, that one caller waits for.
@MainActor
private final class Answer<T: Sendable> {
    private var done = false
    private var value: T?
    private var waiter: CheckedContinuation<T?, Never>?

    func resolve(_ v: T?) {
        guard !done else { return }
        done = true
        value = v
        waiter?.resume(returning: v)
        waiter = nil
    }

    func wait() async -> T? {
        if done { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}
