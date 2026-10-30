import AMProtocol
import AMTestSupport
import ConnectionCore
import FeatureFiles
import Foundation
import SwiftProtobuf
import Testing
@testable import FeaturePhotos

/// A model on a real transfer engine, with fakes around both and a temporary Downloads folder.
@MainActor
private final class Rig {
    let bulk = FakeBulk()
    let sent = SentLog()
    let downloads: URL
    let engine: TransferEngine
    let model: PhotosModel

    init(requestTimeout: Duration = .seconds(5), fetchTimeout: Duration = .seconds(5),
         stallTimeout: Duration = .seconds(5)) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-photos-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        downloads = dir
        let sent = sent
        engine = TransferEngine(
            bulk: bulk,
            send: { type, message in sent.all.append((type, message)) },
            destination: { _ in .refuse(.disabled) },
            freeBytes: { _ in nil },
            timing: TransferTiming(acceptTimeout: .seconds(5), stallTimeout: .seconds(5),
                                   progressInterval: .zero, freeMargin: 0)
        )
        model = PhotosModel(
            engine: engine, bulk: bulk,
            send: { type, message in sent.all.append((type, message)) },
            downloads: dir, requestTimeout: requestTimeout, fetchTimeout: fetchTimeout, stallTimeout: stallTimeout
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: downloads) }

    func connect(shared: Set<String> = ["photos.v1"]) async {
        await engine.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
        await model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
    }

    func disconnect() {
        engine.disconnected()
        model.disconnected()
    }

    var lastListRequest: AMPhotosListRequest? { sent.of(.photosList, AMPhotosListRequest.self).last }

    /// Answers the newest `photos.list` with `ids` (videos where `video` says).
    func answerList(_ ids: [Int64], partial: Bool = false, video: Set<Int64> = []) async {
        var list = AMPhotosList()
        list.requestID = lastListRequest?.requestID ?? 0
        list.partialAccess = partial
        list.items = ids.map { id in
            var item = AMPhotoItem()
            item.id = id
            item.dateTakenMs = 1_700_000_000_000 + id
            item.mime = video.contains(id) ? "video/mp4" : "image/jpeg"
            item.video = video.contains(id)
            item.durationMs = video.contains(id) ? 5_000 : 0
            return item
        }
        await model.message(envelope(.photos, .photosItems, list))
    }

    /// Refreshes, answers the list with `ids`, and waits until the thumbnails are asked for.
    func refreshed(_ ids: [Int64], partial: Bool = false) async throws {
        let before = sent.of(.photosList, AMPhotosListRequest.self).count
        let task = Task { await model.refresh() }
        try await until("photos.list") { self.sent.of(.photosList, AMPhotosListRequest.self).count == before + 1 }
        await answerList(ids, partial: partial)
        await task.value
    }

    /// Links a thumbnail pipe the way the bulk server would; returns the phone's end.
    func linkThumbnails() -> (task: Task<Void, Never>, mac: MemoryPipe, phone: MemoryPipe) {
        let (mac, phone) = MemoryPipe.pair()
        let model = model
        let task = Task { await model.thumbnailLink(mac) }
        return (task, mac, phone)
    }
}

// MARK: refresh

@MainActor @Test func refreshRequestsListThenThumbs() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let task = Task { await r.model.refresh() }
    try await until("photos.list") { r.lastListRequest != nil }
    let request = try #require(r.lastListRequest)
    #expect(request.limit == 200)
    #expect(request.beforeMs == 0)
    #expect(request.requestID != 0)
    #expect(r.model.loading)
    #expect(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).isEmpty, "thumbnails wait for the list")

    // An answer to another request is not this one.
    var stray = AMPhotosList()
    stray.requestID = request.requestID + 100
    stray.items = [AMPhotoItem()]
    await r.model.message(envelope(.photos, .photosItems, stray))
    #expect(r.model.items.isEmpty)

    await r.answerList([30, 10, 20], partial: true)
    await task.value
    #expect(r.model.items.map(\.id) == [30, 10, 20])
    #expect(r.model.partialAccess)
    #expect(!r.model.loading)

    let thumbs = try #require(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).last)
    #expect(thumbs.ids == [30, 10, 20])
    let grant = try #require(r.bulk.issued.last)
    #expect(grant.role == .thumbnails)
    #expect(grant.context == "thumbs")
    #expect(thumbs.token == grant.token)
    #expect(r.sent.types.filter { $0.rawValue.hasPrefix("photos.") } == [.photosList, .photosThumbs])
}

@MainActor @Test func newerRefreshRevokesTheOlderThumbs() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let first = r.linkThumbnails()
    try await r.refreshed([1, 2, 3])
    #expect(r.bulk.revoked.contains("thumbs"))
    await first.task.value
    #expect(first.mac.isClosed, "the older link is closed")
    #expect(r.bulk.issued.count == 2)
    // The newer request's link is taken.
    let second = r.linkThumbnails()
    try await second.phone.send(record(3, Data([3])) + endRecord)
    await second.task.value
    #expect(r.model.thumbnails[3] == Data([3]))
}

@MainActor @Test func listWithNoAnswerStopsLoading() async throws {
    let r = Rig(requestTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    await r.model.refresh()
    #expect(!r.model.loading)
    #expect(r.model.items.isEmpty)
    #expect(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).isEmpty)
}

@MainActor @Test func nothingIsSentWithoutPhotosV1() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect(shared: ["files.v1"])
    await r.model.refresh()
    #expect(await r.model.save(1) == .failure(.transfer(.disabled)))
    #expect(r.sent.types.filter { $0.rawValue.hasPrefix("photos.") }.isEmpty)
}

// MARK: thumbnails

@MainActor @Test func thumbnailsFillFromLink() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([30, 10, 20])
    let link = r.linkThumbnails()
    let a = Data([1, 2, 3]), b = Data(repeating: 9, count: 3000)
    // Split mid-record; an ID that was not asked for and an empty record are left out.
    let bytes = record(30, a) + record(99, Data([5])) + record(10, b) + record(20, Data()) + endRecord
    try await link.phone.send(bytes.prefix(20))
    try await until("first thumbnail") { r.model.thumbnails[30] != nil }
    try await link.phone.send(bytes.dropFirst(20))
    await link.task.value
    #expect(r.model.thumbnails == [30: a, 10: b])
    #expect(link.mac.isClosed, "the link is closed after the end record")
}

@MainActor @Test func unexpectedLinkIsClosed() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let link = r.linkThumbnails()
    await link.task.value
    #expect(link.mac.isClosed)
    // One link per request: a second one for the same request is closed too.
    try await r.refreshed([1])
    let first = r.linkThumbnails()
    let second = r.linkThumbnails()
    await second.task.value
    #expect(second.mac.isClosed)
    try await first.phone.send(record(1, Data([1])) + endRecord)
    await first.task.value
    #expect(r.model.thumbnails[1] == Data([1]))
}

@MainActor @Test func stalledLinkIsClosed() async throws {
    let r = Rig(stallTimeout: .milliseconds(200)); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let link = r.linkThumbnails()
    try await link.phone.send(record(1, Data([1])))
    let start = ContinuousClock.now
    await link.task.value
    #expect(ContinuousClock.now - start >= .milliseconds(150))
    #expect(link.mac.isClosed)
    #expect(r.model.thumbnails == [1: Data([1])])
}

@MainActor @Test func oversizedRecordClosesTheLink() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1])
    let link = r.linkThumbnails()
    var header = Data()
    withUnsafeBytes(of: UInt64(1).bigEndian) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(0xFFFF_FFFF).bigEndian) { header.append(contentsOf: $0) }
    try await link.phone.send(header)
    await link.task.value
    #expect(link.mac.isClosed)
    #expect(r.model.thumbnails.isEmpty)
}

// MARK: fetch

/// Plays the phone answering a fetch: offers `bytes` with the request's ID, streams them, completes.
@MainActor
private func phoneAnswers(_ r: Rig, with bytes: Data, name: String = "IMG_0005.jpg") async throws {
    try await until("photos.fetch") { !r.sent.of(.photosFetch, AMPhotoFetch.self).isEmpty }
    let fetch = try #require(r.sent.of(.photosFetch, AMPhotoFetch.self).last)
    var offer = AMTransferOffer()
    offer.transferID = "p1"
    offer.name = name
    offer.size = UInt64(bytes.count)
    offer.mime = "image/jpeg"
    offer.kind = .photo
    offer.requestID = fetch.requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("files.accept") { !r.sent.of(.filesAccept, AMTransferAccept.self).isEmpty }
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneSends, context: "p1"))
    try await phone.send(bytes)
    var complete = AMTransferComplete()
    complete.transferID = "p1"
    complete.sha256 = sha(bytes)
    await r.engine.message(envelope(.files, .filesComplete, complete))
}

@MainActor @Test func saveExpectsRequestIntoDownloads() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let bytes = Data((0..<4000).map { UInt8($0 % 256) })
    let task = Task { await r.model.save(5) }
    try await phoneAnswers(r, with: bytes)
    let fetch = try #require(r.sent.of(.photosFetch, AMPhotoFetch.self).last)
    #expect(fetch.id == 5)
    #expect(fetch.requestID != 0)

    let result = await task.value
    let saved = r.downloads.appendingPathComponent("IMG_0005.jpg")
    #expect(result == .success(saved))
    #expect(try Data(contentsOf: saved) == bytes)
    // A user-started receive: listed, like any file from the phone (R13 hides only screenshots).
    #expect(r.engine.transfers.first?.kind == .photo)
    #expect(TransferMenu.lines([TransferItem(id: "x", direction: .receive, name: "a", size: 1, kind: .photo,
                                             state: .active)]).count == 1)
}

@MainActor @Test func fetchWritesThePromisedFile() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let target = r.downloads.appendingPathComponent("promised/IMG_20231114.jpg")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data(repeating: 3, count: 100)
    let task = Task { await r.model.fetch(5, to: target) }
    try await phoneAnswers(r, with: bytes)
    #expect(await task.value == .success(target))
    #expect(try Data(contentsOf: target) == bytes)
}

@MainActor @Test func fetchFailureIsReported() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let target = r.downloads.appendingPathComponent("gone.jpg")
    let task = Task { await r.model.fetch(404, to: target) }
    try await until("photos.fetch") { !r.sent.of(.photosFetch, AMPhotoFetch.self).isEmpty }
    let fetch = try #require(r.sent.of(.photosFetch, AMPhotoFetch.self).last)
    var failed = AMTransferFailed()
    failed.requestID = fetch.requestID
    failed.reason = .notFound
    await r.engine.message(envelope(.files, .filesFailed, failed))
    #expect(await task.value == .failure(.transfer(.notFound)))
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

@MainActor @Test func fetchWithNoAnswerTimesOut() async throws {
    let r = Rig(fetchTimeout: .milliseconds(100)); defer { r.cleanUp() }
    await r.connect()
    #expect(await r.model.save(5) == .failure(.transfer(.timedOut)))
}

@MainActor @Test func disconnectFailsAFetchUnderWay() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let task = Task { await r.model.save(5) }
    try await until("photos.fetch") { !r.sent.of(.photosFetch, AMPhotoFetch.self).isEmpty }
    r.disconnect()
    #expect(await task.value == .failure(.transfer(.interrupted)))
}

// MARK: clearing

@MainActor @Test func clearDropsThumbnails() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let link = r.linkThumbnails()
    try await link.phone.send(record(1, Data([1])))
    try await until("thumbnail") { r.model.thumbnails[1] != nil }

    r.model.clear()
    #expect(r.model.thumbnails.isEmpty)
    #expect(r.model.items.isEmpty)
    #expect(r.bulk.revoked.contains("thumbs"))
    await link.task.value
    #expect(link.mac.isClosed)
    // Bytes that were still on the way are not kept.
    #expect(r.model.thumbnails.isEmpty)
}

@MainActor @Test func disconnectClears() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    var availability = AMFeatureAvailability()
    availability.enabled = true
    availability.reason = .partialAccess
    await r.model.message(envelope(.photos, .photosAvailability, availability))
    #expect(r.model.phoneAvailability == availability)
    try await r.refreshed([1, 2], partial: true)
    let link = r.linkThumbnails()
    try await link.phone.send(record(1, Data([1])) + record(2, Data([2])) + endRecord)
    await link.task.value
    #expect(r.model.thumbnails.count == 2)

    r.disconnect()
    #expect(r.model.thumbnails.isEmpty)
    #expect(r.model.items.isEmpty)
    #expect(!r.model.partialAccess)
    #expect(r.model.phoneAvailability == nil)
    #expect(!r.model.loading)
}

@MainActor @Test func disconnectEndsARefreshUnderWay() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let task = Task { await r.model.refresh() }
    try await until("photos.list") { r.lastListRequest != nil }
    r.disconnect()
    await task.value
    #expect(!r.model.loading)
    #expect(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).isEmpty)
}

// MARK: names

@Test func promisedNameUsesDateAndType() {
    var photo = AMPhotoItem()
    photo.id = 5
    photo.dateTakenMs = 1_700_000_000_000 // 2023-11-14 22:13:20 UTC
    photo.mime = "image/heic"
    #expect(PhotosModel.promisedName(for: photo, timeZone: .gmt) == "IMG_20231114_221320.heic")

    var video = photo
    video.video = true
    video.mime = "video/mp4"
    #expect(PhotosModel.promisedName(for: video, timeZone: .gmt) == "VID_20231114_221320.mp4")

    var jpeg = photo
    jpeg.mime = "image/jpeg"
    #expect(PhotosModel.promisedName(for: jpeg, timeZone: .gmt) == "IMG_20231114_221320.jpg")

    // No date, or a type macOS does not know: the ID, and an extension by kind.
    var bare = AMPhotoItem()
    bare.id = 42
    bare.mime = "image/x-unknown-thing"
    #expect(PhotosModel.promisedName(for: bare, timeZone: .gmt) == "IMG_42.jpg")
    bare.video = true
    bare.mime = ""
    #expect(PhotosModel.promisedName(for: bare, timeZone: .gmt) == "VID_42.mp4")
}

@MainActor @Test func phoneTurningPhotosOffClears() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let link = r.linkThumbnails()
    try await link.phone.send(record(1, Data([1])) + endRecord)
    await link.task.value
    #expect(r.model.items.count == 2)

    // Partial access still shows what was picked.
    var partial = AMFeatureAvailability()
    partial.enabled = true
    partial.reason = .partialAccess
    await r.model.message(envelope(.photos, .photosAvailability, partial))
    #expect(r.model.items.count == 2)

    var off = AMFeatureAvailability()
    off.enabled = false
    off.reason = .offByUser
    await r.model.message(envelope(.photos, .photosAvailability, off))
    #expect(r.model.phoneAvailability == off)
    #expect(r.model.items.isEmpty)
    #expect(r.model.thumbnails.isEmpty)
}

@Test func contentTypeFallsBackByKind() {
    var item = AMPhotoItem()
    item.mime = "image/heic"
    #expect(PhotosModel.contentType(for: item) == .heic)
    item.mime = "image/x-unknown-thing"
    #expect(PhotosModel.contentType(for: item) == .image)
    item.video = true
    item.mime = "video/x-unknown-thing"
    #expect(PhotosModel.contentType(for: item) == .movie)
    item.mime = ""
    #expect(PhotosModel.contentType(for: item) == .movie)
    item.mime = "video/mp4"
    #expect(PhotosModel.contentType(for: item) == .mpeg4Movie)
}

// MARK: fix round 1

@MainActor @Test func refreshBeforeConnectedRunsOnConnect() async throws {
    let r = Rig(); defer { r.cleanUp() }
    // The window asks before the session reaches the model (NotifyWork delivers it later).
    await r.model.refresh()
    #expect(r.lastListRequest == nil)
    #expect(!r.model.available)
    await r.connect()
    #expect(r.model.available)
    try await until("photos.list") { r.lastListRequest != nil }
    await r.answerList([1])
    try await until("photos.thumbs") { !r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).isEmpty }

    // Without photos.v1 nothing is asked, and a pending ask does not outlive a window close.
    let r2 = Rig(); defer { r2.cleanUp() }
    await r2.model.refresh()
    await r2.connect(shared: ["files.v1"])
    #expect(!r2.model.available)
    let r3 = Rig(); defer { r3.cleanUp() }
    await r3.model.refresh()
    r3.model.clear()
    await r3.connect()
    try await Task.sleep(for: .milliseconds(50))
    #expect(r2.lastListRequest == nil)
    #expect(r3.lastListRequest == nil)
}

@MainActor @Test func refreshAsksOnlyForMissingThumbnails() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let link = r.linkThumbnails()
    try await link.phone.send(record(1, Data([1])) + record(2, Data()) + endRecord)
    await link.task.value

    try await r.refreshed([3, 1, 2])
    #expect(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).last?.ids == [3, 2])
    #expect(r.model.thumbnails[1] == Data([1]), "a thumbnail held is kept")

    // Every one held: no request at all.
    let count = r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).count
    try await r.refreshed([1])
    #expect(r.sent.of(.photosThumbs, AMPhotosThumbsRequest.self).count == count)
}

@MainActor @Test func oversizedThumbnailIsNotKept() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    try await r.refreshed([1, 2])
    let link = r.linkThumbnails()
    let atLimit = Data(repeating: 1, count: 64 * 1024), over = Data(repeating: 2, count: 64 * 1024 + 1)
    try await link.phone.send(record(1, atLimit) + record(2, over) + endRecord)
    await link.task.value
    #expect(r.model.thumbnails == [1: atLimit])
}

@MainActor @Test func cancelledFetchCancelsItsRequest() async throws {
    let r = Rig(); defer { r.cleanUp() }
    await r.connect()
    let target = r.downloads.appendingPathComponent("drag.jpg")
    let task = Task { await r.model.fetch(5, to: target) }
    try await until("photos.fetch") { !r.sent.of(.photosFetch, AMPhotoFetch.self).isEmpty }
    task.cancel()
    #expect(await task.value == .failure(.transfer(.cancelled)))
    // The phone's late answer is denied.
    let fetch = try #require(r.sent.of(.photosFetch, AMPhotoFetch.self).last)
    var offer = AMTransferOffer()
    offer.transferID = "late"; offer.size = 1; offer.kind = .photo; offer.requestID = fetch.requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("reject") { r.sent.of(.filesReject, AMTransferReject.self).map(\.reason) == [.denied] }
}

@MainActor @Test func fetchQueuedBehindAReceiveDoesNotTimeOut() async throws {
    let r = Rig(fetchTimeout: .milliseconds(150)); defer { r.cleanUp() }
    await r.connect()
    // A first save whose bytes are still coming.
    let first = Task { await r.model.save(1) }
    try await until("photos.fetch 1") { r.sent.of(.photosFetch, AMPhotoFetch.self).count == 1 }
    let one = try #require(r.sent.of(.photosFetch, AMPhotoFetch.self).last)
    var offer = AMTransferOffer()
    offer.transferID = "p1"; offer.name = "a.jpg"; offer.size = 100; offer.kind = .photo; offer.requestID = one.requestID
    await r.engine.message(envelope(.files, .filesOffer, offer))
    try await until("files.accept") { !r.sent.of(.filesAccept, AMTransferAccept.self).isEmpty }
    let (mac, phone) = MemoryPipe.pair()
    r.engine.link(mac, grant: BulkGrant(role: .phoneSends, context: "p1"))

    // The second waits behind it on the phone: no timeout while the first is live.
    var second: Result<URL, TransferFailure>?
    let secondTask = Task { second = await r.model.save(2) }
    try await Task.sleep(for: .milliseconds(400))
    #expect(second == nil)

    let bytes = Data(repeating: 7, count: 100)
    try await phone.send(bytes)
    var complete = AMTransferComplete(); complete.transferID = "p1"; complete.sha256 = sha(bytes)
    await r.engine.message(envelope(.files, .filesComplete, complete))
    #expect(await first.value == .success(r.downloads.appendingPathComponent("a.jpg")))
    await secondTask.value
    #expect(second == .failure(.transfer(.timedOut)), "once idle, its deadline runs")
}
