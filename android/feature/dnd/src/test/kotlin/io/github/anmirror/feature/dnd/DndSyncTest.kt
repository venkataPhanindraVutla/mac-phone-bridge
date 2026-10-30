package io.github.anmirror.feature.dnd

import android.app.NotificationManager.INTERRUPTION_FILTER_ALARMS
import android.app.NotificationManager.INTERRUPTION_FILTER_ALL
import android.app.NotificationManager.INTERRUPTION_FILTER_NONE
import android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY
import android.app.NotificationManager.INTERRUPTION_FILTER_UNKNOWN
import com.google.protobuf.MessageLite
import io.github.anmirror.feature.find.AlarmAudio
import io.github.anmirror.feature.find.DndOverride
import io.github.anmirror.feature.find.RingController
import io.github.anmirror.feature.find.RingNotifier
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.DndOrigin
import io.github.anmirror.protocol.v1.DndState
import io.github.anmirror.protocol.v1.FeatureAvailability
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DndSyncTest {
    private class FakeDnd(var access: Boolean = true, var current: Int = INTERRUPTION_FILTER_ALL) : DndOverride {
        val sets = mutableListOf<Int>()
        override fun hasAccess() = access
        override fun currentFilter() = current
        override fun setFilter(f: Int) { current = f; sets += f }
    }

    private val dnd = FakeDnd()
    private var now = 0L
    private val sent = mutableListOf<Pair<String, MessageLite>>()
    private val sync = DndSync(dnd, { type, m -> sent += type to m; true }, clock = { now })

    private fun states() = sent.map { (type, m) -> assertEquals(MessageType.DND_STATE, type); m as DndState }

    private fun availability(enabled: Boolean, reason: AvailabilityReason = AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER) =
        if (enabled) FeatureAvailability.newBuilder().setEnabled(true).build()
        else FeatureAvailability.newBuilder().setEnabled(false).setReason(reason).build()

    private fun macAvailability(sends: Boolean = true, applies: Boolean = true) {
        sync.onMacAvailability(
            DndAvailability.newBuilder().setSends(availability(sends)).setApplies(availability(applies)).build(),
        )
    }

    private fun macState(on: Boolean, origin: DndOrigin = DndOrigin.DND_ORIGIN_USER, snapshot: Boolean = false) {
        sync.onMacState(DndState.newBuilder().setOn(on).setOrigin(origin).setSnapshot(snapshot).build())
    }

    private fun state(on: Boolean, origin: DndOrigin = DndOrigin.DND_ORIGIN_USER, snapshot: Boolean = false): DndState =
        DndState.newBuilder().setOn(on).setOrigin(origin).setSnapshot(snapshot).build()

    /** Connected without sending the snapshot, with the Mac applying. */
    private suspend fun connected(filter: Int = INTERRUPTION_FILTER_ALL) {
        dnd.current = filter
        sync.onConnected(sends = false)
        macAvailability()
    }

    @Test fun userTransitionIsSentWhenMacApplies() = runTest {
        connected()
        dnd.current = INTERRUPTION_FILTER_PRIORITY
        sync.onLocalChange()
        dnd.current = INTERRUPTION_FILTER_ALL
        sync.onLocalChange()
        assertEquals(listOf(state(true), state(false)), states())
    }

    @Test fun nothingSentWhileMacAppliesIsOff() = runTest {
        dnd.current = INTERRUPTION_FILTER_ALL
        sync.onConnected(sends = false)
        // No availability from the Mac yet: nil counts as off.
        dnd.current = INTERRUPTION_FILTER_PRIORITY
        sync.onLocalChange()
        macAvailability(applies = false)
        dnd.current = INTERRUPTION_FILTER_ALL
        sync.onLocalChange()
        assertTrue(sent.isEmpty())
        // Its next transition goes once the Mac applies again.
        macAvailability(applies = true)
        dnd.current = INTERRUPTION_FILTER_NONE
        sync.onLocalChange()
        assertEquals(listOf(state(true)), states())
    }

    @Test fun repeatedChangeWithoutTransitionSendsNothing() = runTest {
        connected(INTERRUPTION_FILTER_PRIORITY)
        sync.onLocalChange()
        dnd.current = INTERRUPTION_FILTER_NONE
        sync.onLocalChange()
        assertTrue(sent.isEmpty())
    }

    @Test fun unknownFilterIsIgnored() = runTest {
        connected()
        dnd.current = INTERRUPTION_FILTER_UNKNOWN
        sync.onLocalChange()
        dnd.current = INTERRUPTION_FILTER_ALL
        sync.onLocalChange()
        assertTrue(sent.isEmpty())
        dnd.current = INTERRUPTION_FILTER_PRIORITY
        sync.onLocalChange()
        assertEquals(listOf(state(true)), states())
    }

    @Test fun macOnIsAppliedAsPriorityAndOffAsAll() = runTest {
        connected()
        macState(true)
        assertEquals(listOf(INTERRUPTION_FILTER_PRIORITY), dnd.sets)
        assertEquals(true, sync.macOn.value)
        macState(false)
        assertEquals(listOf(INTERRUPTION_FILTER_PRIORITY, INTERRUPTION_FILTER_ALL), dnd.sets)
        assertEquals(false, sync.macOn.value)
    }

    @Test fun appliedMacStateIsNotEchoed() = runTest {
        connected()
        macState(true)
        now = 3_000
        sync.onLocalChange() // the filter the phone itself set, reported back
        assertTrue(sent.isEmpty())
    }

    @Test fun userChangeAfterAnEchoIsSent() = runTest {
        connected()
        macState(true)
        now = 9_999
        sync.onLocalChange() // the echo, at the end of the window
        assertTrue(sent.isEmpty())

        dnd.current = INTERRUPTION_FILTER_ALL
        now = 20_000
        sync.onLocalChange() // the user, later: not an echo
        assertEquals(listOf(state(false)), states())
    }

    @Test fun lateEchoIsSentAsSyncAndNotApplied() = runTest {
        connected()
        macState(true)
        now = 11_000
        sync.onLocalChange()
        assertEquals(listOf(state(true, DndOrigin.DND_ORIGIN_SYNC)), states())
        assertEquals(listOf(INTERRUPTION_FILTER_PRIORITY), dnd.sets) // applied once, never again
    }

    @Test fun snapshotIsNotApplied() = runTest {
        connected()
        macState(true, snapshot = true)
        assertTrue(dnd.sets.isEmpty())
        assertEquals(true, sync.macOn.value) // shown, though
    }

    @Test fun syncOriginIsNotApplied() = runTest {
        connected()
        macState(true, origin = DndOrigin.DND_ORIGIN_SYNC)
        assertTrue(dnd.sets.isEmpty())
        assertEquals(true, sync.macOn.value)
    }

    @Test fun noAccessDoesNotApply() = runTest {
        dnd.access = false
        connected()
        macState(true)
        assertTrue(dnd.sets.isEmpty())
        assertEquals(true, sync.macOn.value)
    }

    @Test fun alreadyOnIsNotReapplied() = runTest {
        connected(INTERRUPTION_FILTER_ALARMS) // any filter but ALL is already "on"
        macState(true)
        assertTrue(dnd.sets.isEmpty())
        dnd.current = INTERRUPTION_FILTER_ALL
        macState(false) // already off
        assertTrue(dnd.sets.isEmpty())
    }

    @Test fun ringSwapNoneToAlarmsIsNoTransition() = runTest {
        connected(INTERRUPTION_FILTER_NONE)
        val ring = RingController(SilentAudio(), dnd, NoNotifier) {}
        ring.start() // Total silence blocks the alarm: Find my phone switches NONE to ALARMS
        assertEquals(INTERRUPTION_FILTER_ALARMS, dnd.current)
        sync.onLocalChange()
        ring.stop() // and back
        assertEquals(INTERRUPTION_FILTER_NONE, dnd.current)
        sync.onLocalChange()
        assertTrue(sent.isEmpty())
    }

    @Test fun connectSendsSnapshotWhenSending() = runTest {
        dnd.current = INTERRUPTION_FILTER_PRIORITY
        sync.onConnected(sends = true)
        assertEquals(listOf(state(true, snapshot = true)), states())

        sent.clear()
        sync.onDisconnected()
        sync.onConnected(sends = false)
        assertTrue(sent.isEmpty())
    }

    @Test fun connectSendsNoSnapshotWhileTheFilterIsUnknown() = runTest {
        dnd.current = INTERRUPTION_FILTER_UNKNOWN
        sync.onConnected(sends = true)
        assertTrue(sent.isEmpty())
    }

    @Test fun connectTakesTheFilterAsItIs() = runTest {
        connected()
        dnd.current = INTERRUPTION_FILTER_PRIORITY
        sync.onDisconnected()
        sync.onConnected(sends = false) // a change while away is not a transition
        macAvailability()
        sync.onLocalChange()
        assertTrue(sent.isEmpty())
    }

    @Test fun disconnectForgetsTheMac() = runTest {
        connected()
        macState(true)
        assertEquals(true, sync.macAvailability.value?.applies?.enabled)
        sync.onDisconnected()
        assertNull(sync.macOn.value)
        assertNull(sync.macAvailability.value)
    }

    private class SilentAudio : AlarmAudio {
        private var v = 3
        override fun volume() = v
        override fun maxVolume() = 7
        override fun setVolume(v: Int) { this.v = v }
        override fun startLoop() = Unit
        override fun stopLoop() = Unit
    }

    private object NoNotifier : RingNotifier {
        override fun show() = Unit
        override fun cancel() = Unit
    }
}
