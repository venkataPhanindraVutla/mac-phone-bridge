package io.github.anmirror.feature.mirror

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayPumpTest {
    @Test
    fun relayFlushesEveryChunk() {
        val events = CopyOnWriteArrayList<String>()
        val written = java.io.ByteArrayOutputStream()
        val out = object : OutputStream() {
            override fun write(b: Int) = throw AssertionError("single bytes")
            override fun write(b: ByteArray, off: Int, len: Int) {
                events += "write $len"
                written.write(b, off, len)
            }
            override fun flush() {
                events += "flush"
            }
        }
        val source = BytePipe()
        val done = CountDownLatch(1)
        thread { RelayPump.run(source.input, out) { done.countDown() } }
        source.output.write(ByteArray(10) { 1 })
        waitFor { events.size >= 2 }
        source.output.write(ByteArray(5) { 2 })
        source.close()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("write 10", "flush", "write 5", "flush"), events)
        assertContentEquals(ByteArray(10) { 1 } + ByteArray(5) { 2 }, written.toByteArray())
    }

    @Test
    fun eofEndsOnce() {
        val ends = CopyOnWriteArrayList<Throwable?>()
        val bytes = RelayPump.run(ByteArrayInputStream(ByteArray(200_000)), OutputStream.nullOutputStream()) { ends += it }
        assertEquals(listOf<Throwable?>(null), ends)
        assertEquals(200_000L, bytes)
    }

    @Test
    fun readAndWriteFailuresAreTold() {
        val readEnds = CopyOnWriteArrayList<Throwable?>()
        val failing = object : InputStream() {
            override fun read(): Int = throw IOException("reset")
        }
        RelayPump.run(failing, OutputStream.nullOutputStream()) { readEnds += it }
        assertEquals(1, readEnds.size)
        assertIs<IOException>(readEnds[0])
        assertTrue(readEnds[0] !is RelayPump.WriteFailed)

        val writeEnds = CopyOnWriteArrayList<Throwable?>()
        val broken = object : OutputStream() {
            override fun write(b: Int) = throw IOException("broken pipe")
        }
        RelayPump.run(ByteArrayInputStream(ByteArray(10)), broken) { writeEnds += it }
        assertEquals(1, writeEnds.size)
        assertIs<RelayPump.WriteFailed>(writeEnds[0])
    }

    @Test
    fun meterShowsTimeBlockedInTheCurrentWrite() {
        var now = 1_000L
        val meter = RelayPump.WriteMeter { now }
        assertEquals(0L, meter.blockedMs())
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val out = object : OutputStream() {
            override fun write(b: Int) = Unit
            override fun write(b: ByteArray, off: Int, len: Int) {
                entered.countDown()
                release.await()
            }
        }
        val source = BytePipe()
        val pump = thread { RelayPump.run(source.input, out, meter) {} }
        source.output.write(ByteArray(10))
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        now = 3_500L
        assertEquals(2_500L, meter.blockedMs())
        release.countDown()
        waitFor { meter.blockedMs() == 0L }
        source.close()
        pump.join(5_000)
    }

    @Test
    fun blockedOutputStopsReadingAfterOneChunk() {
        val read = AtomicLong()
        val endless = object : InputStream() {
            override fun read(): Int = 0.also { read.incrementAndGet() }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                read.addAndGet(len.toLong())
                return len
            }
        }
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val writes = AtomicInteger()
        val blocked = object : OutputStream() {
            override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
            override fun write(b: ByteArray, off: Int, len: Int) {
                writes.incrementAndGet()
                entered.countDown()
                release.await()
                throw IOException("closed")
            }
        }
        val end = CopyOnWriteArrayList<Throwable?>()
        val pump = thread { RelayPump.run(endless, blocked) { end += it } }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        Thread.sleep(200)
        assertTrue(read.get() <= RelayPump.BUFFER_BYTES, "read ${read.get()}")
        assertEquals(1, writes.get())
        release.countDown()
        pump.join(5_000)
        assertEquals(1, end.size)
        assertNull(end.firstOrNull()?.takeIf { it !is RelayPump.WriteFailed })
    }
}

/** Polls [cond] for up to 5 s. */
fun waitFor(cond: () -> Boolean) {
    val deadline = System.nanoTime() + 5_000_000_000L
    while (!cond()) {
        if (System.nanoTime() > deadline) throw AssertionError("timed out")
        Thread.sleep(5)
    }
}
