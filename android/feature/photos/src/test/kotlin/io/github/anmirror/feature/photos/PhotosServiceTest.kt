package io.github.anmirror.feature.photos

import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.PhotoFetch
import io.github.anmirror.protocol.v1.PhotosList
import io.github.anmirror.protocol.v1.PhotosListRequest
import io.github.anmirror.protocol.v1.PhotosThumbsRequest
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferFailed
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.BulkOpener
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.SinkResult
import io.github.anmirror.transfer.TransferEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private class FakeLibrary(
    val items: List<MediaItem> = emptyList(),
    val thumbs: Map<Long, ByteArray?> = emptyMap(),
    val files: Map<Long, OutgoingFile> = emptyMap(),
    val throwsFor: Set<Long> = emptySet(),
) : MediaLibrary {
    val recentCalls = CopyOnWriteArrayList<Pair<Int, Long>>()
    val thumbCalls = CopyOnWriteArrayList<Long>()

    override fun recent(limit: Int, beforeMs: Long): List<MediaItem> {
        recentCalls += limit to beforeMs
        return items.take(limit)
    }

    override fun thumbnail(id: Long): ByteArray? {
        thumbCalls += id
        if (id in throwsFor) throw IllegalStateException("encoder")
        return thumbs[id]
    }

    override fun file(id: Long): OutgoingFile? = files[id]
}

private class MemFile(override val name: String, private val data: ByteArray) : OutgoingFile {
    override val size = data.size.toLong()
    override val mime = "image/jpeg"
    override val modifiedMs = 1_700_000_000_000L
    override fun open(): InputStream = ByteArrayInputStream(data)
}

private class FakeStream(override val output: OutputStream = ByteArrayOutputStream()) : BulkStream {
    override val input: InputStream = ByteArrayInputStream(ByteArray(0))
    val closed = AtomicBoolean(false)
    override fun close() {
        closed.set(true)
        (output as? BlockingOutput)?.release()
    }
}

/** Blocks every write until released (the stream closed), then fails like a closed socket. */
private class BlockingOutput : OutputStream() {
    private val latch = CountDownLatch(1)
    override fun write(b: Int) { latch.await(); throw IOException("closed") }
    override fun write(b: ByteArray, off: Int, len: Int) { latch.await(); throw IOException("closed") }
    fun release() = latch.countDown()
}

private fun item(id: Long, video: Boolean = false) =
    MediaItem(id, 1_700_000_000_000L + id, if (video) "video/mp4" else "image/jpeg", 4032, 3024, if (video) 5_000 else 0, video)

/** Parses `id | length | JPEG` records up to and including the terminator. */
private fun records(bytes: ByteArray): List<Pair<Long, ByteArray>> {
    val input = DataInputStream(ByteArrayInputStream(bytes))
    val out = ArrayList<Pair<Long, ByteArray>>()
    while (true) {
        val id = input.readLong()
        val len = input.readInt()
        val jpeg = ByteArray(len).also { input.readFully(it) }
        out += id to jpeg
        if (id == 0L && len == 0) break
    }
    assertEquals(0, input.available(), "nothing after the terminator")
    return out
}

class PhotosServiceTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val sent = CopyOnWriteArrayList<Pair<String, MessageLite>>()
    private val hellos = CopyOnWriteArrayList<BulkHello>()
    private val streams = CopyOnWriteArrayList<FakeStream>()
    private val queued = CopyOnWriteArrayList<Pair<String, OutgoingFile>>()
    private var nextStream: () -> FakeStream = { FakeStream() }
    private val ids = AtomicInteger()

    private val engine = TransferEngine(
        scope = scope,
        send = { type, payload -> sent += type to payload; true },
        bulk = BulkOpener { throw IOException("no bulk in this test") },
        sinks = { SinkResult.Refused(TransferError.TRANSFER_ERROR_DISABLED) },
        freeBytes = { null },
        newId = { "t${ids.incrementAndGet()}" },
    )

    private fun service(library: MediaLibrary, partial: Boolean = false, stallMs: Long = 30_000) = PhotosService(
        library = library,
        send = { type, payload -> sent += type to payload; true },
        bulk = BulkOpener { hello -> hellos += hello; nextStream().also { streams += it } },
        transfers = engine,
        partial = { partial },
        onQueued = { id, file -> queued += id to file },
        io = Dispatchers.IO,
        stallMs = stallMs,
    )

    @After
    fun tearDown() = scope.cancel()

    private fun awaitUntil(what: String, ms: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + ms
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) throw AssertionError("timed out waiting for $what")
            Thread.sleep(2)
        }
    }

    @Test
    fun listClampsTo200AndReportsPartial() = runBlocking {
        val library = FakeLibrary(items = (1L..300L).map { item(it, video = it % 3 == 0L) })
        val photos = service(library, partial = true)

        photos.onList(PhotosListRequest.newBuilder().setRequestId(41).setLimit(500).build())

        assertEquals(listOf(200 to 0L), library.recentCalls)
        val (type, payload) = sent.single()
        assertEquals(MessageType.PHOTOS_ITEMS, type)
        val list = payload as PhotosList
        assertEquals(41, list.requestId)
        assertEquals(200, list.itemsCount)
        assertTrue(list.partialAccess)
        val third = list.itemsList[2]
        assertEquals(3, third.id)
        assertEquals(1_700_000_000_003L, third.dateTakenMs)
        assertEquals("video/mp4", third.mime)
        assertEquals(4032, third.width)
        assertEquals(3024, third.height)
        assertEquals(5_000, third.durationMs)
        assertTrue(third.video)

        // 0 (unset) asks for at least one; before_ms is passed on.
        sent.clear()
        photos.onList(PhotosListRequest.newBuilder().setRequestId(42).setLimit(0).setBeforeMs(99).build())
        assertEquals(1 to 99L, library.recentCalls.last())
        val one = sent.single().second as PhotosList
        assertEquals(1, one.itemsCount)
        assertEquals(42, one.requestId)

        service(library, partial = false).onList(PhotosListRequest.newBuilder().setRequestId(43).setLimit(10).build())
        assertEquals(false, (sent.last().second as PhotosList).partialAccess)
    }

    @Test
    fun thumbsStreamsRecordsInOrderThenEnd() = runBlocking {
        val a = byteArrayOf(1, 2, 3)
        val b = ByteArray(5000) { it.toByte() }
        val c = byteArrayOf(9)
        val library = FakeLibrary(thumbs = mapOf(30L to a, 10L to b, 20L to c))
        val photos = service(library)
        val token = ByteString.copyFrom(ByteArray(32) { 7 })

        photos.onThumbs(PhotosThumbsRequest.newBuilder().addAllIds(listOf(30L, 10L, 20L)).setToken(token).build())

        val hello = hellos.single()
        assertEquals(BulkRole.BULK_ROLE_THUMBNAILS, hello.role)
        assertEquals(token, hello.token)
        val stream = streams.single()
        assertTrue(stream.closed.get(), "the stream is closed once the records are out")
        val got = records((stream.output as ByteArrayOutputStream).toByteArray())
        assertEquals(listOf(30L, 10L, 20L, 0L), got.map { it.first })
        assertContentEquals(a, got[0].second)
        assertContentEquals(b, got[1].second)
        assertContentEquals(c, got[2].second)
        assertEquals(0, got[3].second.size)
        assertTrue(sent.isEmpty(), "thumbnails travel only over the bulk stream")
    }

    @Test
    fun thumbsTakeAtMost200Ids() = runBlocking {
        val library = FakeLibrary()
        service(library).onThumbs(PhotosThumbsRequest.newBuilder().addAllIds((1L..250L).toList()).build())
        assertEquals((1L..200L).toList(), library.thumbCalls.toList())
        val got = records((streams.single().output as ByteArrayOutputStream).toByteArray())
        assertEquals(201, got.size)
    }

    @Test
    fun missingThumbnailIsEmptyRecord() = runBlocking {
        val library = FakeLibrary(thumbs = mapOf(1L to byteArrayOf(4, 5), 2L to null, 3L to ByteArray(0)))
        service(library).onThumbs(PhotosThumbsRequest.newBuilder().addAllIds(listOf(1L, 2L, 3L, 4L)).build())
        val got = records((streams.single().output as ByteArrayOutputStream).toByteArray())
        assertEquals(listOf(1L, 2L, 3L, 4L, 0L), got.map { it.first })
        assertEquals(listOf(2, 0, 0, 0, 0), got.map { it.second.size })
    }

    @Test
    fun failedDialEndsQuietly() = runBlocking {
        val photos = PhotosService(
            library = FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1))),
            send = { type, payload -> sent += type to payload; true },
            bulk = BulkOpener { throw IOException("refused") },
            transfers = engine,
            partial = { false },
        )
        photos.onThumbs(PhotosThumbsRequest.newBuilder().addIds(1).build()) // does not throw
        assertTrue(sent.isEmpty())
    }

    @Test
    fun stalledThumbStreamIsClosed() = runBlocking {
        nextStream = { FakeStream(BlockingOutput()) }
        val photos = service(FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1))), stallMs = 200)
        val start = System.currentTimeMillis()
        withTimeout(5_000) {
            photos.onThumbs(PhotosThumbsRequest.newBuilder().addIds(1).build())
        }
        assertTrue(streams.single().closed.get())
        assertTrue(System.currentTimeMillis() - start >= 200)
    }

    @Test
    fun newerThumbsRequestClosesTheOlderStream() = runBlocking {
        nextStream = { if (streams.isEmpty()) FakeStream(BlockingOutput()) else FakeStream() }
        val photos = service(FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1))))
        val older = scope.launchThumbs(photos, 1)
        awaitUntil("first stream") { streams.size == 1 }
        photos.onThumbs(PhotosThumbsRequest.newBuilder().addIds(1).build())
        withTimeout(5_000) { older.join() }
        assertTrue(streams[0].closed.get())
        assertEquals(listOf(1L, 0L), records((streams[1].output as ByteArrayOutputStream).toByteArray()).map { it.first })
    }

    @Test
    fun stopClosesTheStreamInProgress() = runBlocking {
        nextStream = { FakeStream(BlockingOutput()) }
        val photos = service(FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1))))
        val job = scope.launchThumbs(photos, 1)
        awaitUntil("stream") { streams.size == 1 }
        photos.stop()
        withTimeout(5_000) { job.join() }
        assertTrue(streams.single().closed.get())
    }

    @Test
    fun throwingThumbnailIsEmptyRecord() = runBlocking {
        val library = FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1), 3L to byteArrayOf(3)), throwsFor = setOf(2L))
        service(library).onThumbs(PhotosThumbsRequest.newBuilder().addAllIds(listOf(1L, 2L, 3L)).build())
        val got = records((streams.single().output as ByteArrayOutputStream).toByteArray())
        assertEquals(listOf(1L, 2L, 3L, 0L), got.map { it.first })
        assertEquals(listOf(1, 0, 1, 0), got.map { it.second.size })
    }

    @Test
    fun olderDialArrivingLateNeverClosesTheNewerStream() = runBlocking {
        val firstDial = CountDownLatch(1)
        val dials = AtomicInteger()
        val photos = PhotosService(
            library = FakeLibrary(thumbs = mapOf(1L to byteArrayOf(1))),
            send = { type, payload -> sent += type to payload; true },
            bulk = BulkOpener { hello ->
                hellos += hello
                if (dials.incrementAndGet() == 1) {
                    // The older request's dial is slow: it comes back after the newer one is streaming.
                    kotlinx.coroutines.withContext(Dispatchers.IO) { firstDial.await() }
                    FakeStream().also { streams += it }
                } else {
                    FakeStream(BlockingOutput()).also { streams += it }
                }
            },
            transfers = engine,
            partial = { false },
        )
        val older = scope.launchThumbs(photos, 1)
        awaitUntil("first dial") { dials.get() == 1 }
        val newer = scope.launchThumbs(photos, 1)
        awaitUntil("newer stream") { streams.size == 1 }
        firstDial.countDown()
        withTimeout(5_000) { older.join() }
        val late = streams[1]
        val current = streams[0]
        assertTrue(late.closed.get(), "the late, older stream is closed unused")
        assertEquals(0, (late.output as ByteArrayOutputStream).size())
        assertTrue(!current.closed.get(), "the newer stream is left alone")
        photos.stop()
        withTimeout(5_000) { newer.join() }
        assertTrue(current.closed.get())
    }

    @Test
    fun fetchOffersWithRequestId() = runBlocking {
        val file = MemFile("IMG_0005.jpg", ByteArray(1234))
        val photos = service(FakeLibrary(files = mapOf(5L to file)))

        photos.onFetch(PhotoFetch.newBuilder().setRequestId(77).setId(5).build())

        awaitUntil("files.offer") { sent.any { it.first == MessageType.FILES_OFFER } }
        val offer = sent.first { it.first == MessageType.FILES_OFFER }.second as TransferOffer
        assertEquals(TransferKind.TRANSFER_KIND_PHOTO, offer.kind)
        assertEquals(77, offer.requestId)
        assertEquals("IMG_0005.jpg", offer.name)
        assertEquals(1234, offer.size)
        val (id, queuedFile) = queued.single()
        assertEquals(offer.transferId, id)
        assertTrue(queuedFile === file, "the opened file is handed back so its descriptor can be closed")
    }

    @Test
    fun fetchOfMissingIdFailsNotFound() = runBlocking {
        val photos = service(FakeLibrary())

        photos.onFetch(PhotoFetch.newBuilder().setRequestId(78).setId(404).build())

        val (type, payload) = sent.single()
        assertEquals(MessageType.FILES_FAILED, type)
        val failed = payload as TransferFailed
        assertEquals(78, failed.requestId)
        assertEquals(TransferError.TRANSFER_ERROR_NOT_FOUND, failed.reason)
        assertEquals("", failed.transferId)
        assertTrue(queued.isEmpty())
        assertTrue(engine.transfers.value.isEmpty())
    }
}

private fun CoroutineScope.launchThumbs(photos: PhotosService, vararg ids: Long) =
    launch { photos.onThumbs(PhotosThumbsRequest.newBuilder().addAllIds(ids.toList()).build()) }
