import AMProtocol
import ConnectionCore
import FeatureFiles
import Foundation
import Observation
import os
import SwiftProtobuf
import UniformTypeIdentifiers

/// The phone's newest photos and videos (SPEC section 18), while the phone shares `photos.v1`.
/// `refresh()` lists the newest 200 (`photos.list`), then asks for all their thumbnails at once
/// (`photos.thumbs`); the phone streams them over one bulk connection (role `THUMBNAILS`),
/// handed in through `thumbnailLink(_:)`. One thumbnails request is outstanding at a time: a newer
/// refresh revokes the older token and closes the older link.
///
/// Thumbnails live in memory only and are dropped by `clear()`, on disconnect, and when the Phone
/// window closes. A photo itself comes as a `TRANSFER_KIND_PHOTO` offer answering a `photos.fetch`,
/// received by the transfer engine into Downloads (`save`) or a file promise's file (`fetch`).
/// Only IDs and counts are logged, never names, dates or bytes.
@MainActor
@Observable
public final class PhotosModel: SessionFeature {
    public let messagePrefixes = ["photos."]

    /// The bulk token context of a thumbnails request.
    public static let thumbsContext = "thumbs"
    /// How many items a refresh lists (the `photos.items` limit).
    public static let pageSize: UInt32 = 200

    /// Newest first, as the phone listed them.
    public private(set) var items: [AMPhotoItem] = []
    /// JPEG thumbnails by item ID, as they arrive; an item with none has no entry. Memory only.
    public private(set) var thumbnails: [Int64: Data] = [:]
    /// The phone lists only the photos the user picked there.
    public private(set) var partialAccess = false
    /// The phone's last `photos.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?
    /// A refresh is waiting for the list.
    public private(set) var loading = false

    @ObservationIgnored private let engine: TransferEngine
    @ObservationIgnored private let bulk: any BulkGrants
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let downloads: URL
    @ObservationIgnored private let requestTimeout: Duration
    @ObservationIgnored private let fetchTimeout: Duration
    @ObservationIgnored private let stallTimeout: Duration

    @ObservationIgnored private var isConnected = false
    /// The phone in session shares `photos.v1`; nothing `photos.*` goes out otherwise.
    @ObservationIgnored private var sharesPhotos = false
    /// Moves on with every refresh, clear, connect and disconnect: what an older one started is dropped.
    @ObservationIgnored private var generation: UInt64 = 0
    /// The refresh waiting for `photos.items`.
    @ObservationIgnored private var listWaiter: (requestID: UInt64, answer: Answer<AMPhotosList>)?
    /// The thumbnails request whose link has not come yet: its generation and the IDs asked for.
    @ObservationIgnored private var awaitingLink: (generation: UInt64, ids: Set<Int64>)?
    @ObservationIgnored private var linkTimeout: Task<Void, Never>?
    /// The thumbnail link being read.
    @ObservationIgnored private var link: (any BulkPipe)?
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "photos")

    /// `requestTimeout` bounds the wait for the list and for the thumbnail link; `fetchTimeout` the
    /// wait for a fetch's offer (it may queue behind another phone send); `stallTimeout` how long
    /// the thumbnail link may go without a byte.
    public init(engine: TransferEngine, bulk: any BulkGrants,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                downloads: URL, requestTimeout: Duration = .seconds(15), fetchTimeout: Duration = .seconds(30),
                stallTimeout: Duration = .seconds(30)) {
        self.engine = engine
        self.bulk = bulk
        self.send = send
        self.downloads = downloads
        self.requestTimeout = requestTimeout
        self.fetchTimeout = fetchTimeout
        self.stallTimeout = stallTimeout
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        isConnected = true
        sharesPhotos = shared.contains("photos.v1")
        phoneAvailability = nil
        clear()
    }

    public func disconnected() {
        isConnected = false
        sharesPhotos = false
        phoneAvailability = nil
        clear()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard sharesPhotos else { return }
        switch MessageType(rawValue: envelope.type) {
        case .photosItems:
            guard let list = try? AMPhotosList(serializedBytes: envelope.payload),
                  let waiter = listWaiter, waiter.requestID == list.requestID else { return }
            listWaiter = nil
            waiter.answer.resolve(list)
        case .photosAvailability:
            guard let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
            phoneAvailability = a
            // The phone stopped sharing its photos: what this Mac shows of them goes too.
            if !a.enabled { clear() }
        default:
            break
        }
    }

    public func forget(phoneID: String) async {}

    // MARK: API

    /// Lists the newest 200 items, then asks for all their thumbnails over one bulk stream. Ends
    /// whatever an earlier refresh still had under way. Does nothing unless the phone in session
    /// shares `photos.v1`; returns once the list is in (or did not come) and thumbnails are asked for.
    public func refresh() async {
        guard isConnected, sharesPhotos else { return }
        let gen = restart()
        loading = true
        let requestID = engine.nextRequestID()
        let answer = Answer<AMPhotosList>()
        listWaiter = (requestID, answer)
        let timeout = Task { [requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            answer.resolve(nil)
        }
        var request = AMPhotosListRequest()
        request.requestID = requestID
        request.limit = Self.pageSize
        request.beforeMs = 0
        await send(.photosList, request)
        let list = await answer.wait()
        timeout.cancel()
        // A newer refresh, a clear or a disconnect took over meanwhile.
        guard gen == generation else { return }
        listWaiter = nil
        loading = false
        guard let list else {
            Self.log.info("list \(requestID, privacy: .public) got no answer")
            return
        }
        items = Array(list.items.prefix(Int(Self.pageSize)))
        partialAccess = list.partialAccess
        let ids = items.map(\.id)
        let wanted = Set(ids)
        thumbnails = thumbnails.filter { wanted.contains($0.key) }
        Self.log.info("list \(requestID, privacy: .public): \(ids.count, privacy: .public) items")
        guard !ids.isEmpty else { return }

        var thumbs = AMPhotosThumbsRequest()
        thumbs.ids = ids
        thumbs.token = bulk.issue(role: .thumbnails, context: Self.thumbsContext)
        awaitingLink = (gen, wanted)
        linkTimeout = Task { [weak self, requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            guard !Task.isCancelled, let self, self.awaitingLink?.generation == gen else { return }
            Self.log.info("thumbnail link did not come")
            self.awaitingLink = nil
            self.bulk.revoke(context: Self.thumbsContext)
        }
        await send(.photosThumbs, thumbs)
    }

    /// A bulk connection whose `THUMBNAILS` token redeemed. Read until the end record, a newer
    /// refresh, `clear()`, a bad record, or `stallTimeout` without a byte; then closed. A link
    /// that answers no outstanding request is closed at once.
    public func thumbnailLink(_ pipe: any BulkPipe) async {
        guard let waiting = awaitingLink, waiting.generation == generation, link == nil else {
            pipe.close()
            return
        }
        awaitingLink = nil
        linkTimeout?.cancel()
        linkTimeout = nil
        link = pipe
        let gen = generation
        let meter = Meter()
        let stall = stallTimeout
        // The phone's socket has no read timeout, and neither has this one: a dead peer is cut here.
        let watchdog = Task.detached {
            let tick = max(min(stall / 5, .seconds(1)), .milliseconds(5))
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                if meter.idle >= stall {
                    pipe.close()
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            pipe.close()
            if link === pipe { link = nil }
        }
        var reader = ThumbnailRecordReader()
        var received = 0
        while gen == generation {
            let chunk: Data?
            do { chunk = try await pipe.receive(maximum: BulkLink.bufferBytes) } catch { break }
            guard let chunk, gen == generation else { break }
            meter.touch()
            let records: [(id: Int64, jpeg: Data)]
            do {
                records = try reader.append(chunk)
            } catch {
                Self.log.error("thumbnail stream: bad record")
                break
            }
            // One change per chunk, not per record.
            var updated = thumbnails
            var changed = false
            for r in records where !r.jpeg.isEmpty && waiting.ids.contains(r.id) {
                updated[r.id] = r.jpeg
                changed = true
                received += 1
            }
            if changed { thumbnails = updated }
            if reader.finished { break }
        }
        Self.log.info("thumbnails: \(received, privacy: .public) received, end \(reader.finished, privacy: .public)")
    }

    /// Fetches item `id` into Downloads, under the phone's (sanitized, made unique) name.
    public func save(_ id: Int64) async -> Result<URL, TransferFailure> {
        await fetch(id, into: .folder(downloads))
    }

    /// Fetches item `id` to exactly `file` (a file promise's file), replacing what is there.
    public func fetch(_ id: Int64, to file: URL) async -> Result<URL, TransferFailure> {
        await fetch(id, into: .file(file))
    }

    /// The name a dragged-out item is promised under, before the phone has said its real one:
    /// `IMG_` or `VID_`, the local date and time taken (`yyyyMMdd_HHmmss`, else the ID), and the
    /// extension of its type.
    public nonisolated static func promisedName(for item: AMPhotoItem, timeZone: TimeZone = .current) -> String {
        let stem: String
        if item.dateTakenMs > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            stem = formatter.string(from: Date(timeIntervalSince1970: Double(item.dateTakenMs) / 1000))
        } else {
            stem = String(item.id)
        }
        let ext = UTType(mimeType: item.mime)?.preferredFilenameExtension ?? (item.video ? "mp4" : "jpg")
        return FileNameSanitizer.sanitize((item.video ? "VID_" : "IMG_") + stem + "." + ext)
    }

    /// Drops the list and every thumbnail, and ends a refresh or thumbnail stream under way.
    /// Fetches go on: they are transfers, ended by the engine.
    public func clear() {
        _ = restart()
        items = []
        thumbnails = [:]
        partialAccess = false
        loading = false
    }

    // MARK: private

    /// A new generation: the list wait ends unanswered, the thumbnails token is revoked and its link closed.
    private func restart() -> UInt64 {
        generation &+= 1
        if let waiter = listWaiter {
            listWaiter = nil
            waiter.answer.resolve(nil)
        }
        linkTimeout?.cancel()
        linkTimeout = nil
        awaitingLink = nil
        bulk.revoke(context: Self.thumbsContext)
        link?.close()
        link = nil
        return generation
    }

    /// `photos.fetch`, answered by an offer carrying its request ID (the engine receives it into
    /// `destination`) or by `files.failed`. With no offer within `fetchTimeout`, it fails `TIMED_OUT`.
    private func fetch(_ id: Int64, into destination: IncomingDestination) async -> Result<URL, TransferFailure> {
        guard isConnected else { return .failure(.transfer(.interrupted)) }
        guard sharesPhotos else { return .failure(.transfer(.disabled)) }
        let requestID = engine.nextRequestID()
        let answer = Answer<Result<URL, TransferFailure>>()
        engine.expect(requestID: requestID, destination: destination) { answer.resolve($0) }
        let engine = engine
        let timeout = Task { [fetchTimeout] in
            try? await Task.sleep(for: fetchTimeout)
            guard !Task.isCancelled else { return }
            // A no-op once the offer came: the engine then forgets the request, and the transfer
            // has its own time limits.
            engine.failRequest(requestID, .transfer(.timedOut))
        }
        var fetch = AMPhotoFetch()
        fetch.requestID = requestID
        fetch.id = id
        await send(.photosFetch, fetch)
        let result = await answer.wait() ?? .failure(.transfer(.interrupted))
        timeout.cancel()
        if case let .failure(failure) = result {
            Self.log.info("fetch \(requestID, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
        }
        return result
    }
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

/// When bytes last moved; written by the reader, read by the watchdog.
private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() { lock.withLock { last = .now } }
    var idle: Duration { lock.withLock { ContinuousClock.now - last } }
}
