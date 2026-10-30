package io.github.anmirror.feature.status

import io.github.anmirror.protocol.v1.NetworkKind
import io.github.anmirror.protocol.v1.StatusUpdate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class StatusPublisherTest {
    private fun status(battery: Int, charging: Boolean = false) =
        PhoneStatus(battery, charging, signalLevel = 3, network = NetworkKind.NETWORK_KIND_WIFI)

    private class Rig(scope: TestScope, initial: PhoneStatus) {
        val source = MutableStateFlow(initial)
        val connected = MutableStateFlow(false)
        val sent = mutableListOf<Pair<Long, StatusUpdate>>()
        val publisher = StatusPublisher(
            source = source,
            connected = connected,
            send = { sent += scope.currentTime to it },
            minIntervalMs = 5_000,
        )
    }

    @Test
    fun backgroundRestrictedGoesOnTheWire() {
        assertTrue(status(50).copy(backgroundRestricted = true).toProto().backgroundRestricted)
        assertFalse(status(50).toProto().backgroundRestricted, "false unless set")
    }

    @Test
    fun sendsImmediatelyOnConnect() = runTest {
        val rig = Rig(this, status(82))
        rig.publisher.launchIn(backgroundScope)
        runCurrent()
        assertEquals(0, rig.sent.size, "nothing while disconnected")

        rig.connected.value = true
        runCurrent()
        assertEquals(1, rig.sent.size)
        val update = rig.sent.single().second
        assertEquals(82, update.batteryPercent)
        assertEquals(3, update.signalLevel)
        assertEquals(NetworkKind.NETWORK_KIND_WIFI, update.network)
    }

    @Test
    fun dropsDuplicateValues() = runTest {
        val rig = Rig(this, status(82))
        rig.connected.value = true
        rig.publisher.launchIn(backgroundScope)
        runCurrent()
        rig.source.value = status(82).copy() // equal value
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals(1, rig.sent.size)
    }

    @Test
    fun throttlesToOnePer5sAndSendsLatest() = runTest {
        val rig = Rig(this, status(80))
        rig.connected.value = true
        rig.publisher.launchIn(backgroundScope)
        runCurrent()
        assertEquals(1, rig.sent.size)

        advanceTimeBy(300); rig.source.value = status(79)
        advanceTimeBy(300); rig.source.value = status(78)
        advanceTimeBy(300); rig.source.value = status(77)
        runCurrent()
        assertEquals(1, rig.sent.size, "throttled inside the window")

        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(2, rig.sent.size)
        assertEquals(5_000L, rig.sent[1].first)
        assertEquals(77, rig.sent[1].second.batteryPercent)
    }

    @Test
    fun resendsAfterReconnect() = runTest {
        val rig = Rig(this, status(60))
        rig.connected.value = true
        rig.publisher.launchIn(backgroundScope)
        runCurrent()
        rig.connected.value = false
        runCurrent()
        rig.connected.value = true
        runCurrent()
        assertEquals(2, rig.sent.size)
        assertEquals(rig.sent[0].second, rig.sent[1].second)
    }
}
