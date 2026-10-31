package io.github.anmirror.adb

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.ConnectException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** libadb itself, against real loopback sockets (the JVM's TLS stands in for Conscrypt). */
class LibAdbClientTest {
    private val identity = sharedIdentity
    private val servers = mutableListOf<ServerSocket>()
    private val accepted = mutableListOf<Socket>()
    private val closes = AtomicInteger()

    @AfterTest
    fun tearDown() {
        accepted.forEach { runCatching { it.close() } }
        servers.forEach { runCatching { it.close() } }
    }

    private fun client(timeoutMs: Long = 2_000): LibAdbClient {
        val c = LibAdbClient(identity, sdk = 30, timeoutMs = timeoutMs)
        LibAdbTls.useContext(jvmTls())
        val real = c.pairingSessions
        c.pairingSessions = PairingSessionFactory { host, port, code ->
            val session = real.open(host, port, code)
            object : PairingSession {
                override fun start() = session.start()
                override fun close() {
                    closes.incrementAndGet()
                    session.close() // libadb throws a NullPointerException here before its streams exist
                }
            }
        }
        return c
    }

    private fun closedPort(): Int = ServerSocket(0).use { it.localPort }

    /** A loopback server that runs [onClient] for each connection on its own thread. */
    private fun server(onClient: (Socket) -> Unit): Int {
        val s = ServerSocket(0)
        servers += s
        thread(isDaemon = true) {
            while (!s.isClosed) {
                val c = runCatching { s.accept() }.getOrNull() ?: break
                synchronized(accepted) { accepted += c }
                thread(isDaemon = true) { runCatching { onClient(c) } }
            }
        }
        return s.localPort
    }

    private fun awaitCloses(n: Int) {
        val until = System.currentTimeMillis() + 3_000
        while (closes.get() < n && System.currentTimeMillis() < until) Thread.sleep(10)
        assertEquals(n, closes.get(), "pairing context closes")
    }

    @Test
    fun refusedPortIsNotListeningAndClosesOnce() = runBlocking {
        val e = assertFailsWith<AdbPairingException> { client().pair("127.0.0.1", closedPort(), "482916") }
        assertEquals(AdbPairingException.Stage.NOT_LISTENING, e.stage)
        awaitCloses(1)
    }

    @Test
    fun serverDroppingTheTlsHandshakeIsHandshakeAndClosesOnce() = runBlocking {
        val port = server { c ->
            c.getInputStream().read(ByteArray(4096)) // the ClientHello
            c.close()
        }
        val e = assertFailsWith<AdbPairingException> { client().pair("127.0.0.1", port, "482916") }
        assertEquals(AdbPairingException.Stage.HANDSHAKE, e.stage, e.cause.toString())
        awaitCloses(1)
    }

    @Test
    fun silentServerTimesOutWithinTheLimit() = runBlocking {
        val port = server { c -> c.getInputStream().read(ByteArray(4096)) } // reads the hello, never answers
        val started = System.currentTimeMillis()
        // Bounded, so a regression fails here instead of hanging the suite.
        withTimeout(5_000) { assertFailsWith<SocketTimeoutException> { client(timeoutMs = 500).pair("127.0.0.1", port, "482916") } }
        val took = System.currentTimeMillis() - started
        assertTrue(took < 2_000, "took $took ms")
        // The abandoned attempt ends when the peer goes, and closes its context there, once.
        assertEquals(0, closes.get())
        synchronized(accepted) { accepted.forEach { it.close() } }
        awaitCloses(1)
    }

    @Test
    fun connectToClosedPortFailsAtOnce() = runBlocking {
        assertFailsWith<ConnectException> { client().connect("127.0.0.1", closedPort()) }
        Unit
    }

    @Test
    fun connectToSilentServerTimesOutWithinTheLimit() = runBlocking {
        val port = server { c -> c.getInputStream().read(ByteArray(4096)) }
        val started = System.currentTimeMillis()
        val e = withTimeout(5_000) { assertFailsWith<IOException> { client(timeoutMs = 500).connect("127.0.0.1", port) } }
        val took = System.currentTimeMillis() - started
        assertTrue(e is SocketTimeoutException, e.toString())
        assertTrue(took < 4_000, "took $took ms")
    }

    @Test
    fun connectAbandonedDuringBuildClosesTheLateConnection() = runBlocking {
        val firstReads = ConcurrentLinkedQueue<Int>()
        val ended = CountDownLatch(2) // our timed probe, then libadb's socket
        val port = server { c ->
            firstReads += c.getInputStream().read(ByteArray(64))
            ended.countDown()
        }
        val c = client(timeoutMs = 300)
        val release = CountDownLatch(1)
        val real = c.buildConnection
        c.buildConnection = { host, p ->
            release.await() // build() is still running when the connect is given up
            real(host, p)
        }
        withTimeout(5_000) { assertFailsWith<SocketTimeoutException> { c.connect("127.0.0.1", port) } }
        release.countDown()
        assertTrue(ended.await(3, TimeUnit.SECONDS), "the late connection was not closed")
        // Both sockets closed without a byte: the late connection never sent CNXN, and isn't tracked.
        assertEquals(listOf(-1, -1), firstReads.toList())
        assertFalse(c.isConnected)
    }

    @Test
    fun silentOpenTimesOutAndDropsTheConnection() = runBlocking {
        val ended = CountDownLatch(1)
        val port = server { c ->
            c.getInputStream().read(ByteArray(64)) // returns once we close
            ended.countDown()
        }
        val c = LibAdbClient(identity, sdk = 30, timeoutMs = 2_000, openTimeoutMs = 300)
        LibAdbTls.useContext(jvmTls())
        c.useConnection(c.buildConnection("127.0.0.1", port))
        val gate = CountDownLatch(1)
        c.openStream = { _, _ ->
            gate.await() // adbd never answers the OPEN
            error("unreachable")
        }
        val started = System.currentTimeMillis()
        withTimeout(5_000) { assertFailsWith<SocketTimeoutException> { c.open("localabstract:scrcpy_0a1b2c3d") } }
        val took = System.currentTimeMillis() - started
        assertTrue(took < 2_000, "took $took ms")
        // The connection was closed and forgotten: later opens fail at once instead of waiting.
        assertTrue(ended.await(3, TimeUnit.SECONDS), "the silent connection was not closed")
        assertFailsWith<IOException> { c.open("shell:true") }
        gate.countDown()
    }

    @Test
    fun queueMeterCountsQueuedPayloadsAndTheBufferRest() {
        assertTrue(LibAdbQueue.fieldsFound, "libadb's AdbStream fields moved: the relay's backlog can't be measured")
        val queue = ConcurrentLinkedQueue<ByteArray>(listOf(ByteArray(4_096), ByteArray(1_000)))
        val buffer = java.nio.ByteBuffer.allocate(8_192).apply {
            put(ByteArray(300))
            flip()
            position(100)
        }
        assertEquals(4_096L + 1_000L + 200L, LibAdbQueue.queuedBytes(queue, buffer))
        assertEquals(0L, LibAdbQueue.queuedBytes(ConcurrentLinkedQueue<ByteArray>(), null))
    }

    @Test
    fun missingTlsCacheFieldIsReported() {
        assertNull(LibAdbTls.forgetCachedContext())
        assertEquals("ClassNotFoundException", LibAdbTls.forgetCachedContext("io.github.muntashirakon.adb.Gone"))
    }

    @Test
    fun closeOnceRunsOnceAndSwallows() {
        var runs = 0
        val once = CloseOnce {
            runs++
            throw NullPointerException("libadb")
        }
        once()
        once()
        assertEquals(1, runs)
    }

    private companion object {
        val sharedIdentity by lazy { AdbIdentity.generate() }

        fun jvmTls(): SSLContext = SSLContext.getInstance("TLSv1.3").apply {
            val trustAll = object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            }
            init(null, arrayOf(trustAll), null)
        }
    }
}
