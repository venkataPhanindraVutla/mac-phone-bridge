package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbClient
import io.github.anmirror.adb.AdbEndpoint
import io.github.anmirror.adb.AdbIdentity
import io.github.anmirror.adb.AdbNotPairedException
import io.github.anmirror.adb.AdbPairingException
import io.github.anmirror.adb.AdbPipe
import io.github.anmirror.adb.AdbService
import io.github.anmirror.adb.AdbServiceFinder
import io.github.anmirror.adb.LibAdbClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import java.io.IOException
import java.net.ConnectException
import java.net.ServerSocket
import java.net.Socket
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * libadb builds its TLS context once per process, with Conscrypt, which the JVM lacks: hand it
 * the JVM's own (after the client is made, since a new client drops libadb's cache).
 */
private fun useJvmTls() {
    val trustAll = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
    val tls = SSLContext.getInstance("TLSv1.3").apply { init(null, arrayOf(trustAll), null) }
    Class.forName("io.github.muntashirakon.adb.SslUtils").getDeclaredField("sslContext").apply { isAccessible = true }.set(null, tls)
}

/** One RSA key for the whole file: generating one takes a while. */
private val testIdentity by lazy { AdbIdentity.generate(nowMs = 1_790_000_000_000L) }

private class MemoryStore : SetupStore {
    override var paired = false
    override var lastConnectPort: Int? = null
    override var lastConnectFailed = false
}

private class FakeIdentities : IdentityHolder {
    var current: AdbIdentity? = null
    var created = 0
    var deleted = 0
    override fun load(): AdbIdentity? = current
    override fun create(): AdbIdentity = testIdentity.also { current = it; created++ }
    override fun delete() {
        current = null
        deleted++
    }
}

private class FakeAdb : AdbClient {
    val pairs = mutableListOf<String>()
    val connects = mutableListOf<String>()
    var closed = 0
    var pairResult: (host: String) -> Unit = {}
    var connectOk: (host: String, port: Int) -> Boolean = { _, _ -> true }
    var connectError: () -> IOException? = { null }
    override var isConnected = false

    override suspend fun pair(host: String, port: Int, code: String) {
        pairs += "$host:$port:$code"
        pairResult(host)
    }

    override suspend fun connect(host: String, port: Int) {
        connects += "$host:$port"
        connectError()?.let { throw it }
        if (!connectOk(host, port)) throw ConnectException("refused")
        isConnected = true
    }

    override suspend fun shell(command: String): String = throw IOException("not used")
    override suspend fun open(service: String): AdbPipe = throw IOException("not used")
    override fun close() {
        closed++
        isConnected = false
    }
}

private class FakeFinder : AdbServiceFinder {
    val found = mutableMapOf<AdbService, AdbEndpoint>()
    val asked = mutableListOf<Pair<AdbService, Long>>()
    override suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint? {
        asked += service to timeoutMs
        return found[service] ?: run {
            delay(timeoutMs)
            null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class) // advanceUntilIdle
class FullModeSetupTest {
    private val adb = FakeAdb()
    private val finder = FakeFinder()
    private val store = MemoryStore()
    private val identities = FakeIdentities()
    private val notified = mutableListOf<Boolean>()

    private fun TestScope.setup() = FullModeSetup(
        adb = { adb }, finder = finder, store = store, identity = identities,
        notify = { notified += it }, scope = this,
    )

    @Test
    fun pairThenConnectReachesReady() = runTest {
        finder.found[AdbService.PAIRING] = AdbEndpoint("192.168.0.20", 37123)
        finder.found[AdbService.CONNECT] = AdbEndpoint("192.168.0.20", 41000)
        val s = setup()
        assertEquals(SetupState.Unpaired, s.state.value)
        s.startPairing()
        advanceUntilIdle()
        // The connect port is looked up alongside the pairing port.
        assertEquals(setOf(AdbService.PAIRING to 6_000L, AdbService.CONNECT to 6_000L), finder.asked.toSet())
        assertEquals(SetupState.Pairing(portKnown = true), s.state.value)
        assertEquals(listOf(true), notified)
        assertEquals(1, identities.created)

        assertNull(s.submitReply("482916"))
        assertEquals(listOf("127.0.0.1:37123:482916"), adb.pairs)
        assertTrue(store.paired && s.paired)
        assertEquals(AdbService.CONNECT to 5_000L, finder.asked.last())
        assertEquals(listOf("127.0.0.1:41000"), adb.connects)
        assertEquals(41000, store.lastConnectPort)
        assertFalse(store.lastConnectFailed)
        assertEquals(SetupState.Ready, s.state.value)
        assertEquals(1, identities.created) // created once
    }

    @Test
    fun pairFallsBackToTheNsdHost() = runTest {
        finder.found[AdbService.PAIRING] = AdbEndpoint("192.168.0.20", 37123)
        adb.pairResult = { host -> if (host == "127.0.0.1") throw AdbPairingException(AdbPairingException.Stage.NOT_LISTENING, ConnectException()) }
        val s = setup()
        s.startPairing()
        advanceUntilIdle()
        assertNull(s.submitReply("482916"))
        assertEquals(listOf("127.0.0.1:37123:482916", "192.168.0.20:37123:482916"), adb.pairs)
        assertTrue(store.paired)
    }

    @Test
    fun wrongCodeStaysUnpairedAndRepostsNotification() = runTest {
        adb.pairResult = { throw AdbPairingException(AdbPairingException.Stage.AFTER_HANDSHAKE, IOException("Could not exchange peer info.")) }
        val s = setup()
        s.startPairing()
        advanceUntilIdle()
        assertEquals(SetupState.Pairing(portKnown = false), s.state.value)
        assertEquals(PairingError.WRONG_CODE, s.submitReply("37123 482916"))
        assertFalse(store.paired)
        assertEquals(SetupState.PairFailed(PairingError.WRONG_CODE), s.state.value)
        assertEquals(listOf(false, false), notified)
        assertTrue(adb.connects.isEmpty())

        // A reply that does not parse never reaches the client.
        assertEquals(PairingError.INVALID, s.submitReply("482916"))
        assertEquals(1, adb.pairs.size)
        assertEquals(SetupState.PairFailed(PairingError.INVALID), s.state.value)
        assertEquals(3, notified.size)
    }

    @Test
    fun cachedPortTriedBeforeNsd() = runTest {
        identities.current = testIdentity
        store.paired = true
        store.lastConnectPort = 41000
        finder.found[AdbService.CONNECT] = AdbEndpoint("192.168.0.20", 42000)
        val s = setup()
        assertTrue(s.ensureConnected())
        assertEquals(listOf("127.0.0.1:41000"), adb.connects)
        assertTrue(finder.asked.isEmpty())

        // Connected: no new attempt at all.
        assertTrue(s.ensureConnected())
        assertEquals(1, adb.connects.size)

        // The cached port went stale (Wireless debugging was turned off and on): NSD gives the new one.
        adb.isConnected = false
        adb.connectOk = { _, port -> port == 42000 }
        assertTrue(s.ensureConnected())
        assertEquals(listOf("127.0.0.1:41000", "127.0.0.1:41000", "127.0.0.1:42000"), adb.connects)
        assertEquals(42000, store.lastConnectPort)
    }

    @Test
    fun nsdMissingFallsBackToTypedPort() = runTest {
        identities.current = testIdentity
        store.paired = true
        val s = setup()
        assertTrue(s.ensureConnected(typedPort = 43000))
        assertEquals(listOf(AdbService.CONNECT to 5_000L), finder.asked)
        assertEquals(listOf("127.0.0.1:43000"), adb.connects)
        assertEquals(43000, store.lastConnectPort)
        assertEquals(SetupState.Ready, s.state.value)
    }

    @Test
    fun connectFailureNeedsSetupUntilSuccess() = runTest {
        identities.current = testIdentity
        store.paired = true
        store.lastConnectPort = 41000
        finder.found[AdbService.CONNECT] = AdbEndpoint("192.168.0.20", 41000)
        adb.connectOk = { _, _ -> false }
        val s = setup()
        assertFalse(s.ensureConnected())
        // The cached port on loopback, then the NSD host (the same port on loopback is not tried twice).
        assertEquals(listOf("127.0.0.1:41000", "192.168.0.20:41000"), adb.connects)
        assertTrue(store.lastConnectFailed)
        assertEquals(SetupState.ConnectFailed, s.state.value)

        adb.connectOk = { _, port -> port == 44000 }
        assertTrue(s.ensureConnected(typedPort = 44000))
        assertFalse(store.lastConnectFailed)
        assertEquals(44000, store.lastConnectPort)
        assertEquals(SetupState.Ready, s.state.value)
    }

    @Test
    fun nsdConnectPortGivesWrongPort() = runTest {
        // A first setup: no cached port, but NSD found the connect port while looking for the pairing one.
        finder.found[AdbService.CONNECT] = AdbEndpoint("192.168.0.20", 41000)
        adb.pairResult = { throw AdbPairingException(AdbPairingException.Stage.HANDSHAKE, IOException("reset")) }
        val s = setup()
        s.startPairing()
        advanceUntilIdle()
        assertEquals(PairingError.WRONG_PORT, s.submitReply("41000 482916"))
    }

    @Test
    fun revokedPairingNeedsSetupAgain() = runTest {
        identities.current = testIdentity
        store.paired = true
        store.lastConnectPort = 41000
        finder.found[AdbService.CONNECT] = AdbEndpoint("192.168.0.20", 42000)
        adb.connectError = { AdbNotPairedException(null) }
        val s = setup()
        assertFalse(s.ensureConnected(typedPort = 43000))
        // No other port is tried: the daemon refuses this key everywhere.
        assertEquals(listOf("127.0.0.1:41000"), adb.connects)
        assertFalse(store.paired)
        assertNull(store.lastConnectPort)
        assertFalse(store.lastConnectFailed) // not "Wireless debugging is off": the row offers "Set up Full mode"
        assertEquals(SetupState.Unpaired, s.state.value)
        assertEquals(testIdentity, identities.current) // pairing the same key again is fine
    }

    @Test
    fun silentPairingServerReleasesTheMutexWithinTheLimit() = runBlocking {
        val server = ServerSocket(0)
        val held = mutableListOf<Socket>()
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val c = runCatching { server.accept() }.getOrNull() ?: break
                synchronized(held) { held += c } // accepts, reads nothing back, never answers
            }
        }
        try {
            identities.current = testIdentity
            val client = LibAdbClient(testIdentity, sdk = 30, timeoutMs = 500)
            useJvmTls()
            val s = FullModeSetup(
                adb = { client }, finder = object : AdbServiceFinder {
                    override suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint? = null
                },
                store = store, identity = identities, notify = { notified += it }, scope = this,
            )
            val started = System.currentTimeMillis()
            val reply = async(Dispatchers.Default) { s.submitReply("${server.localPort} 482916") }
            delay(50)
            // Queued behind the pairing on the mutex; it must get through once the pairing gives up.
            val other = async(Dispatchers.Default) { s.ensureConnected() }
            assertEquals(PairingError.TIMEOUT, reply.await())
            assertFalse(other.await())
            val took = System.currentTimeMillis() - started
            assertTrue(took < 3_000, "took $took ms")
            assertEquals(SetupState.PairFailed(PairingError.TIMEOUT), s.state.value)
        } finally {
            synchronized(held) { held.forEach { it.close() } }
            server.close()
        }
    }

    @Test
    fun forgetDeletesIdentity() = runTest {
        identities.current = testIdentity
        store.paired = true
        store.lastConnectPort = 41000
        store.lastConnectFailed = true
        val s = setup()
        assertEquals(SetupState.ConnectFailed, s.state.value)
        s.forget()
        assertEquals(1, identities.deleted)
        assertNull(identities.current)
        assertEquals(1, adb.closed)
        assertFalse(store.paired)
        assertNull(store.lastConnectPort)
        assertFalse(store.lastConnectFailed)
        assertEquals(SetupState.Unpaired, s.state.value)
        assertFalse(s.ensureConnected())
        assertTrue(adb.connects.isEmpty())
    }
}
