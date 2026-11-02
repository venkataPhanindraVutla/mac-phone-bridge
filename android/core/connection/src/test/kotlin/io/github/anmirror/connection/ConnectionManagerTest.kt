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
import kotlinx.coroutines.CompletableDeferred
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
        /** onSessionEnd calls: reason code, connected ms, liveness. */
        val ends: MutableList<Triple<String, Long, Boolean>>,
    )

    private fun TestScope.rig(
        macs: List<PairedMac>,
        discovery: MacDiscovery = StaticDiscovery(emptyList()),
        hello: () -> io.github.anmirror.protocol.v1.Hello = { phoneHello() },
    ): Rig {
        val connector = FakeConnector { testScheduler.currentTime }
        val store = InMemoryPairedMacStore(macs)
        val ends = java.util.concurrent.CopyOnWriteArrayList<Triple<String, Long, Boolean>>()
        val manager = ConnectionManager(
            backgroundScope, store, discovery, connector, hello,
            clock = { nowMs },
            uptimeMs = { testScheduler.currentTime },
            elapsedMs = { testScheduler.currentTime },
            onSessionEnd = { reason, connectedMs, liveness -> ends += Triple(reason, connectedMs, liveness) },
        )
        return Rig(manager, connector, store, ends)
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
        assertEquals(15 * 60_000, t.notRecognizedRetryMs)
        assertEquals(2, t.heuristicRefusalsForNotRecognized)
        assertEquals(45_000, t.fallbackIdleMs)
        assertEquals(60_000, t.redialNowAfterMs)
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 5_000L, 5_000L, 5_000L, 15_000L, 30_000L, 30_000L, 30_000L),
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
            val connected = withTimeout(30_000) {
                manager.state.first { it is PhoneConnectionState.Connected } as PhoneConnectionState.Connected
            }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue(elapsedMs < 30_000, "reconnect took $elapsedMs ms")
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
    fun backoffCapsAt30sAfterSixAttempts() = runTest {
        val r = rig(listOf(macA()))
        r.manager.start()
        advanceTimeBy(130_001)
        runCurrent()
        // Waits 1, 2, 4, 5, 5, 5 s, then 15 s once, then 30 s.
        assertEquals(
            listOf(0L, 1_000L, 3_000L, 7_000L, 12_000L, 17_000L, 22_000L, 37_000L, 67_000L, 97_000L, 127_000L),
            r.connector.dials.map { it.second },
        )
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)

        r.manager.kick() // network changed: retry now, and start the backoff over
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf(130_001L, 131_001L), r.connector.dials.map { it.second }.drop(11))
    }

    @Test
    fun burstOfKicksDialsOnce() = runTest {
        // Screen-on, a network change and the watchdog at once: one dial, not three.
        val r = rig(listOf(macA()))
        r.manager.start()
        advanceTimeBy(23_000) // in the 15 s wait after the dial at 22 s
        runCurrent()
        assertEquals(22_000L, r.connector.dials.last().second)
        r.manager.kick()
        r.manager.kick()
        r.manager.kick()
        runCurrent()
        advanceTimeBy(999)
        runCurrent()
        assertEquals(listOf(23_000L), r.connector.dials.map { it.second }.filter { it in 23_000L..23_999L })
        advanceTimeBy(1)
        runCurrent()
        // The kick started the backoff over: the next dial is 1 s later.
        assertEquals(listOf(23_000L, 24_000L), r.connector.dials.map { it.second }.filter { it >= 23_000L })
    }

    @Test
    fun livenessSessionAnswersMacPingsAndSendsNoTimerPings() = runTest {
        val caps = CAPS + LIVENESS_CAPABILITY
        val r = rig(listOf(macA()), hello = { phoneHello(caps) })
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope, caps)
        r.manager.start()
        runCurrent()
        assertEquals(setOf("find.v1", LIVENESS_CAPABILITY, "status.v1"), assertIs<PhoneConnectionState.Connected>(r.manager.state.value).shared)
        repeat(10) {
            advanceTimeBy(30_000)
            mac.sendPing()
            runCurrent()
        }
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(1, mac.connects)
        assertEquals(0, mac.received.count { it.type == MessageType.PING })
        assertEquals(10, mac.received.count { it.type == MessageType.PONG })

        // The Mac goes quiet: the phone's own ping after 45 s, the drop 10 s after that.
        mac.answerPings = false
        advanceTimeBy(45_001)
        runCurrent()
        assertEquals(1, mac.received.count { it.type == MessageType.PING })
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        advanceTimeBy(10_000)
        runCurrent()
        assertFalse(r.manager.state.value is PhoneConnectionState.Connected, "dropped 10 s after the fallback ping")
    }

    @Test
    fun matchingDiscoveryEventKicksDuringBackoff() = runTest {
        val flow = MutableSharedFlow<DiscoveredService>(extraBufferCapacity = 16)
        val r = rig(listOf(macA()), MacDiscovery { flow })
        r.manager.start()
        advanceTimeBy(200_000) // deep into the 30 s cap; last dial at 187 s, next due at 217 s
        runCurrent()
        assertEquals(187_000L, r.connector.dials.last().second)

        // Another Mac's advertisement is not a wake-up.
        flow.tryEmit(service("10.0.0.21", 4000, keyB))
        runCurrent()
        assertEquals(187_000L, r.connector.dials.last().second)

        // Our Mac wakes on a new address and re-advertises: reconnect now, not at 217 s.
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
        // NSD/StaticDiscovery re-report the visible Mac on every new subscription; after a
        // session that died at once that replay must not end the wait (no hot loop).
        val r = rig(listOf(macA()), StaticDiscovery(listOf(service("10.0.0.5", 4000, keyA))))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.goodbyeAfterHello = GoodbyeReason.GOODBYE_REASON_SHUTDOWN
        r.manager.start()
        advanceTimeBy(37_001)
        runCurrent()
        // Each session dies at once, so the backoff keeps its 1, 2, 4, 5, 5, 5, 15 s cadence.
        assertEquals(
            listOf(0L, 1_000L, 3_000L, 7_000L, 12_000L, 17_000L, 22_000L, 37_000L),
            r.connector.dials.map { it.second },
        )
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
    fun forgetReportsFailureWhenTheStoreRefusesAndChangesNothing() = runTest {
        val inner = InMemoryPairedMacStore(listOf(macA()))
        var refuse = true
        val store = object : PairedMacStore by inner {
            override suspend fun remove(id: String) {
                if (refuse) throw java.io.IOException("unreadable") else inner.remove(id)
            }
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        val mac = FakeMac(Identities.MAC_FP, backgroundScope, CAPS).also { connector.macs["10.0.0.5:4000"] = it }
        manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value)

        assertFalse(manager.forget(Identities.MAC_FP))
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value)
        assertEquals(0, mac.received.count { it.type == MessageType.GOODBYE })
        assertEquals(1, inner.all().size)

        refuse = false
        assertTrue(manager.forget(Identities.MAC_FP))
        runCurrent()
        assertEquals(1, mac.received.count { it.type == MessageType.GOODBYE })
        assertEquals(emptyList(), inner.all())
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
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value, "one refused attempt is not enough")
        assertEquals(listOf("10.0.0.5:4000", "10.0.0.9:4000"), r.connector.dials.map { it.first })
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        assertEquals(4, r.connector.dials.size)
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(4, r.connector.dials.size, "no retries in NotRecognized before the 15 min retry")
    }

    @Test
    fun singleHeuristicRefusalDoesNotEnterNotRecognized() = runTest {
        // One address; a reset mid-handshake (or a Mac app restart) looks like a refusal once.
        val r = rig(listOf(macA()))
        r.connector.refusing += "10.0.0.5:4000"
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)
        r.connector.refusing.clear()
        r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        advanceTimeBy(1_000)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun twoConsecutiveHeuristicRefusalsEnterNotRecognized() = runTest {
        val r = rig(listOf(macA()))
        r.connector.refusing += "10.0.0.5:4000"
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        assertEquals(listOf(0L, 1_000L), r.connector.dials.map { it.second })
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(2, r.connector.dials.size)
    }

    @Test
    fun heuristicRefusalsMustBeConsecutive() = runTest {
        val r = rig(listOf(macA()))
        r.connector.refusing += "10.0.0.5:4000"
        r.manager.start()
        runCurrent() // refused (1)
        r.connector.refusing.clear() // next attempt: plain unreachable (nothing answers)
        advanceTimeBy(1_000)
        runCurrent()
        r.connector.refusing += "10.0.0.5:4000"
        advanceTimeBy(2_000)
        runCurrent() // refused again, but not consecutively
        assertEquals(3, r.connector.dials.size)
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)
    }

    @Test
    fun tlsErrorAfterHandshakeIsHeuristic() = runTest {
        // TLS 1.3: a refusal (or a reset reported as SSLException) on the first read.
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.tlsErrorAfterHandshake = true
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Unreachable(macA()), r.manager.state.value)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        assertEquals(2, mac.connects)
    }

    @Test
    fun explicitNotPairedEntersImmediately() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_NOT_PAIRED
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        assertEquals(1, mac.connects, "an authenticated NOT_PAIRED needs no second attempt")
    }

    @Test
    fun notRecognizedRetriesAfter15Minutes() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_NOT_PAIRED
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotRecognized(macA()), r.manager.state.value)
        advanceTimeBy(15 * 60_000 - 1)
        runCurrent()
        assertEquals(1, mac.connects)
        mac.errorOnHello = null // re-paired meanwhile
        advanceTimeBy(2)
        runCurrent()
        assertEquals(2, mac.connects)
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun kickRestartsFinishedDiscovery() = runTest {
        var subscriptions = 0
        val r = rig(listOf(macA()), MacDiscovery { kotlinx.coroutines.flow.flow<DiscoveredService> { subscriptions++ } })
        r.manager.start()
        advanceTimeBy(100_000)
        runCurrent()
        assertEquals(1, subscriptions, "a finished subscription is not restarted per attempt")
        r.manager.kick()
        runCurrent()
        assertEquals(2, subscriptions, "a kick restarts it")
    }

    @Test
    fun incompatibleStopsDiscovery() = runTest {
        var active = 0
        val discovery = MacDiscovery {
            kotlinx.coroutines.flow.flow<DiscoveredService> {
                active++
                try {
                    kotlinx.coroutines.awaitCancellation()
                } finally {
                    active--
                }
            }
        }
        val r = rig(listOf(macA()), discovery)
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.helloVersion = 2
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Incompatible(macA()), r.manager.state.value)
        assertEquals(0, active, "no Bonjour browsing while waiting for an update")
    }

    @Test
    fun busyStopsDiscovery() = runTest {
        // R37 #8: waiting out BUSY must not keep the Bonjour browser (and the radio) busy.
        var active = 0
        val discovery = MacDiscovery {
            kotlinx.coroutines.flow.flow<DiscoveredService> {
                active++
                try {
                    kotlinx.coroutines.awaitCancellation()
                } finally {
                    active--
                }
            }
        }
        val r = rig(listOf(macA()), discovery)
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        mac.errorOnHello = ErrorCode.ERROR_CODE_BUSY
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.Busy(macA()), r.manager.state.value)
        assertEquals(0, active, "no Bonjour browsing while the Mac serves another phone")
        mac.errorOnHello = null
        advanceTimeBy(60_001)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
    }

    @Test
    fun storeSaveFailureStillConnectsAndKeepsRunning() = runTest {
        // R37 #6: a store write that throws (Keystore trouble) must not end the session or the loop.
        val inner = InMemoryPairedMacStore(listOf(macA()))
        val store = object : PairedMacStore by inner {
            override suspend fun save(mac: PairedMac) = throw IllegalStateException("keystore unavailable")
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val mac = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value)
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        advanceTimeBy(1_001)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value, "the manager is still running")
        assertEquals(2, mac.connects)
    }

    @Test
    fun loopSurvivesUnexpectedException() = runTest {
        // R37 #6: an unexpected error restarts the loop after a backoff instead of ending it.
        val inner = InMemoryPairedMacStore(listOf(macA()))
        var failures = 1
        val store = object : PairedMacStore by inner {
            override suspend fun all(): List<PairedMac> {
                if (failures > 0) {
                    failures--
                    throw IllegalStateException("store read failed")
                }
                return inner.all()
            }
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val mac = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertEquals(0, mac.connects)
        advanceTimeBy(1_001)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value)
        assertEquals(1, mac.connects)
    }

    @Test
    fun stopStillCancelsTheLoop() = runTest {
        // Cancellation is not an "unexpected exception": stop() ends the loop for good.
        val r = rig(listOf(macA()))
        r.manager.start()
        runCurrent()
        r.manager.stop()
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(PhoneConnectionState.Stopped, r.manager.state.value)
        assertTrue(r.connector.dials.all { it.second == 0L }, "no dials after stop")
    }

    @Test
    fun forgetKickIsNotSwallowed() = runTest {
        // forget() lands right after the loop read the store: its kick must still wake the wait.
        val inner = InMemoryPairedMacStore(listOf(macA()))
        lateinit var manager: ConnectionManager
        var hooked = false
        val store = object : PairedMacStore by inner {
            override suspend fun all(): List<PairedMac> {
                val snapshot = inner.all()
                if (!hooked && snapshot.isNotEmpty()) {
                    hooked = true
                    backgroundScope.launch { manager.forget(snapshot.first().id) }
                    kotlinx.coroutines.yield()
                }
                return snapshot
            }
        }
        val connector = FakeConnector { testScheduler.currentTime } // nothing answers
        manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertTrue(hooked)
        assertEquals(PhoneConnectionState.NotPaired, manager.state.value, "not stuck in Unreachable for a forgotten Mac")
        assertEquals(0L, testScheduler.currentTime)
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

    @Test
    fun adoptedPairingChannelSaysHelloWithoutDialing() = runTest {
        // SPEC 5.3 step 6: after pairing.complete the phone says hello on the same connection.
        val r = rig(emptyList())
        val fake = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertEquals(PhoneConnectionState.NotPaired, r.manager.state.value)
        r.store.save(macA())
        r.manager.adopt(fake.accept("10.0.0.5", 4000))
        runCurrent()
        val state = assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(Identities.MAC_FP, state.mac.id)
        assertEquals(emptyList(), r.connector.dials, "the pairing connection is used, not a new one")
        assertEquals(1, fake.connects)
        assertEquals(1, fake.received.count { it.type == MessageType.HELLO })
    }

    @Test
    fun adoptedChannelWinsOverAStaleStoreRead() = runTest {
        // R29: the loop read the store before B was saved and dials A. A's setup must yield to
        // B's adopted channel: no session with A, no save, no goodbye; B connects on its channel.
        val a0 = macA(at = 200)
        val inner = InMemoryPairedMacStore(listOf(a0, macB(at = 300)))
        var stale = true
        val store = object : PairedMacStore by inner {
            override suspend fun all(): List<PairedMac> =
                if (stale) inner.all().filter { it.id == a0.id }.also { stale = false } else inner.all()
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val a = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        val b = FakeMac(Identities.STRANGER_FP, backgroundScope)
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.adopt(b.accept("10.0.0.8", 4000))
        manager.start()
        runCurrent()
        val state = assertIs<PhoneConnectionState.Connected>(manager.state.value)
        assertEquals(Identities.STRANGER_FP, state.mac.id, "B is connected")
        assertEquals(1, b.received.count { it.type == MessageType.HELLO }, "on its adopted channel")
        assertEquals(1, b.connects)
        assertEquals(0, a.received.count { it.type == MessageType.GOODBYE }, "A is closed without a goodbye")
        assertEquals(200, inner.all().first { it.id == a0.id }.lastConnectedAt, "A's lastConnectedAt is not saved")
    }

    @Test
    fun adoptWhileConnectedToAnotherMacSwitchesOnTheAdoptedChannel() = runTest {
        // R28 M-1: connected to A, then B is paired: B on the adopted channel at once, no dial.
        val r = rig(listOf(macA()))
        val a = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        val dialsBefore = r.connector.dials.size
        r.store.save(macB(at = nowMs + 1))
        val b = FakeMac(Identities.STRANGER_FP, backgroundScope)
        r.manager.adopt(b.accept("10.0.0.8", 4000))
        runCurrent() // no virtual time passes: the kick must survive the closing session
        val state = assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(Identities.STRANGER_FP, state.mac.id)
        assertEquals(dialsBefore, r.connector.dials.size, "no extra dial")
        assertEquals(1, b.received.count { it.type == MessageType.HELLO })
        // R29: A is told the phone is switching, not that it was unpaired.
        val bye = a.received.filter { it.type == MessageType.GOODBYE }.map { Goodbye.parseFrom(it.payload).reason }
        assertEquals(listOf(GoodbyeReason.GOODBYE_REASON_SWITCHING_MAC), bye)
    }

    @Test
    fun aWaitingAdoptedChannelPicksItsMacEvenIfNotTheMostRecent() = runTest {
        // Equal or older lastConnectedAt (clock granularity) must not make A win forever.
        val r = rig(listOf(macA(at = 500), macB(at = 100)))
        val a = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        val b = FakeMac(Identities.STRANGER_FP, backgroundScope)
        r.manager.adopt(b.accept("10.0.0.8", 4000))
        r.manager.start()
        runCurrent()
        assertEquals(Identities.STRANGER_FP, assertIs<PhoneConnectionState.Connected>(r.manager.state.value).mac.id)
        assertEquals(0, a.connects, "A is not dialed")
    }

    @Test
    fun leftoverAdoptedChannelForTheSameMacIsClosedWhenASessionStarts() = runTest {
        // R28 M-1: B dialed between save and adopt; the late adopted channel must not linger.
        val store = InMemoryPairedMacStore(listOf(macA()))
        val fake = FakeConnector { testScheduler.currentTime }
        val a = FakeMac(Identities.MAC_FP, backgroundScope).also { fake.macs["10.0.0.5:4000"] = it }
        lateinit var manager: ConnectionManager
        var late: ControlChannel? = null
        val connector = MacConnector { hosts, port, fp ->
            fake.connect(hosts, port, fp).also {
                if (late == null) late = a.accept("10.0.0.5", 4000).also { manager.adopt(it) }
            }
        }
        manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value)
        assertTrue(checkNotNull(late).isClosed, "the leftover adopted channel is closed")
    }

    @Test
    fun adoptedChannelThatFailsHelloFallsBackToDialing() = runTest {
        val r = rig(emptyList())
        val fake = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        r.store.save(macA(host = "10.0.0.5", port = 4000))
        val channel = fake.accept("10.0.0.5", 4000)
        channel.close() // the Mac hung up after pairing.complete
        r.manager.adopt(channel)
        runCurrent()
        advanceTimeBy(1_500)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertTrue(r.connector.dials.isNotEmpty(), "redials once the adopted connection is gone")
    }

    @Test
    fun adoptDuringSetupOfAnotherMacEndsThatSessionWithSwitchingMac() = runTest {
        // R30: adopt(B) lands while A's setup is suspended in store.save (current not yet set).
        val inner = InMemoryPairedMacStore(listOf(macA()))
        val latch = CompletableDeferred<Unit>()
        var saving = false
        val store = object : PairedMacStore by inner {
            override suspend fun save(mac: PairedMac) {
                if (mac.id == Identities.MAC_FP && !latch.isCompleted) {
                    saving = true
                    latch.await()
                }
                inner.save(mac)
            }
        }
        val connector = FakeConnector { testScheduler.currentTime }
        val a = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        val b = FakeMac(Identities.STRANGER_FP, backgroundScope)
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertTrue(saving, "A's setup is inside store.save")
        inner.save(macB(at = nowMs + 1))
        manager.adopt(b.accept("10.0.0.8", 4000))
        latch.complete(Unit)
        runCurrent()
        val state = assertIs<PhoneConnectionState.Connected>(manager.state.value)
        assertEquals(Identities.STRANGER_FP, state.mac.id, "the phone ends up on B")
        assertEquals(1, b.received.count { it.type == MessageType.HELLO }, "on B's adopted channel")
        assertEquals(1, b.connects)
        val bye = a.received.filter { it.type == MessageType.GOODBYE }.map { Goodbye.parseFrom(it.payload).reason }
        assertEquals(listOf(GoodbyeReason.GOODBYE_REASON_SWITCHING_MAC), bye, "A is told once")
    }

    @Test
    fun forgettingTheAdoptedMacClosesItsChannel() = runTest {
        // R30: adopt B, then forget(B) before the loop uses it: no channel left in the slot.
        val r = rig(listOf(macA(), macB(at = nowMs + 1)))
        val b = FakeMac(Identities.STRANGER_FP, backgroundScope)
        val channel = b.accept("10.0.0.8", 4000)
        r.manager.adopt(channel)
        r.manager.forget(Identities.STRANGER_FP)
        assertTrue(channel.isClosed, "the forgotten Mac's channel is closed")
        assertFalse(r.manager.hasAdoptedChannel(), "the slot is empty")
    }

    @Test
    fun adoptedChannelOfAMacNoLongerStoredIsClosedNotKept() = runTest {
        // R30: connect() must not put back a channel whose Mac is not paired.
        val r = rig(listOf(macA()))
        r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        val stranger = FakeMac(Identities.STRANGER_FP, backgroundScope)
        val channel = stranger.accept("10.0.0.9", 4000)
        r.manager.adopt(channel)
        r.manager.start()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertTrue(channel.isClosed)
        assertFalse(r.manager.hasAdoptedChannel())
    }

    // MARK: final fix wave

    /** A store whose `all()` reads as empty (unreadable) on the given 1-based calls only. */
    private class FlakyReads(private val inner: PairedMacStore, private val emptyOn: Set<Int>) : PairedMacStore by inner {
        var calls = 0
        override suspend fun all(): List<PairedMac> = if (++calls in emptyOn) emptyList() else inner.all()
    }

    @Test
    fun unreadableStoreAfterHelloSendsNoGoodbye() = runTest {
        // I1: a Keystore hiccup right at setup (the 2nd read) must not tell the Mac to forget us.
        val inner = InMemoryPairedMacStore(listOf(macA()))
        val store = FlakyReads(inner, emptyOn = setOf(2))
        val connector = FakeConnector { testScheduler.currentTime }
        val mac = FakeMac(Identities.MAC_FP, backgroundScope).also { connector.macs["10.0.0.5:4000"] = it }
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertTrue(store.calls >= 2)
        assertEquals(0, mac.received.count { it.type == MessageType.GOODBYE }, "no goodbye UNPAIRED on an unreadable store")
        assertEquals(1, inner.all().size, "the pairing is kept")
        assertFalse(manager.state.value is PhoneConnectionState.Connected)
        advanceTimeBy(1_001)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(manager.state.value, "retried after the backoff")
        assertEquals(2, mac.connects)
        assertEquals(0, mac.received.count { it.type == MessageType.GOODBYE })
    }

    @Test
    fun forgottenMacStillGetsUnpairedGoodbye() = runTest {
        // I1: forget() that lands while the phone dials still ends with goodbye UNPAIRED.
        val store = InMemoryPairedMacStore(listOf(macA()))
        lateinit var manager: ConnectionManager
        val fakes = FakeConnector { testScheduler.currentTime }
        val mac = FakeMac(Identities.MAC_FP, backgroundScope).also { fakes.macs["10.0.0.5:4000"] = it }
        var forgot = false
        val connector = MacConnector { hosts, port, fp ->
            val channel = fakes.connect(hosts, port, fp)
            forgot = manager.forget(Identities.MAC_FP)
            channel
        }
        manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { phoneHello() }, clock = { nowMs })
        manager.start()
        runCurrent()
        assertTrue(forgot)
        val bye = mac.received.filter { it.type == MessageType.GOODBYE }.map { Goodbye.parseFrom(it.payload).reason }
        assertEquals(listOf(GoodbyeReason.GOODBYE_REASON_UNPAIRED), bye)
        assertEquals(emptyList(), store.all())
        assertEquals(PhoneConnectionState.NotPaired, manager.state.value)
    }

    @Test
    fun maturedSessionEndRedialsImmediately() = runTest {
        // I2(b): a session that lived 60 s and ends by goodbye or EOF dials again at once.
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        advanceTimeBy(61_000)
        runCurrent()
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value, "redialed without waiting")
        assertEquals(listOf(0L, 61_000L), r.connector.dials.map { it.second })

        // EOF (the Mac closed the socket) after another 60 s: the same.
        advanceTimeBy(61_000)
        runCurrent()
        checkNotNull(mac.current).close()
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        assertEquals(listOf(0L, 61_000L, 122_000L), r.connector.dials.map { it.second })

        // If that one dial fails, the usual backoff follows: 1 s, then 2 s.
        advanceTimeBy(61_000)
        runCurrent()
        r.connector.macs.clear()
        checkNotNull(mac.current).close()
        runCurrent()
        advanceTimeBy(3_001)
        runCurrent()
        assertEquals(listOf(183_000L, 184_000L, 186_000L), r.connector.dials.map { it.second }.drop(3))
    }

    @Test
    fun shortSessionEndUsesBackoff() = runTest {
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        advanceTimeBy(59_000)
        runCurrent()
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        assertEquals(listOf(0L), r.connector.dials.map { it.second }, "no immediate dial before 60 s")
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(listOf(0L, 60_000L), r.connector.dials.map { it.second })
    }

    @Test
    fun pongTimeoutIsNotRedialedImmediately() = runTest {
        // A dead link (no pong) is not a closed connection: it keeps the backoff, even after 60 s.
        val r = rig(listOf(macA()))
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope)
        r.manager.start()
        runCurrent()
        advanceTimeBy(61_000)
        mac.answerPings = false
        advanceTimeBy(39_500) // ping at 90 s, deadline 100 s; the backoff's dial would be at 101 s
        runCurrent()
        assertFalse(r.manager.state.value is PhoneConnectionState.Connected)
        assertEquals(listOf(0L), r.connector.dials.map { it.second })
        assertEquals("PING_TIMEOUT", r.ends.single().first)
    }

    @Test
    fun sessionEndIsReportedWithReasonDurationAndMode() = runTest {
        val caps = CAPS + LIVENESS_CAPABILITY
        val r = rig(listOf(macA()), hello = { phoneHello(caps) })
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope, caps)
        r.manager.start()
        runCurrent()
        advanceTimeBy(5_000)
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        assertEquals(listOf(Triple("GOODBYE_SHUTDOWN", 5_000L, true)), r.ends.toList())

        advanceTimeBy(1_000) // the backoff; connected again
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        r.manager.stop()
        runCurrent()
        assertEquals("CANCELLED", r.ends.last().first)
        assertEquals(2, r.ends.size)
    }

    @Test
    fun livenessSessionMaturesOnFirstAnsweredMacPing() = runTest {
        // M1: a locked phone's session lives on wall time; one answered Mac ping proves the link.
        val caps = CAPS + LIVENESS_CAPABILITY
        val r = rig(listOf(macA()), hello = { phoneHello(caps) })
        r.manager.start()
        advanceTimeBy(6_000) // dials at 0, 1, 3 s; the next at 7 s
        runCurrent()
        val mac = r.addMac("10.0.0.5:4000", Identities.MAC_FP, backgroundScope, caps)
        advanceTimeBy(1_000)
        runCurrent()
        assertIs<PhoneConnectionState.Connected>(r.manager.state.value)
        advanceTimeBy(1_000)
        mac.sendPing()
        runCurrent()
        advanceTimeBy(2_000)
        launch { mac.goodbye(GoodbyeReason.GOODBYE_REASON_SHUTDOWN) }
        runCurrent()
        // Matured: the backoff starts over at 1 s (not attempt 3's 5 s).
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(listOf(0L, 1_000L, 3_000L, 7_000L, 11_000L), r.connector.dials.map { it.second })
    }
}
