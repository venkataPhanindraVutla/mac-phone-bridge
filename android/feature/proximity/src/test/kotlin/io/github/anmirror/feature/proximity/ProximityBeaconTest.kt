package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.protocol.PairingCrypto
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ProximityBeaconTest {
    /** Records each start's service data and each stop, in order. */
    private class FakeAdvertiser(var state: AdvertiserState = AdvertiserState.READY) : BleAdvertiser {
        val events = mutableListOf<String>()
        val started = mutableListOf<ByteArray>()
        var failWith: Int? = null
        var lastFailure: ((Int) -> Unit)? = null

        override fun state() = state

        override fun start(serviceData: ByteArray, onFailure: (Int) -> Unit) {
            events += "start"
            started += serviceData
            lastFailure = onFailure
            failWith?.let(onFailure)
        }

        override fun stop() {
            events += "stop"
        }
    }

    private val phoneFp = ByteArray(32) { (it + 1).toByte() }

    private fun mac(id: String, key: Byte, lastConnectedAt: Long = 0) = PairedMac(
        id = id, name = "Mac $id", fingerprintHex = "00", discoveryKey = ByteArray(32) { key },
        lastHost = null, lastPort = null, lastConnectedAt = lastConnectedAt,
    )

    private val macA = mac("a", 1)
    private val macB = mac("b", 2)

    /** 100 s into an epoch. */
    private val base = 1_800_000L * 900_000L + 100_000L

    private fun TestScope.beacon(advertiser: FakeAdvertiser) =
        ProximityBeacon(advertiser, phoneFp, backgroundScope, clock = { base + testScheduler.currentTime })

    private fun idAt(mac: PairedMac, nowMs: Long) =
        PairingCrypto.bleId(mac.discoveryKey, phoneFp, PairingCrypto.epochOf(nowMs / 1000))

    @Test fun advertisesBleIdForPickedMac() = runTest {
        val advertiser = FakeAdvertiser()
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        assertEquals(listOf("start"), advertiser.events)
        assertContentEquals(idAt(macA, base), advertiser.started.single())
        assertEquals(8, advertiser.started.single().size)
        assertTrue(beacon.advertising.value)
    }

    @Test fun restartsWithNewIdAtEpochBoundary() = runTest {
        val advertiser = FakeAdvertiser()
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        // The boundary is 800 s away; the restart comes 1 s after it.
        advanceTimeBy(800_000L + 999L)
        runCurrent()
        assertEquals(listOf("start"), advertiser.events)
        advanceTimeBy(2L)
        runCurrent()
        assertEquals(listOf("start", "stop", "start"), advertiser.events)
        val next = base + 801_000L
        assertContentEquals(idAt(macA, next), advertiser.started[1])
        assertFalse(advertiser.started[0].contentEquals(advertiser.started[1]))
        assertTrue(beacon.advertising.value)
        // And again a full epoch later.
        advanceTimeBy(900_000L)
        runCurrent()
        assertEquals(3, advertiser.started.size)
        assertContentEquals(idAt(macA, next + 900_000L), advertiser.started[2])
    }

    @Test fun switchOffStopsAdvertising() = runTest {
        val advertiser = FakeAdvertiser()
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        beacon.update(active = false, mac = macA)
        runCurrent()
        assertEquals(listOf("start", "stop"), advertiser.events)
        assertFalse(beacon.advertising.value)
        // No restart at the next boundary either.
        advanceTimeBy(2 * 900_000L)
        runCurrent()
        assertEquals(listOf("start", "stop"), advertiser.events)
    }

    @Test fun bluetoothOffDoesNotStart() = runTest {
        val advertiser = FakeAdvertiser(AdvertiserState.BLUETOOTH_OFF)
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        assertEquals(emptyList(), advertiser.events)
        assertFalse(beacon.advertising.value)
        advertiser.state = AdvertiserState.UNSUPPORTED
        beacon.update(active = true, mac = macA)
        runCurrent()
        assertEquals(emptyList(), advertiser.events)
        // Bluetooth back on: the service calls update again.
        advertiser.state = AdvertiserState.READY
        beacon.update(active = true, mac = macA)
        runCurrent()
        assertEquals(listOf("start"), advertiser.events)
    }

    @Test fun noMacNoAdvert() = runTest {
        val advertiser = FakeAdvertiser()
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = null)
        runCurrent()
        assertEquals(emptyList(), advertiser.events)
        beacon.update(active = true, mac = macA)
        runCurrent()
        beacon.update(active = true, mac = null)
        runCurrent()
        assertEquals(listOf("start", "stop"), advertiser.events)
        assertFalse(beacon.advertising.value)
    }

    @Test fun macChangeRestartsAtOnce() = runTest {
        val advertiser = FakeAdvertiser()
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        advanceTimeBy(10_000L)
        beacon.update(active = true, mac = macB)
        runCurrent()
        assertEquals(listOf("start", "stop", "start"), advertiser.events)
        assertContentEquals(idAt(macB, base + 10_000L), advertiser.started[1])
        assertTrue(beacon.advertising.value)
        // Only one timer runs: one restart at the boundary, not two.
        advanceTimeBy(800_000L)
        runCurrent()
        assertEquals(listOf("start", "stop", "start", "stop", "start"), advertiser.events)
    }

    @Test fun startFailureClearsAdvertising() = runTest {
        val advertiser = FakeAdvertiser().apply { failWith = 1 }
        val beacon = beacon(advertiser)
        beacon.update(active = true, mac = macA)
        runCurrent()
        assertFalse(beacon.advertising.value)
        // A late failure of an advertisement already replaced is ignored.
        advertiser.failWith = null
        val stale = advertiser.lastFailure!!
        beacon.update(active = true, mac = macB)
        runCurrent()
        assertTrue(beacon.advertising.value)
        stale(1)
        assertTrue(beacon.advertising.value)
    }

    @Test fun msUntilNextEpochAtBoundaries() {
        assertEquals(900_000L, msUntilNextEpoch(0L))
        assertEquals(1L, msUntilNextEpoch(899_999L))
        assertEquals(900_000L, msUntilNextEpoch(900_000L))
    }
}
