package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbClient
import io.github.anmirror.adb.AdbEndpoint
import io.github.anmirror.adb.AdbIdentity
import io.github.anmirror.adb.AdbPairingException
import io.github.anmirror.adb.AdbPipe
import io.github.anmirror.adb.AdbService
import io.github.anmirror.adb.AdbServiceFinder
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import java.io.IOException
import java.net.ConnectException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

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
    override var isConnected = false

    override suspend fun pair(host: String, port: Int, code: String) {
        pairs += "$host:$port:$code"
        pairResult(host)
    }

    override suspend fun connect(host: String, port: Int) {
        connects += "$host:$port"
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
        assertEquals(listOf(AdbService.PAIRING to 6_000L), finder.asked)
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
