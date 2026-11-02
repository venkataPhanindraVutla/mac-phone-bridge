package io.github.anmirror.transfer

import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BrowseTarget
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.TransferAccept
import io.github.anmirror.protocol.v1.TransferCancel
import io.github.anmirror.protocol.v1.TransferComplete
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferFailed
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.protocol.v1.TransferReceived
import io.github.anmirror.protocol.v1.TransferReject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b)

private class FakeStream(
    override val input: InputStream = ByteArrayInputStream(ByteArray(0)),
    override val output: OutputStream = ByteArrayOutputStream(),
) : BulkStream {
    val closed = AtomicBoolean(false)
    override fun close() {
        closed.set(true)
        (input as? Closeable2)?.release()
        (output as? Closeable2)?.release()
    }
}

/** Blocks until the owning stream is closed, then fails like a closed socket. */
private interface Closeable2 { fun release() }

private class BlockingInput : InputStream(), Closeable2 {
    private val latch = CountDownLatch(1)
    override fun read(): Int { latch.await(); throw IOException("closed") }
    override fun read(b: ByteArray, off: Int, len: Int): Int { latch.await(); throw IOException("closed") }
    override fun release() = latch.countDown()
}

private class BlockingOutput : OutputStream(), Closeable2 {
    private val latch = CountDownLatch(1)
    override fun write(b: Int) { latch.await(); throw IOException("closed") }
    override fun write(b: ByteArray, off: Int, len: Int) { latch.await(); throw IOException("closed") }
    override fun release() = latch.countDown()
}

/** Serves [first] bytes, then blocks until [gate] opens, then serves [second]. */
private class GatedInput(first: ByteArray, second: ByteArray, val gate: CountDownLatch) : InputStream() {
    private val a = ByteArrayInputStream(first)
    private val b = ByteArrayInputStream(second)
    override fun read(): Int = throw UnsupportedOperationException()
    override fun read(buf: ByteArray, off: Int, len: Int): Int {
        val n = a.read(buf, off, len)
        if (n >= 0) return n
        gate.await()
        return b.read(buf, off, len)
    }
}

/** [chunks] reads of [chunk] bytes, advancing [clock] by [step] before each. */
private class ClockedInput(val chunks: Int, val chunk: Int, val clock: AtomicLong, val step: Long) : InputStream() {
    private var n = 0
    override fun read(): Int = throw UnsupportedOperationException()
    override fun read(buf: ByteArray, off: Int, len: Int): Int {
        if (n >= chunks) return -1
        n++
        clock.addAndGet(step)
        return minOf(len, chunk)
    }
}

/** Endless zeros, [total] bytes. */
private class ZeroInput(var left: Long, val clock: AtomicLong? = null, val step: Long = 0) : InputStream() {
    override fun read(): Int = if (left-- > 0) 0 else -1
    override fun read(buf: ByteArray, off: Int, len: Int): Int {
        if (left <= 0) return -1
        clock?.addAndGet(step)
        val n = minOf(len.toLong(), left).toInt()
        java.util.Arrays.fill(buf, off, off + n, 0)
        left -= n
        return n
    }
}

private class CountingOutput : OutputStream() {
    val count = AtomicLong()
    override fun write(b: Int) { count.incrementAndGet() }
    override fun write(b: ByteArray, off: Int, len: Int) { count.addAndGet(len.toLong()) }
}

private class MemSource(
    override val name: String,
    private val data: ByteArray,
    override val mime: String = "application/octet-stream",
    override val size: Long = data.size.toLong(),
) : OutgoingFile {
    override val modifiedMs = 1_700_000_000_000L
    override fun open(): InputStream = ByteArrayInputStream(data)
}

private class StreamSource(override val name: String, override val size: Long, val make: () -> InputStream) : OutgoingFile {
    override val mime = "application/octet-stream"
    override val modifiedMs = 0L
    override fun open(): InputStream = make()
}

private class MemSink(
    val savedName: String = "saved.bin",
    val out: OutputStream = ByteArrayOutputStream(),
    val commitFails: Boolean = false,
) : IncomingFile {
    val committed = AtomicBoolean(false)
    val aborted = AtomicBoolean(false)
    override val output: OutputStream get() = out
    override fun commit(): String { if (commitFails) throw IOException("disk"); committed.set(true); return savedName }
    override fun abort() { aborted.set(true) }
}

private class Harness(
    val timing: TransferTiming = TransferTiming(),
    val free: (TransferOffer) -> Long? = { null },
    val clock: AtomicLong = AtomicLong(1_000),
    val sinkFor: (TransferOffer) -> SinkResult = { SinkResult.Ready(MemSink()) },
    val onSend: (String, MessageLite) -> Unit = { _, _ -> },
    val makeStream: (BulkHello) -> BulkStream = { FakeStream() },
    val dial: suspend (BulkHello) -> Unit = {},
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val sent = CopyOnWriteArrayList<Pair<String, MessageLite>>()
    val hellos = CopyOnWriteArrayList<BulkHello>()
    val streams = CopyOnWriteArrayList<FakeStream>()
    val openNow = AtomicInteger()
    val maxOpen = AtomicInteger()
    val offersSeen = CopyOnWriteArrayList<TransferOffer>()
    private val ids = AtomicInteger()

    val engine = TransferEngine(
        scope = scope,
        send = { type, payload -> sent += type to payload; onSend(type, payload); true },
        bulk = { hello ->
            hellos += hello
            dial(hello)
            val s = makeStream(hello) as FakeStream
            streams += s
            val now = openNow.incrementAndGet()
            maxOpen.updateAndGet { maxOf(it, now) }
            object : BulkStream by s {
                override fun close() { if (!s.closed.get()) openNow.decrementAndGet(); s.close() }
            }
        },
        sinks = { offer -> offersSeen += offer; sinkFor(offer) },
        freeBytes = free,
        clock = { clock.get() },
        newId = { "t${ids.incrementAndGet()}" },
        io = Dispatchers.IO,
        timing = timing,
    )

    fun env(type: String, msg: MessageLite) = envelope(Channel.CHANNEL_FILES, 1, type, msg)
    fun deliver(type: String, msg: MessageLite) = runBlocking { engine.onMessage(env(type, msg)) }
    fun status(id: String) = engine.transfers.value.first { it.id == id }
    fun awaitState(id: String, state: TransferState, ms: Long = 10_000) =
        awaitUntil(ms, "state $state of $id (now ${engine.transfers.value.firstOrNull { it.id == id }?.state})") {
            engine.transfers.value.firstOrNull { it.id == id }?.state == state
        }
    fun types() = sent.map { it.first }
    fun awaitSent(type: String, ms: Long = 10_000) = awaitUntil(ms, "sent $type") { type in types() }
    inline fun <reified T : MessageLite> last(type: String): T = sent.last { it.first == type }.second as T

    fun offer(id: String, size: Long, name: String = "a.bin", token: ByteArray = byteArrayOf(7, 7)) =
        TransferOffer.newBuilder().setTransferId(id).setName(name).setSize(size).setMime("x/y")
            .setKind(TransferKind.TRANSFER_KIND_FILE).setToken(ByteString.copyFrom(token)).build()

    fun complete(id: String, sha: ByteArray) =
        TransferComplete.newBuilder().setTransferId(id).setSha256(ByteString.copyFrom(sha)).build()

    fun close() { scope.cancel() }
}

private fun awaitUntil(ms: Long, what: String, cond: () -> Boolean) {
    val end = System.currentTimeMillis() + ms
    while (!cond()) {
        if (System.currentTimeMillis() > end) throw AssertionError("timed out waiting for $what")
        Thread.sleep(5)
    }
}

class TransferEngineTest {
    private val harnesses = mutableListOf<Harness>()
    private fun harness(h: Harness) = h.also { harnesses += it }

    @After
    fun tearDown() { harnesses.forEach { it.close() } }

    @Test
    fun sendRunsOfferAcceptBytesComplete() {
        val out = ByteArrayOutputStream()
        val h = harness(Harness(makeStream = { FakeStream(output = out) }))
        val data = Random(1).nextBytes(1_000_000)
        val id = h.engine.send(listOf(MemSource("photo.jpg", data, "image/jpeg"))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        val offer = h.last<TransferOffer>(MessageType.FILES_OFFER)
        assertEquals(id, offer.transferId)
        assertEquals("photo.jpg", offer.name)
        assertEquals(1_000_000L, offer.size)
        assertEquals("image/jpeg", offer.mime)
        assertEquals(1_700_000_000_000L, offer.modifiedMs)
        assertTrue(offer.token.isEmpty)
        h.awaitState(id, TransferState.WAITING)

        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).setToken(ByteString.copyFrom(byteArrayOf(1, 2, 3))).build())
        h.awaitSent(MessageType.FILES_COMPLETE)
        assertContentEquals(byteArrayOf(1, 2, 3), h.hellos.single().token.toByteArray())
        assertEquals(BulkRole.BULK_ROLE_PHONE_SENDS, h.hellos.single().role)
        assertContentEquals(data, out.toByteArray())
        assertContentEquals(sha(data), h.last<TransferComplete>(MessageType.FILES_COMPLETE).sha256.toByteArray())
        assertEquals(TransferState.ACTIVE, h.status(id).state)

        h.deliver(MessageType.FILES_RECEIVED, TransferReceived.newBuilder().setTransferId(id).build())
        h.awaitState(id, TransferState.DONE)
        assertEquals(1_000_000L, h.status(id).done)
        awaitUntil(5_000, "stream closed") { h.streams.single().closed.get() }
    }

    @Test
    fun receiveAcceptsWritesAndCommitsOnHashMatch() {
        val data = Random(2).nextBytes(700_000)
        val sink = MemSink("saved (1).jpg")
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = ByteArrayInputStream(data)) }))
        assertTrue(h.deliver(MessageType.FILES_OFFER, h.offer("m1", data.size.toLong(), "../../evil/photo.jpg", byteArrayOf(9, 9))))
        h.awaitSent(MessageType.FILES_ACCEPT)
        assertEquals("m1", h.last<TransferAccept>(MessageType.FILES_ACCEPT).transferId)
        assertEquals("photo.jpg", h.offersSeen.single().name) // sanitized before it reaches the sink
        assertContentEquals(byteArrayOf(9, 9), h.hellos.single().token.toByteArray())
        assertEquals(BulkRole.BULK_ROLE_PHONE_RECEIVES, h.hellos.single().role)
        // Bytes are in; the engine waits for files.complete.
        awaitUntil(5_000, "bytes written") { (sink.output as ByteArrayOutputStream).size() == data.size }
        assertFalse(sink.committed.get())
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", sha(data)))
        h.awaitState("m1", TransferState.DONE)
        assertTrue(sink.committed.get())
        assertFalse(sink.aborted.get())
        assertEquals("saved (1).jpg", h.status("m1").savedAs)
        assertEquals(Direction.RECEIVE, h.status("m1").direction)
        assertEquals("photo.jpg", h.status("m1").name)
        h.awaitSent(MessageType.FILES_RECEIVED)
        assertContentEquals(data, (sink.output as ByteArrayOutputStream).toByteArray())
    }

    @Test
    fun hashMismatchAbortsAndFails() {
        val data = Random(3).nextBytes(5_000)
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = ByteArrayInputStream(data)) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", data.size.toLong()))
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", ByteArray(32)))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_HASH_MISMATCH, h.status("m1").error)
        assertTrue(sink.aborted.get())
        assertFalse(sink.committed.get())
        assertEquals(TransferError.TRANSFER_ERROR_HASH_MISMATCH, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertFalse(MessageType.FILES_RECEIVED in h.types())
    }

    @Test
    fun completeBeforeLastByteStillCommits() {
        val data = Random(4).nextBytes(100_000)
        val gate = CountDownLatch(1)
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = {
            FakeStream(input = GatedInput(data.copyOfRange(0, 60_000), data.copyOfRange(60_000, data.size), gate))
        }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", data.size.toLong()))
        h.awaitSent(MessageType.FILES_ACCEPT)
        awaitUntil(5_000, "first half") { (sink.output as ByteArrayOutputStream).size() == 60_000 }
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", sha(data)))
        Thread.sleep(50)
        assertFalse(sink.committed.get())
        assertEquals(TransferState.ACTIVE, h.status("m1").state)
        gate.countDown()
        h.awaitState("m1", TransferState.DONE)
        assertTrue(sink.committed.get())
    }

    @Test
    fun progressIsThrottledTo500ms() {
        val clock = AtomicLong(1_000)
        val sink = MemSink()
        val h = harness(Harness(clock = clock, sinkFor = { SinkResult.Ready(sink) }, makeStream = {
            FakeStream(input = ClockedInput(chunks = 10, chunk = 1000, clock = clock, step = 100))
        }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 10_000))
        awaitUntil(5_000, "two progress messages") { h.types().count { it == MessageType.FILES_PROGRESS } >= 2 }
        Thread.sleep(100)
        val progress = h.sent.filter { it.first == MessageType.FILES_PROGRESS }
            .map { (it.second as io.github.anmirror.protocol.v1.TransferProgress).bytesDone }
        assertEquals(listOf(5_000L, 10_000L), progress)
        assertEquals(10_000L, h.status("m1").done)
    }

    @Test
    fun cancelBySenderAbortsReceiver() {
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = BlockingInput()) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000_000))
        awaitUntil(5_000, "stream open") { h.streams.size == 1 }
        val before = h.sent.size
        h.deliver(MessageType.FILES_CANCEL, TransferCancel.newBuilder().setTransferId("m1").build())
        h.awaitState("m1", TransferState.CANCELLED)
        awaitUntil(5_000, "aborted") { sink.aborted.get() }
        assertTrue(h.streams.single().closed.get())
        assertFalse(sink.committed.get())
        assertEquals(before, h.sent.size) // a peer cancel is never answered
    }

    @Test
    fun localCancelSendsCancelAndAborts() {
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = BlockingInput()) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000_000))
        awaitUntil(5_000, "stream open") { h.streams.size == 1 }
        h.engine.cancel("m1")
        h.awaitState("m1", TransferState.CANCELLED)
        h.awaitSent(MessageType.FILES_CANCEL)
        assertEquals("m1", h.last<TransferCancel>(MessageType.FILES_CANCEL).transferId)
        awaitUntil(5_000, "aborted") { sink.aborted.get() }
        assertTrue(h.streams.single().closed.get())
    }

    @Test
    fun cancelFromPeerStopsSending() {
        val h = harness(Harness(makeStream = { FakeStream(output = BlockingOutput()) }))
        val id = h.engine.send(listOf(MemSource("big.bin", ByteArray(2_000_000)))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build())
        awaitUntil(5_000, "stream open") { h.streams.size == 1 }
        Thread.sleep(50)
        val before = h.sent.size
        h.deliver(MessageType.FILES_CANCEL, TransferCancel.newBuilder().setTransferId(id).build())
        h.awaitState(id, TransferState.CANCELLED)
        awaitUntil(5_000, "closed") { h.streams.single().closed.get() }
        assertEquals(before, h.sent.size)
        assertFalse(MessageType.FILES_COMPLETE in h.types())
    }

    @Test
    fun acceptTimeoutFailsTimedOut() {
        val h = harness(Harness(timing = TransferTiming(acceptTimeoutMs = 100)))
        val id = h.engine.send(listOf(MemSource("a.bin", ByteArray(10)))).single()
        h.awaitState(id, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.status(id).error)
        assertTrue(h.hellos.isEmpty())
        // The peer is told to drop the offer.
        assertEquals(id, h.last<TransferCancel>(MessageType.FILES_CANCEL).transferId)
    }

    @Test
    fun rejectedOfferFailsWithPeerReason() {
        val h = harness(Harness())
        val id = h.engine.send(listOf(MemSource("a.bin", ByteArray(10)))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        h.deliver(MessageType.FILES_REJECT, TransferReject.newBuilder().setTransferId(id).setReason(TransferError.TRANSFER_ERROR_NO_SPACE).build())
        h.awaitState(id, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_NO_SPACE, h.status(id).error)
        assertTrue(h.hellos.isEmpty())
    }

    @Test
    fun offerLargerThanFreeSpaceIsRejected() {
        var opened = false
        val h = harness(Harness(free = { 100L shl 20 }, sinkFor = { opened = true; SinkResult.Ready(MemSink()) }))
        // 40 MiB + 64 MiB margin > 100 MiB free.
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 40L shl 20))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_NO_SPACE, h.last<TransferReject>(MessageType.FILES_REJECT).reason)
        assertEquals(TransferError.TRANSFER_ERROR_NO_SPACE, h.status("m1").error)
        assertFalse(opened)
        assertTrue(h.hellos.isEmpty())
        assertFalse(MessageType.FILES_ACCEPT in h.types())
        // 30 MiB + 64 MiB fits in 100 MiB.
        h.deliver(MessageType.FILES_OFFER, h.offer("m2", 30L shl 20))
        h.awaitSent(MessageType.FILES_ACCEPT)
    }

    @Test
    fun refusedSinkRejectsWithReason() {
        val h = harness(Harness(sinkFor = { SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 10))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_DENIED, h.last<TransferReject>(MessageType.FILES_REJECT).reason)
        assertEquals(TransferError.TRANSFER_ERROR_DENIED, h.status("m1").error)
        assertTrue(h.hellos.isEmpty())
    }

    @Test
    fun disconnectFailsActiveAndAbortsPartial() {
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = BlockingInput()) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000_000))
        awaitUntil(5_000, "stream open") { h.streams.size == 1 }
        // A queued send that never started.
        val q = h.engine.send(listOf(MemSource("q.bin", ByteArray(5)))).single()
        val before = h.sent.size
        h.engine.onDisconnected()
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.status("m1").error)
        awaitUntil(5_000, "aborted") { sink.aborted.get() }
        assertTrue(h.streams.single().closed.get())
        // The send worker may already have picked the queued send up: then it ends on that
        // worker's thread, not inside onDisconnected().
        h.awaitState(q, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.status(q).error)
        Thread.sleep(50)
        // Nothing but the queued send's own offer (if it got out first) was sent after the disconnect.
        assertTrue(h.sent.drop(before).none { it.first != MessageType.FILES_OFFER })
        assertEquals(0, h.openNow.get())
    }

    @Test
    fun bulkEndsEarlyFailsInterrupted() {
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = ByteArrayInputStream(ByteArray(500))) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.status("m1").error)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertTrue(sink.aborted.get())
        assertTrue(h.streams.single().closed.get())
    }

    @Test
    fun extraBytesFail() {
        val data = Random(5).nextBytes(1_000)
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = {
            FakeStream(input = ByteArrayInputStream(data + ByteArray(5)))
        }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", sha(data)))
        h.awaitState("m1", TransferState.FAILED)
        assertTrue(sink.aborted.get())
        assertFalse(sink.committed.get())
        assertTrue(MessageType.FILES_FAILED in h.types())
    }

    @Test
    fun sourceLongerThanAnnouncedFails() {
        val h = harness(Harness())
        val id = h.engine.send(listOf(MemSource("a.bin", ByteArray(20), size = 10))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build())
        h.awaitState(id, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_IO, h.status(id).error)
        assertEquals(TransferError.TRANSFER_ERROR_IO, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertFalse(MessageType.FILES_COMPLETE in h.types())
    }

    @Test
    fun stalledReceiveTimesOut() {
        val sink = MemSink()
        val h = harness(Harness(timing = TransferTiming(stallTimeoutMs = 200), sinkFor = { SinkResult.Ready(sink) },
            makeStream = { FakeStream(input = BlockingInput()) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.status("m1").error)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertTrue(sink.aborted.get())
        assertTrue(h.streams.single().closed.get())
    }

    @Test
    fun stalledSendTimesOut() {
        val h = harness(Harness(timing = TransferTiming(stallTimeoutMs = 200), makeStream = { FakeStream(output = BlockingOutput()) }))
        val id = h.engine.send(listOf(MemSource("a.bin", ByteArray(1_000)))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build())
        h.awaitState(id, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.status(id).error)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
    }

    @Test
    fun peerFailureAfterCompleteFailsSend() {
        val h = harness(Harness())
        val id = h.engine.send(listOf(MemSource("a.bin", ByteArray(10)))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build())
        h.awaitSent(MessageType.FILES_COMPLETE)
        h.deliver(MessageType.FILES_FAILED, TransferFailed.newBuilder().setTransferId(id).setReason(TransferError.TRANSFER_ERROR_HASH_MISMATCH).build())
        h.awaitState(id, TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_HASH_MISMATCH, h.status(id).error)
    }

    @Test
    fun fiftyFilesRunOneAtATime() {
        lateinit var h: Harness
        h = harness(Harness(onSend = { type, p ->
            val id = when (p) {
                is TransferOffer -> p.transferId
                is TransferComplete -> p.transferId
                else -> ""
            }
            h.scope.launch {
                when (type) {
                    MessageType.FILES_OFFER -> h.engine.onMessage(h.env(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build()))
                    MessageType.FILES_COMPLETE -> h.engine.onMessage(h.env(MessageType.FILES_RECEIVED, TransferReceived.newBuilder().setTransferId(id).build()))
                }
            }
        }))
        val ids = h.engine.send((1..50).map { MemSource("f$it.bin", ByteArray(100) { b -> b.toByte() }) })
        assertEquals(50, ids.size)
        assertEquals(50, ids.toSet().size)
        // Not each id in turn: the engine keeps only the last 20 finished, so an early one can be
        // gone from the list before it is looked for. All 50 completed and everything listed is done.
        awaitUntil(30_000, "50 completes, all listed done") {
            h.sent.count { it.first == MessageType.FILES_COMPLETE } == 50 &&
                h.engine.transfers.value.let { list -> list.isNotEmpty() && list.all { it.state == TransferState.DONE } }
        }
        assertEquals(1, h.maxOpen.get())
        assertEquals(0, h.openNow.get())
        assertEquals(20, h.engine.transfers.value.count { it.state == TransferState.DONE }) // only the last 20 are kept
        // Offers went out in call order.
        val offered = h.sent.filter { it.first == MessageType.FILES_OFFER }.map { (it.second as TransferOffer).transferId }
        assertEquals(ids, offered)
    }

    @Test
    fun sizeAbove4GiBIsKept() {
        val big = 5_000_000_000L
        val counted = CountingOutput()
        val clock = AtomicLong(1_000)
        lateinit var h: Harness
        h = harness(Harness(
            clock = clock,
            makeStream = { hello ->
                if (hello.role == BulkRole.BULK_ROLE_PHONE_SENDS) FakeStream(output = counted)
                else FakeStream(input = ZeroInput(big, clock, 300))
            },
            sinkFor = { SinkResult.Ready(MemSink(out = CountingOutput())) },
            onSend = { type, p ->
                h.scope.launch {
                    when (type) {
                        MessageType.FILES_OFFER -> h.engine.onMessage(h.env(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId((p as TransferOffer).transferId).build()))
                        MessageType.FILES_COMPLETE -> h.engine.onMessage(h.env(MessageType.FILES_RECEIVED, TransferReceived.newBuilder().setTransferId((p as TransferComplete).transferId).build()))
                    }
                }
            },
        ))
        val id = h.engine.send(listOf(StreamSource("big.mkv", big) { ZeroInput(big) })).single()
        h.awaitState(id, TransferState.DONE, 120_000)
        assertEquals(big, h.offersSent().single().size)
        assertEquals(big, counted.count.get())
        assertEquals(big, h.status(id).size)
        assertEquals(big, h.status(id).done)
        // Hash of five billion zero bytes, computed independently.
        val md = MessageDigest.getInstance("SHA-256")
        val zeros = ByteArray(1 shl 20)
        var left = big
        while (left > 0) { val n = minOf(left, zeros.size.toLong()).toInt(); md.update(zeros, 0, n); left -= n }
        val expected = md.digest()
        assertContentEquals(expected, h.last<TransferComplete>(MessageType.FILES_COMPLETE).sha256.toByteArray())

        // Receiving the same size keeps the exact value in progress, status and hash check.
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", big))
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", expected))
        h.awaitState("m1", TransferState.DONE, 120_000)
        assertEquals(big, h.status("m1").size)
        assertEquals(big, h.status("m1").done)
        val maxProgress = h.sent.filter { it.first == MessageType.FILES_PROGRESS }
            .maxOf { (it.second as io.github.anmirror.protocol.v1.TransferProgress).bytesDone }
        assertTrue(maxProgress > (1L shl 32), "progress above 2^32 expected, got $maxProgress")
    }

    private fun Harness.offersSent() = sent.filter { it.first == MessageType.FILES_OFFER }.map { it.second as TransferOffer }

    @Test
    fun zeroByteFileCompletes() {
        val h = harness(Harness(makeStream = { FakeStream(input = ByteArrayInputStream(ByteArray(0))) }))
        val id = h.engine.send(listOf(MemSource("empty.txt", ByteArray(0)))).single()
        h.awaitSent(MessageType.FILES_OFFER)
        assertEquals(0L, h.last<TransferOffer>(MessageType.FILES_OFFER).size)
        h.deliver(MessageType.FILES_ACCEPT, TransferAccept.newBuilder().setTransferId(id).build())
        h.awaitSent(MessageType.FILES_COMPLETE)
        assertContentEquals(sha(ByteArray(0)), h.last<TransferComplete>(MessageType.FILES_COMPLETE).sha256.toByteArray())
        h.deliver(MessageType.FILES_RECEIVED, TransferReceived.newBuilder().setTransferId(id).build())
        h.awaitState(id, TransferState.DONE)

        val sink = MemSink()
        val h2 = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = ByteArrayInputStream(ByteArray(0))) }))
        h2.deliver(MessageType.FILES_OFFER, h2.offer("m1", 0))
        h2.deliver(MessageType.FILES_COMPLETE, h2.complete("m1", sha(ByteArray(0))))
        h2.awaitState("m1", TransferState.DONE)
        assertTrue(sink.committed.get())
    }

    @Test
    fun nonFilesTypeReturnsFalse() {
        val h = harness(Harness())
        assertFalse(h.deliver(MessageType.CLIPBOARD_TEXT, TransferCancel.getDefaultInstance()))
        assertFalse(h.deliver(MessageType.FILES_ENDPOINT, TransferCancel.getDefaultInstance()))
        assertTrue(h.deliver(MessageType.FILES_CANCEL, TransferCancel.newBuilder().setTransferId("nope").build()))
        assertTrue(h.engine.transfers.value.isEmpty())
        assertNull(h.engine.transfers.value.firstOrNull())
    }

    @Test
    fun commitThrowsAbortsSink() {
        val data = Random(6).nextBytes(1_000)
        val sink = MemSink(commitFails = true)
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, makeStream = { FakeStream(input = ByteArrayInputStream(data)) }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", data.size.toLong()))
        h.deliver(MessageType.FILES_COMPLETE, h.complete("m1", sha(data)))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_IO, h.status("m1").error)
        assertTrue(sink.aborted.get())
        assertEquals(TransferError.TRANSFER_ERROR_IO, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertFalse(MessageType.FILES_RECEIVED in h.types())
    }

    @Test
    fun cancelDuringDialFailsImmediately() {
        val h = harness(Harness(dial = { kotlinx.coroutines.awaitCancellation() }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.awaitSent(MessageType.FILES_ACCEPT)
        awaitUntil(5_000, "dialling") { h.hellos.size == 1 }
        h.engine.cancel("m1")
        h.awaitState("m1", TransferState.CANCELLED, 3_000) // the stall timeout is 30 s
        h.awaitSent(MessageType.FILES_CANCEL)
    }

    @Test
    fun dialThatThrowsFailsInterrupted() {
        val sink = MemSink()
        val h = harness(Harness(sinkFor = { SinkResult.Ready(sink) }, dial = { throw IOException("refused") }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.status("m1").error)
        assertEquals(TransferError.TRANSFER_ERROR_INTERRUPTED, h.last<TransferFailed>(MessageType.FILES_FAILED).reason)
        assertTrue(sink.aborted.get())
    }

    @Test
    fun slowDialTimesOutAndLateStreamIsClosed() {
        val h = harness(Harness(
            timing = TransferTiming(stallTimeoutMs = 100),
            dial = { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { kotlinx.coroutines.delay(400) } },
        ))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 1_000))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_TIMED_OUT, h.status("m1").error)
        awaitUntil(5_000, "late stream closed") { h.streams.size == 1 && h.streams.single().closed.get() }
    }

    @Test
    fun throwingSinkOrFreeBytesRejectsWithIo() {
        val h = harness(Harness(sinkFor = { throw IOException("no storage") }))
        h.deliver(MessageType.FILES_OFFER, h.offer("m1", 10))
        h.awaitState("m1", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_IO, h.last<TransferReject>(MessageType.FILES_REJECT).reason)
        assertFalse(MessageType.FILES_FAILED in h.types())

        val h2 = harness(Harness(free = { throw IllegalStateException("stat") }))
        h2.deliver(MessageType.FILES_OFFER, h2.offer("m2", 10))
        h2.awaitState("m2", TransferState.FAILED)
        assertEquals(TransferError.TRANSFER_ERROR_IO, h2.last<TransferReject>(MessageType.FILES_REJECT).reason)
        assertFalse(MessageType.FILES_FAILED in h2.types())
    }

    @Test
    fun statusCarriesRequestIdAndBrowseTarget() {
        // R16: the app tells browse traffic apart by these two.
        val h = harness(Harness(sinkFor = { SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED) }))
        val read = h.engine.send(listOf(MemSource("a.txt", ByteArray(1), "text/plain")), requestId = 42).single()
        val plain = h.engine.send(listOf(MemSource("b.txt", ByteArray(1), "text/plain"))).single()
        assertEquals(42L, h.status(read).requestId)
        assertEquals(0L, h.status(plain).requestId)
        assertFalse(h.status(read).browseTarget)

        val target = BrowseTarget.newBuilder().setRootId("r").setDirPath("d").build()
        h.deliver(MessageType.FILES_OFFER, h.offer("w1", 1).toBuilder().setTarget(target).build())
        h.deliver(MessageType.FILES_OFFER, h.offer("w2", 1))
        assertTrue(h.status("w1").browseTarget)
        assertFalse(h.status("w2").browseTarget)
        assertEquals(0L, h.status("w1").requestId)
    }

    @Test
    fun requestedSendStoppedBeforeItsOfferSaysFailedWithTheRequest() {
        // M1: a send answering a Mac request, stopped here while queued, must not leave the Mac
        // waiting for an offer that never comes.
        val h = harness(Harness())
        val first = h.engine.send(listOf(MemSource("a.bin", ByteArray(1)))).single()
        h.awaitState(first, TransferState.WAITING) // holds the send queue
        val read = h.engine.send(listOf(MemSource("b.bin", ByteArray(1))), requestId = 9).single()
        val plain = h.engine.send(listOf(MemSource("c.bin", ByteArray(1)))).single()
        h.engine.cancel(read)
        h.engine.cancel(plain)
        h.awaitState(read, TransferState.CANCELLED)
        h.awaitState(plain, TransferState.CANCELLED)
        h.awaitSent(MessageType.FILES_FAILED)
        val failed = h.last<TransferFailed>(MessageType.FILES_FAILED)
        assertEquals(read, failed.transferId)
        assertEquals(9L, failed.requestId)
        assertEquals(TransferError.TRANSFER_ERROR_CANCELLED, failed.reason)
        Thread.sleep(100)
        // The plain one the Mac never heard of: nothing. Neither was ever offered.
        assertEquals(1, h.types().count { it == MessageType.FILES_FAILED })
        assertFalse(MessageType.FILES_CANCEL in h.types())
        assertEquals(listOf(first), h.sent.filter { it.first == MessageType.FILES_OFFER }.map { (it.second as TransferOffer).transferId })
    }

    @Test
    fun requestedSendDroppedByADisconnectSendsNothing() {
        val h = harness(Harness())
        val first = h.engine.send(listOf(MemSource("a.bin", ByteArray(1)))).single()
        h.awaitState(first, TransferState.WAITING)
        val read = h.engine.send(listOf(MemSource("b.bin", ByteArray(1))), requestId = 9).single()
        h.engine.onDisconnected()
        h.awaitState(read, TransferState.FAILED)
        Thread.sleep(100)
        assertFalse(MessageType.FILES_FAILED in h.types())
    }
}
