package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.PairingCrypto
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.RingRequest
import io.github.anmirror.protocol.v1.RingState
import io.github.anmirror.protocol.v1.StatusUpdate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import java.net.ServerSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionManagerTest {
    private val keyA = ByteArray(32) { 1 }
    private val keyB = ByteArray(32) { 2 }
    private val nowMs = 1_700_000_000_000L
    private val nowS = nowMs / 1000

    private fun macA(host: String? = "10.0.0.5", port: Int? = 4000, at: Long = 200) =
        PairedMac(Identities.MAC_FP, "Mac A", Identities.MAC_FP, keyA, host, port, at)

    private fun macB(host: String? = "10.0.0.8", port: Int? = 4000, at: Long = 100) =
        PairedMac(Identities.STRANGER_FP, "Mac B", Identities.STRANGER_FP, keyB, host, port, at)

    private fun service(host: String, port: Int, key: ByteArray, unixSeconds: Long = nowS) =
        DiscoveredService(host, port, mapOf("v" to "1", "r" to PairingCrypto.rotatingId(key, unixSeconds)))

    private class Rig(
        val manager: ConnectionManager,
        val connector: FakeConnector,
        val store: InMemoryPairedMacStore,
    )

    private fun TestScope.rig(
        macs: List<PairedMac>,
        discovery: MacDiscovery = StaticDiscovery(emptyList()),
        hello: () -> io.github.anmirror.protocol.v1.Hello = { phoneHello() },
    ): Rig {
        val connector = FakeConnector { testScheduler.currentTime }
        val store = InMemoryPairedMacStore(macs)
        val manager = ConnectionManager(backgroundScope, store, discovery, connector, hello, clock = { nowMs })
        return Rig(manager, connector, store)
    }

    private fun Rig.addMac(hostPort: String, fp: String, scope: CoroutineScope, caps: List<String> = CAPS): FakeMac =
        FakeMac(fp, scope, caps).also { connector.macs[hostPort] = it }

    @Test
    fun defaultTimingIsTheSpecValues() {
        val t = ConnectionTiming()
        assertEquals(30_000, t.pingIntervalMs)
        assertEquals(10_000, t.pongTimeoutMs)
        assertEquals(10_000, t.helloTimeoutMs)
        assertEquals(60_000, t.busyRetryMs)
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 5_000L, 5_000L, 5_000L, 30_000L, 60_000L, 60_000L, 60_000L),
            (0..9).map { t.backoff(it) },
        )
    }

    @Test
    fun connectsToLastAddressAndRecordsIt() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        val state = assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(Identities.MAC_FP, state.mac.id)
        assertEquals(setOf("find.v1", "status.v1"), state.shared)
        assertEquals(1, mac.connects)
        val saved = r.store.all().single()
        assertEquals("10.0.0.5", saved.lastHost)
        assertEquals(4000, saved.lastPort)
        assertEquals(nowMs, saved.lastConnectedAt)
    }

    @Test
    fun fallsBackToDiscoveryWhenLastAddressFails() = runBlocking {
        // Real TLS and real time: the stale port refuses, Bonjour finds the new one.
        TestMacServer { c ->
            c.answerHello()
            while (c.read(20_000) != null) continue
        }.use { server ->
            val stalePort = ServerSocket(0).use { it.localPort }
            val store = InMemoryPairedMacStore(listOf(macA(host = "127.0.0.1", port = stalePort)))
            val discovery = StaticDiscovery(
                listOf(service("127.0.0.1", server.port, keyA, System.currentTimeMillis() / 1000)),
            )
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val manager = ConnectionManager(scope, store, discovery, TlsConnector(Identities.phone), { phoneHello() })
            val started = System.nanoTime()
            manager.start()
            val connected = withTimeout(10_000) {
                manager.state.first { it is PhoneConnectionState.Connected } as PhoneConnectionState.Connected
            }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue(elapsedMs < 10_000, "reconnect took $elapsedMs ms")
            assertEquals(Identities.MAC_FP, connected.mac.id)
            val saved = store.all().single()
            assertEquals("127.0.0.1", saved.lastHost)
            assertEquals(server.port, saved.lastPort, "the discovered address replaces the stale one")
            manager.stop()
            scope.cancel()
            server.join()
        }
    }

    @Test
    fun ignoresServiceWithWrongRotatingId() = runTest {
        val discovery = StaticDiscovery(
            listOf(
                service("10.0.0.8", 4000, keyB), // another Mac's ID
                service("10.0.0.9", 4000, keyA, nowS + 2 * 900), // two epochs ahead: outside ±1
                DiscoveredService("10.0.0.10", 4000, mapOf("v" to "1")), // no r at all
            ),
        )
        val r = rig(listOf(macA(host = null, port = null)), discovery)
        // Even though these addresses would answer with the right certificate, they are not dialed.
        r.addMac("10.0.0.8:4000", Identities.MAC_FP, backgroundScope)
        r.addMac("10.0.0.9:4000", Identities.MAC_FP, backgroundScope)
        r.addMac("10.0.0.10:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(emptyList(), r.connector.dials.map { it.first })
        // Nothing to dial: no last address and no matching service.
        assertEquals(PhoneConnectionState.Searching, r.manager.state.value)
    }

    @Test
    fun acceptsRotatingIdFromAdjacentEpoch() = runTest {
        val discovery = StaticDiscovery(listOf(service("10.0.0.9", 4000, keyA, nowS - 900)))
        val r = rig(listOf(macA(host = null, port = null)), discovery)
        r.addMac("10.0.0.9:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(listOf("10.0.0.9:4000"), r.connector.dials.map { it.first })
    }

    @Test
    fun reconnectsWhenPongMissing() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.answerPings = false
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)

        // Ping at 30 s; the pong deadline is 40 s.
        advanceTimeBy(39_999)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(1, mac.connects)
        assertEquals(1, mac.received.count { it.type == MessageType.PING })

        advanceTimeBy(2)
        runCurrent()
        assertFalse(r.manager.state.value is PhoneConnectionState.Connected, "dropped at the pong deadline")

        mac.answerPings = true
        advanceTimeBy(1_000)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(2, mac.connects)
    }

    @Test
    fun keepsConnectionWhilePongsArrive() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        advanceTimeBy(125_000)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(1, mac.connects)
        assertEquals(4, mac.received.count { it.type == MessageType.PING })
    }

    @Test
    fun backoffCapsAt60sAfterSixAttempts() = runTest {
        val r = rig(listOf(macA()))
        r.manager.start()
        advanceTimeBy(400_001)
        runCurrent()
        // Waits 1, 2, 4, 5, 5, 5 s, then 30 s once, then 60 s.
        assertEquals(
            listOf(0L, 1_000L, 3_000L, 7_000L, 12_000L, 17_000L, 22_000L, 52_000L, 112_000L, 172_000L, 232_000L, 292_000L, 352_000L),
            r.connector.dials.map { it.second },
        )
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)

        r.manager.kick() // network changed: retry now, and start the backoff over
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf(400_001L, 401_001L), r.connector.dials.map { it.second }.drop(13))
    }

    @Test
    fun matchingDiscoveryEventKicksDuringBackoff() = runTest {
        val flow = MutableSharedFlow<DiscoveredService>(extraBufferCapacity = 16)
        val r = rig(listOf(macA()), MacDiscovery { flow })
        r.manager.start()
        advanceTimeBy(200_000) // deep into the 60 s cap; last dial at 172 s, next due at 232 s
        runCurrent()
        assertEquals(172_000L, r.connector.dials.last().second)

        // Another Mac's advertisement is not a wake-up.
        flow.tryEmit(service("10.0.0.21", 4000, keyB))
        runCurrent()
        assertEquals(172_000L, r.connector.dials.last().second)

        // Our Mac wakes on a new address and re-advertises: reconnect now, not at 232 s.
        r.addMac("10.0.0.30:4000", Identities.MAC_FP, backgroundScope)
        flow.tryEmit(service("10.0.0.30", 4000, keyA))
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals("10.0.0.30:4000" to 200_000L, r.connector.dials.last())
        assertEquals(4000, r.store.all().single().lastPort)
        assertEquals("10.0.0.30", r.store.all().single().lastHost)
    }

    @Test
    fun discoveryIsOneSubscriptionWhileDisconnected() = runTest {
        var subscriptions = 0
        val r = rig(listOf(macA()), MacDiscovery { kotlinx.coroutines.flow.flow { subscriptions++; kotlinx.coroutines.awaitCancellation() } })
        r.manager.start()
        advanceTimeBy(300_000)
        runCurrent()
        assertTrue(r.connector.dials.size > 5)
        assertEquals(1, subscriptions, "no fresh Bonjour poll per attempt")
    }

    @Test
    fun shortSessionsDoNotResetBackoff() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.goodbyeAfterHello = GoodbyeReason.GOODBYE_REASON_SHUTDOWN
        r.manager.start()
        advanceTimeBy(7_001)
        runCurrent()
        // Each session dies at once, so the backoff keeps growing: 1, 2, 4 s.
        assertEquals(listOf(0L, 1_000L, 3_000L, 7_000L), r.connector.dials.map { it.second })
    }

    @Test
    fun staysWithCurrentMacWhenAnotherAppears() = runTest {
        val flow = MutableSharedFlow<DiscoveredService>(extraBufferCapacity = 16)
        val r = rig(listOf(macA(host = null, port = null), macB()), MacDiscovery { flow })
        r.addMac("10.0.0.20:4000", Identities.MAC_FP, backgroundScope)
        val b = r.addMac("10.0.0.21:4000", Identities.STRANGER_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Searching, r.manager.state.value)

        // The most recently used Mac (A) is the one we look for; B showing up first is ignored.
        flow.tryEmit(service("10.0.0.21", 4000, keyB))
        runCurrent()
        assertEquals(PhoneConnectionState.Searching, r.manager.state.value)
        flow.tryEmit(service("10.0.0.20", 4000, keyA))
        runCurrent()
        val connected = assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(Identities.MAC_FP, connected.mac.id)

        // While connected, another paired Mac appearing changes nothing.
        flow.tryEmit(service("10.0.0.21", 4000, keyB))
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(Identities.MAC_FP, assertIs<PhoneConnectionState.Connected>(r.manager.state.value).mac.id)
        assertEquals(0, b.connects)
        assertEquals(listOf("10.0.0.20:4000"), r.connector.dials.map { it.first })
    }

    @Test
    fun goodbyeUnpairedForgetsMac() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)

        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_UNPAIRED) }
        runCurrent()
        assertEquals(emptyList(), r.store.all())
        assertEquals(PhoneConnectionState.NotPaired, r.manager.state.value)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(1, mac.connects, "a forgotten Mac is never dialed again")
    }

    @Test
    fun goodbyeUnpairedMovesToNextMac() = runTest {
        val r = rig(listOf(macA(), macB()))
        val a = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.addMac("10.0.0.8:4000", Identities.STRANGER_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertEquals(Identities.MAC_FP, assertIs<PhoneConnectionState.Connected>(r.manager.state.value).mac.id)
        launch { a.goodbye(GoodbyeReason.GOODBYE_REASON_UNPAIRED) }
        runCurrent()
        assertEquals(Identities.STRANGER_FP, assertIs<PhoneConnectionState.Connected>(r.manager.state.value).mac.id)
        assertEquals(listOf(Identities.STRANGER_FP), r.store.all().map { it.id })
    }

    @Test
    fun otherGoodbyeReconnectsAfterBackoff() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        assertEquals(PhoneConnectionState.Connecting(r.store.all().single()), r.manager.state.value)
        assertEquals(1, r.store.all().size, "SHUTDOWN does not unpair")
        advanceTimeBy(1_001)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(2, mac.connects)
    }

    @Test
    fun forgetSendsGoodbyeUnpairedAndRemoves() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        r.manager.forget(Identities.MAC_FP)
        runCurrent()
        val bye = mac.received.single { it.type == MessageType.GOODBYE }
        assertEquals(GoodbyeReason.GOODBYE_REASON_UNPAIRED, Goodbye.parseFrom(bye.payload).reason)
        assertEquals(emptyList(), r.store.all())
        assertEquals(PhoneConnectionState.NotPaired, r.manager.state.value)
    }

    @Test
    fun notPairedWhenStoreIsEmptyUntilKicked() = runTest {
        val r = rig(emptyList())
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotPaired, r.manager.state.value)
        r.store.save(macA())
        r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.kick()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun sendRespectsConnectionAndSharedCapabilities() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope, caps = listOf("find.v1"))
        val status = StatusUpdate.newBuilder().setBatteryPercent(50).setSignalLevel(-1).build()
        assertFalse(r.manager.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, status), "not connected")
        r.manager.start()
        runCurrent()
        assertEquals(setOf("find.v1"), assertIs<PhoneConnectionState.Connected>(r.manager.state.value).shared)
        assertFalse(r.manager.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, status), "status.v1 not shared")
        assertTrue(r.manager.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, RingState.newBuilder().setRinging(true).build()))
        runCurrent()
        assertEquals(1, mac.received.count { it.type == MessageType.FIND_STATE })
        assertEquals(0, mac.received.count { it.type == MessageType.STATUS_UPDATE })
    }

    @Test
    fun handlersReceiveIncomingMessages() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        val rings = mutableListOf<Long>()
        r.manager.on(MessageType.FIND_RING) { rings += it.id }
        r.manager.start()
        runCurrent()
        launch { mac.current!!.send(Channel.CHANNEL_FIND, MessageType.FIND_RING, RingRequest.getDefaultInstance()) }
        runCurrent()
        assertEquals(1, rings.size)
    }

    @Test
    fun protocolMismatchIsIncompatibleAndWaitsForKick() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.helloVersion = 2
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Incompatible(macA()), r.manager.state.value)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(1, mac.connects, "no retry loop against an incompatible Mac")
        mac.helloVersion = 1
        r.manager.kick()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun busyRetriesAt60s() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_BUSY
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Busy(macA()), r.manager.state.value)
        advanceTimeBy(59_999)
        runCurrent()
        assertEquals(1, mac.connects)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(2, mac.connects)
        assertEquals(PhoneConnectionState.Busy(macA()), r.manager.state.value)

        mac.errorOnHello = null
        r.manager.kick()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(3, mac.connects)
    }

    @Test
    fun notPairedEntersNotRecognizedAndStopsRetrying() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_NOT_PAIRED
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(1, mac.connects, "no retry loop against a Mac that does not know us")
        assertEquals(listOf(macA()), r.store.all(), "never forgotten automatically")
    }

    @Test
    fun refusalOnEveryAddressEntersNotRecognized() = runTest {
        val r = rig(listOf(macA()), StaticDiscovery(listOf(service("10.0.0.9", 4000, keyA))))
        r.connector.refusing += "10.0.0.5:4000"
        r.connector.refusing += "10.0.0.9:4000"
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        assertEquals(listOf("10.0.0.5:4000", "10.0.0.9:4000"), r.connector.dials.map { it.first })
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(2, r.connector.dials.size)
    }

    @Test
    fun refusalAtLastAddressStillTriesDiscoveredAddress() = runTest {
        // Something else at the old address refuses (or a stale NAT mapping): the Mac is elsewhere.
        val r = rig(listOf(macA()), StaticDiscovery(listOf(service("10.0.0.9", 4000, keyA))))
        r.connector.refusing += "10.0.0.5:4000"
        r.addMac("10.0.0.9:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun kickLeavesNotRecognized() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_NOT_PAIRED
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        mac.errorOnHello = null // e.g. the user re-paired on the Mac side
        r.manager.kick()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(2, mac.connects)
    }

    @Test
    fun stopLeavesStoppedAndClosesConnection() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        r.manager.stop()
        runCurrent()
        assertEquals(PhoneConnectionState.Stopped, r.manager.state.value)
        assertEquals(1, mac.disconnects)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals(PhoneConnectionState.Stopped, r.manager.state.value)
        assertEquals(1, mac.connects)
    }

    @Test
    fun forgetDuringConnectionSetupWins() = runTest {
        val inner = InMemoryPairedMacStore(listOf(macA()))
        lateinit var manager: ConnectionManager
        var hooked = false
        // forget() lands exactly while the connect-time save is in progress.
        val store = object : PairedMacStore by inner {
            override suspend fun save(mac: PairedMac) {
                if (!hooked) {
                    hooked = true
                    backgroundScope.launch { manager.forget(mac.id) }
                    kotlinx.coroutines.yield()
                }
                inner.save(mac)
            }
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val mac = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        advanceTimeBy(120_000)
        runCurrent()
        assertTrue(hooked)
        assertEquals(emptyList(), inner.all(), "the forgotten Mac is not brought back")
        assertEquals(PhoneConnectionState.NotPaired, manager.state.value)
        assertEquals(1, mac.received.count { it.type == MessageType.GOODBYE })
        assertEquals(1, mac.connects)
    }
}
