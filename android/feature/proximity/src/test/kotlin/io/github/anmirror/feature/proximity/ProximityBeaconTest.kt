package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.protocol.PairingCrypto
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProximityBeaconTest {
    /** One advertising set: the data it was started with, then each setData. */
    private class FakeSet(first: ByteArray, val events: (AdvertiserEvent) -> Unit) : AdvertisingSlot {
        val data = mutableListOf(first)
        var stopped = false
        override fun setData(serviceData: ByteArray) { data += serviceData }
        override fun stop() { stopped = true }
    }

    private class FakeAdvertiser(var state: AdvertiserState = AdvertiserState.READY) : BleAdvertiser {
        val sets = mutableListOf<FakeSet>()
        /** A failure reported before start returns (no permission, Bluetooth gone). */
        var failNow: Int? = null
        override fun state() = state
        override fun start(serviceData: ByteArray, events: (AdvertiserEvent) -> Unit): AdvertisingSlot {
            val set = FakeSet(serviceData, events)
            sets += set
            failNow?.let { events(AdvertiserEvent.Failed(it)) }
            return set
        }
        fun live() = sets.filter { !it.stopped }
    }

    /** The pending wake, and which kind of alarm it was set with. */
    private class FakeAlarm : WakeAlarm {
        var at: Long? = null
        var kind: WakeKind? = null
        override fun set(wake: Wake) {
            at = wake.atMs
            kind = wake.kind
        }
        override fun cancel() {
            at = null
            kind = null
        }
    }

    private val phoneFp = ByteArray(32) { (it + 1).toByte() }

    private fun mac(id: String, key: Byte) = PairedMac(
        id = id, name = "Mac $id", fingerprintHex = "00", discoveryKey = ByteArray(32) { key },
        lastHost = null, lastPort = null, lastConnectedAt = 0,
    )

    private val macA = mac("a", 1)
    private val macB = mac("b", 2)
    private val macC = mac("c", 3)

    /** The start of some epoch; the tests begin 100 s into it. */
    private val boundary = 1_800_000L * 900_000L
    private var now = boundary + 100_000L

    private val advertiser = FakeAdvertiser()
    private val alarm = FakeAlarm()
    private val beacon = ProximityBeacon(advertiser, alarm, phoneFp = { phoneFp }, clock = { now })

    private fun idAt(mac: PairedMac, nowMs: Long) =
        PairingCrypto.bleId(mac.discoveryKey, phoneFp, PairingCrypto.epochOf(nowMs / 1000))

    @Test fun advertisesBleIdForPickedMac() {
        beacon.update(active = true, macs = listOf(macA))
        val set = advertiser.sets.single()
        assertContentEquals(idAt(macA, now), set.data.single())
        assertEquals(8, set.data.single().size)
        assertEquals(mapOf("a" to BeaconState.Starting), beacon.states.value)
        set.events(AdvertiserEvent.Started)
        assertEquals(mapOf("a" to BeaconState.On), beacon.states.value)
        assertEquals(emptySet(), beacon.faulted.value)
    }

    @Test fun rotatesWithSetDataAtEpochBoundary() {
        beacon.update(active = true, macs = listOf(macA))
        val set = advertiser.sets.single()
        set.events(AdvertiserEvent.Started)
        // A wall-clock alarm 1 s past the boundary.
        assertEquals(boundary + 901_000L, alarm.at)
        now = boundary + 901_000L
        beacon.onClockCheck()
        // The same set, new data: the controller slot is never released.
        assertEquals(1, advertiser.sets.size)
        assertFalse(set.stopped)
        assertEquals(2, set.data.size)
        assertContentEquals(idAt(macA, now), set.data[1])
        assertFalse(set.data[0].contentEquals(set.data[1]))
        // Until the stack confirms the new data, the next wake is its 5 s deadline.
        assertEquals(now + 5_000L, alarm.at)
        set.events(AdvertiserEvent.DataSet)
        assertEquals(boundary + 2 * 900_000L + 1_000L, alarm.at)
        assertEquals(BeaconState.On, beacon.states.value["a"])
        assertEquals(emptySet(), beacon.faulted.value)
    }

    @Test fun lateAlarmRotatesToTheEpochNow() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets.single().events(AdvertiserEvent.Started)
        // The CPU slept through two boundaries; the alarm fires late.
        now = boundary + 2 * 900_000L + 420_000L
        beacon.onClockCheck()
        val set = advertiser.sets.single()
        assertEquals(2, set.data.size)
        assertContentEquals(idAt(macA, now), set.data[1])
        set.events(AdvertiserEvent.DataSet)
        assertEquals(boundary + 3 * 900_000L + 1_000L, alarm.at)
    }

    @Test fun clockCheckWithinTheEpochChangesNothing() {
        beacon.update(active = true, macs = listOf(macA))
        now += 60_000L // screen on, a minute later
        beacon.onClockCheck()
        assertEquals(1, advertiser.sets.single().data.size)
    }

    @Test fun timeJumpRotatesAtOnce() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets.single().events(AdvertiserEvent.Started)
        now -= 3_600_000L // the user set the clock back an hour
        beacon.onClockCheck()
        val set = advertiser.sets.single()
        assertContentEquals(idAt(macA, now), set.data[1])
        set.events(AdvertiserEvent.DataSet)
        assertEquals(RotationSchedule.nextRotationAt(now), alarm.at)
    }

    @Test fun switchOffStopsAdvertising() {
        beacon.update(active = true, macs = listOf(macA, macB))
        beacon.update(active = false, macs = listOf(macA, macB))
        assertTrue(advertiser.sets.all { it.stopped })
        assertEquals(emptyMap(), beacon.states.value)
        assertNull(alarm.at)
    }

    @Test fun bluetoothOffDoesNotStart() {
        advertiser.state = AdvertiserState.BLUETOOTH_OFF
        beacon.update(active = true, macs = listOf(macA))
        assertEquals(emptyList(), advertiser.sets)
        advertiser.state = AdvertiserState.UNSUPPORTED
        beacon.update(active = true, macs = listOf(macA))
        assertEquals(emptyList(), advertiser.sets)
        assertNull(alarm.at)
        // Bluetooth back on: the service calls update again.
        advertiser.state = AdvertiserState.READY
        beacon.update(active = true, macs = listOf(macA))
        assertEquals(1, advertiser.sets.size)
        // Bluetooth off again stops it.
        advertiser.state = AdvertiserState.BLUETOOTH_OFF
        beacon.update(active = true, macs = listOf(macA))
        assertTrue(advertiser.sets.single().stopped)
    }

    @Test fun noMacNoAdvert() {
        beacon.update(active = true, macs = emptyList())
        assertEquals(emptyList(), advertiser.sets)
        assertNull(alarm.at)
    }

    @Test fun oneSetPerMacUpToThree() {
        val macD = mac("d", 4)
        beacon.update(active = true, macs = listOf(macB, macA, macC, macD))
        assertEquals(3, advertiser.sets.size)
        // Started in priority order, each with its own Mac's ID.
        assertContentEquals(idAt(macB, now), advertiser.sets[0].data[0])
        assertContentEquals(idAt(macA, now), advertiser.sets[1].data[0])
        assertContentEquals(idAt(macC, now), advertiser.sets[2].data[0])
        advertiser.sets.forEach { it.events(AdvertiserEvent.Started) }
        // Rotation updates every set.
        now = boundary + 901_000L
        beacon.onClockCheck()
        assertTrue(advertiser.sets.all { it.data.size == 2 })
        assertContentEquals(idAt(macC, now), advertiser.sets[2].data[1])
    }

    @Test fun forgettingAMacStopsOnlyItsSet() {
        beacon.update(active = true, macs = listOf(macA, macB))
        val (setA, setB) = advertiser.sets
        beacon.update(active = true, macs = listOf(macB))
        assertTrue(setA.stopped)
        assertFalse(setB.stopped)
        assertEquals(setOf("b"), beacon.states.value.keys)
        // A reorder (another Mac connects) restarts nothing.
        beacon.update(active = true, macs = listOf(macC, macB))
        assertFalse(setB.stopped)
        assertEquals(3, advertiser.sets.size)
    }

    @Test fun tooManyAdvertisersKeepsTheStartedOnes() {
        beacon.update(active = true, macs = listOf(macA, macB, macC))
        val (setA, setB, setC) = advertiser.sets
        setA.events(AdvertiserEvent.Started)
        setB.events(AdvertiserEvent.Started)
        setC.events(AdvertiserEvent.Failed(ADVERTISE_FAILED_TOO_MANY_ADVERTISERS))
        assertEquals(BeaconState.On, beacon.states.value["a"])
        assertEquals(BeaconState.On, beacon.states.value["b"])
        assertEquals(BeaconState.Failed(ADVERTISE_FAILED_TOO_MANY_ADVERTISERS), beacon.states.value["c"])
        assertFalse(setA.stopped)
        assertFalse(setB.stopped)
        assertEquals(setOf("c"), beacon.faulted.value)
    }

    @Test fun asyncFailureFlipsAvailabilityToUnavailable() {
        beacon.update(active = true, macs = listOf(macA))
        val set = advertiser.sets.single()
        set.events(AdvertiserEvent.Started)
        assertEquals(emptySet(), beacon.faulted.value)
        // A later failure (here: new data refused at a rotation) arrives on its own.
        set.events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        assertEquals(setOf("a"), beacon.faulted.value)
        assertEquals(BeaconState.Failed(ADVERTISE_FAILED_INTERNAL_ERROR), beacon.states.value["a"])
        assertTrue(set.stopped)
    }

    @Test fun startFailureBeforeReturnIsFailed() {
        advertiser.failNow = ADVERTISE_FAILED_FEATURE_UNSUPPORTED
        beacon.update(active = true, macs = listOf(macA))
        assertEquals(BeaconState.Failed(ADVERTISE_FAILED_FEATURE_UNSUPPORTED), beacon.states.value["a"])
        assertEquals(setOf("a"), beacon.faulted.value)
        assertTrue(advertiser.sets.single().stopped)
    }

    @Test fun pendingStartAtBoundaryKeepsEnabled() {
        // A first start still pending is no fault, also across a boundary: it starts again with
        // the new ID (nothing is on the air to keep yet).
        beacon.update(active = true, macs = listOf(macA))
        val first = advertiser.sets.single()
        now = boundary + 901_000L
        beacon.onClockCheck()
        assertTrue(first.stopped)
        assertEquals(2, advertiser.sets.size)
        assertContentEquals(idAt(macA, now), advertiser.sets[1].data.single())
        assertEquals(BeaconState.Starting, beacon.states.value["a"])
        assertEquals(emptySet(), beacon.faulted.value)
        advertiser.sets[1].events(AdvertiserEvent.Started)
        assertEquals(BeaconState.On, beacon.states.value["a"])
        assertEquals(emptySet(), beacon.faulted.value)
    }

    @Test fun retryKeepsTheFaultUntilASuccess() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets[0].events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        now += 5_000L
        beacon.onClockCheck()
        assertEquals(BeaconState.Starting, beacon.states.value["a"])
        // While the retry is pending the last confirmed state (failed) stands: no flicker.
        assertEquals(setOf("a"), beacon.faulted.value)
        advertiser.sets[1].events(AdvertiserEvent.Started)
        assertEquals(emptySet(), beacon.faulted.value)
        assertEquals(BeaconState.On, beacon.states.value["a"])
    }

    @Test fun retryFiresBeforeNextEpoch() {
        beacon.update(active = true, macs = listOf(macA))
        val failedAt = now
        advertiser.sets[0].events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        // 5 s, 15 s, 60 s, then every 5 minutes; each well before the boundary 800 s away.
        var expected = failedAt
        for ((attempt, delay) in listOf(5_000L, 15_000L, 60_000L, 300_000L, 300_000L).withIndex()) {
            expected += delay
            assertEquals(expected, alarm.at, "retry $attempt")
            assertEquals(WakeKind.PROMPT, alarm.kind, "retry $attempt")
            now = expected
            beacon.onClockCheck()
            assertEquals(attempt + 2, advertiser.sets.size)
            advertiser.sets.last().events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        }
        // The next 5-minute retry would fall after the boundary: the rotation comes first.
        assertEquals(boundary + 901_000L, alarm.at)
        assertEquals(WakeKind.ROTATION, alarm.kind)
    }

    @Test fun earlyClockCheckDoesNotRetry() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets[0].events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        now += 1_000L
        beacon.onClockCheck()
        assertEquals(1, advertiser.sets.size)
    }

    @Test fun setStoppedBySystemIsFailed() {
        beacon.update(active = true, macs = listOf(macA))
        val set = advertiser.sets.single()
        set.events(AdvertiserEvent.Started)
        set.events(AdvertiserEvent.StoppedBySystem)
        assertEquals(BeaconState.Failed(ProximityBeacon.CODE_STOPPED_BY_SYSTEM), beacon.states.value["a"])
        assertEquals(setOf("a"), beacon.faulted.value)
        assertEquals(now + 5_000L, alarm.at)
    }

    @Test fun eventsOfAStoppedSetAreIgnored() {
        beacon.update(active = true, macs = listOf(macA))
        val old = advertiser.sets.single()
        beacon.update(active = false, macs = emptyList())
        beacon.update(active = true, macs = listOf(macA))
        old.events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        old.events(AdvertiserEvent.StoppedBySystem)
        assertEquals(BeaconState.Starting, beacon.states.value["a"])
        assertEquals(emptySet(), beacon.faulted.value)
    }

    @Test fun retryWakeUsesNearExactAlarm() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets.single().events(AdvertiserEvent.Failed(ADVERTISE_FAILED_INTERNAL_ERROR))
        // A windowed alarm would stretch 5 s to 10 minutes.
        assertEquals(now + 5_000L, alarm.at)
        assertEquals(WakeKind.PROMPT, alarm.kind)
    }

    @Test fun rotationWakeUsesWindow() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets.single().events(AdvertiserEvent.Started)
        assertEquals(boundary + 901_000L, alarm.at)
        assertEquals(WakeKind.ROTATION, alarm.kind)
    }

    @Test fun adapterNotReadySinceLastUpdateRestartsAllSets() {
        beacon.update(active = true, macs = listOf(macA, macB))
        val (setA, setB) = advertiser.sets
        setA.events(AdvertiserEvent.Started)
        setB.events(AdvertiserEvent.Started)
        // Bluetooth went off and on again between two updates: the stack may have dropped the
        // sets without a word, so none is trusted.
        beacon.markAdapterNotReady()
        beacon.update(active = true, macs = listOf(macA, macB))
        assertTrue(setA.stopped)
        assertTrue(setB.stopped)
        assertEquals(4, advertiser.sets.size)
        assertEquals(mapOf("a" to BeaconState.Starting, "b" to BeaconState.Starting), beacon.states.value)
        // Once restarted, a later update with the same inputs leaves them alone.
        beacon.update(active = true, macs = listOf(macA, macB))
        assertEquals(4, advertiser.sets.size)
    }

    @Test fun refreshAfterTheAdapterCameBackRestartsWithTheLastInputs() {
        beacon.update(active = true, macs = listOf(macA))
        advertiser.sets.single().events(AdvertiserEvent.Started)
        beacon.markAdapterNotReady()
        beacon.refresh()
        assertTrue(advertiser.sets[0].stopped)
        assertEquals(2, advertiser.sets.size)
        assertContentEquals(idAt(macA, now), advertiser.sets[1].data.single())
    }

    @Test fun setDataWithoutCallbackIsAFault() {
        beacon.update(active = true, macs = listOf(macA))
        val set = advertiser.sets.single()
        set.events(AdvertiserEvent.Started)
        now = boundary + 901_000L
        beacon.onClockCheck()
        assertEquals(2, set.data.size)
        // No onAdvertisingDataSet: the alarm comes back at the deadline.
        assertEquals(now + 5_000L, alarm.at)
        assertEquals(WakeKind.PROMPT, alarm.kind)
        now += 4_999L
        beacon.onClockCheck()
        assertEquals(BeaconState.On, beacon.states.value["a"])
        now += 1L
        beacon.onClockCheck()
        assertEquals(BeaconState.Failed(ProximityBeacon.CODE_DATA_TIMEOUT), beacon.states.value["a"])
        assertEquals(setOf("a"), beacon.faulted.value)
        assertTrue(set.stopped)
        // And it is retried like any failure.
        assertEquals(now + 5_000L, alarm.at)
        // A confirmation arriving after the deadline changes nothing.
        set.events(AdvertiserEvent.DataSet)
        assertEquals(setOf("a"), beacon.faulted.value)
    }

    private companion object {
        // AdvertisingSetCallback's codes.
        const val ADVERTISE_FAILED_TOO_MANY_ADVERTISERS = 2
        const val ADVERTISE_FAILED_INTERNAL_ERROR = 4
        const val ADVERTISE_FAILED_FEATURE_UNSUPPORTED = 5
    }
}
