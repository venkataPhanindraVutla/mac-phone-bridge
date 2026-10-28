package io.github.anmirror.feature.find

import android.app.NotificationManager.INTERRUPTION_FILTER_ALARMS
import android.app.NotificationManager.INTERRUPTION_FILTER_ALL
import android.app.NotificationManager.INTERRUPTION_FILTER_NONE
import io.github.anmirror.protocol.v1.RingState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RingControllerTest {
    private class FakeAudio(var vol: Int = 3, val max: Int = 7) : AlarmAudio {
        var looping = false
        var startCalls = 0
        val volumeSets = mutableListOf<Int>()
        override fun volume() = vol
        override fun maxVolume() = max
        override fun setVolume(v: Int) { vol = v; volumeSets += v }
        override fun startLoop() { looping = true; startCalls++ }
        override fun stopLoop() { looping = false }
    }

    private class FakeDnd(val access: Boolean, var current: Int) : DndOverride {
        val sets = mutableListOf<Int>()
        override fun hasAccess() = access
        override fun currentFilter() = current
        override fun setFilter(f: Int) { current = f; sets += f }
    }

    private class FakeNotifier : RingNotifier {
        var shown = 0
        var cancelled = 0
        override fun show() { shown++ }
        override fun cancel() { cancelled++ }
    }

    private class FakeStore : RingSavedStore {
        var saved: SavedRingState? = null
        override fun save(state: SavedRingState) { saved = state }
        override fun load() = saved
        override fun clear() { saved = null }
    }

    private class Rig(vol: Int = 3, access: Boolean = true, filter: Int = INTERRUPTION_FILTER_ALL, val store: FakeStore = FakeStore()) {
        val audio = FakeAudio(vol)
        val dnd = FakeDnd(access, filter)
        val notifier = FakeNotifier()
        val states = mutableListOf<RingState>()
        val controller = RingController(audio, dnd, notifier, store) { states += it }
    }

    @Test
    fun startSetsMaxVolumeAndPlays() {
        val r = Rig()
        r.controller.start()
        assertEquals(7, r.audio.vol)
        assertTrue(r.audio.looping)
        assertEquals(1, r.notifier.shown)
        assertTrue(r.controller.ringing.value)
        assertEquals(listOf(RingState.newBuilder().setRinging(true).build()), r.states)
    }

    @Test
    fun stopRestoresPreviousVolumeAndFilter() {
        val r = Rig(vol = 2, filter = INTERRUPTION_FILTER_NONE)
        r.controller.start()
        assertEquals(INTERRUPTION_FILTER_ALARMS, r.dnd.current)
        r.controller.stop()
        assertEquals(2, r.audio.vol)
        assertEquals(INTERRUPTION_FILTER_NONE, r.dnd.current)
        assertFalse(r.audio.looping)
        assertEquals(1, r.notifier.cancelled)
        assertFalse(r.controller.ringing.value)
        assertEquals(false, r.states.last().ringing)
    }

    @Test
    fun startTwiceIsIdempotent() {
        val r = Rig(vol = 2)
        r.controller.start()
        r.controller.start()
        assertEquals(1, r.audio.startCalls)
        assertEquals(1, r.notifier.shown)
        assertEquals(1, r.states.size)
        r.controller.stop()
        assertEquals(2, r.audio.vol, "second start must not remember the max volume as 'previous'")
    }

    @Test
    fun stopWhenIdleIsNoOp() {
        val r = Rig()
        r.controller.stop()
        assertTrue(r.states.isEmpty())
        assertTrue(r.audio.volumeSets.isEmpty())
        assertEquals(0, r.notifier.cancelled)
        r.controller.start()
        r.controller.stop()
        r.controller.stop()
        assertEquals(2, r.states.size)
    }

    @Test
    fun overridesTotalSilenceWhenAccessGranted() {
        val r = Rig(access = true, filter = INTERRUPTION_FILTER_NONE)
        r.controller.start()
        assertEquals(listOf(INTERRUPTION_FILTER_ALARMS), r.dnd.sets)
        assertFalse(r.states.last().mayBeSilent)
    }

    @Test
    fun reportsMaySilentWithoutAccessInTotalSilence() {
        val r = Rig(access = false, filter = INTERRUPTION_FILTER_NONE)
        r.controller.start()
        assertTrue(r.dnd.sets.isEmpty())
        assertTrue(r.states.last().ringing)
        assertTrue(r.states.last().mayBeSilent)
    }

    @Test
    fun priorityModeDoesNotTouchFilter() {
        val r = Rig(access = true, filter = INTERRUPTION_FILTER_ALL)
        r.controller.start()
        r.controller.stop()
        assertTrue(r.dnd.sets.isEmpty())
    }

    @Test
    fun keepsRingingWhenConnectionDrops() {
        // The controller has no connection: a dropped send only loses the report.
        val r = Rig()
        r.controller.start()
        assertTrue(r.controller.ringing.value)
        assertTrue(r.audio.looping)
        r.controller.start() // a reconnect re-sending find.ring changes nothing
        assertTrue(r.controller.ringing.value)
    }

    @Test
    fun currentStateReflectsRingAndSilence() {
        val r = Rig(access = false, filter = INTERRUPTION_FILTER_NONE)
        assertEquals(RingState.getDefaultInstance(), r.controller.currentState())
        r.controller.start()
        assertEquals(RingState.newBuilder().setRinging(true).setMayBeSilent(true).build(), r.controller.currentState())
    }

    @Test
    fun userChangedDndMidRingIsNotOverwritten() {
        val r = Rig(vol = 2, filter = INTERRUPTION_FILTER_NONE)
        r.controller.start()
        r.dnd.current = INTERRUPTION_FILTER_ALL // the user changed it while ringing
        r.controller.stop()
        assertEquals(INTERRUPTION_FILTER_ALL, r.dnd.current)
        assertEquals(2, r.audio.vol, "volume is restored regardless")
    }

    @Test
    fun restoresAfterProcessDeath() {
        val store = FakeStore()
        val first = Rig(vol = 2, filter = INTERRUPTION_FILTER_NONE, store = store)
        first.controller.start()
        assertTrue(store.saved != null)
        // the process dies: a new controller, same phone state (max volume, ALARMS), same store
        val second = Rig(vol = 7, filter = INTERRUPTION_FILTER_ALARMS, store = store)
        second.controller.restoreLeftover()
        assertEquals(2, second.audio.vol)
        assertEquals(INTERRUPTION_FILTER_NONE, second.dnd.current)
        assertEquals(null, store.saved)
        assertFalse(second.controller.ringing.value)
    }

    @Test
    fun leftoverRestoreSkipsFilterTheUserChanged() {
        val store = FakeStore().apply { saved = SavedRingState(2, INTERRUPTION_FILTER_NONE) }
        val r = Rig(vol = 7, filter = INTERRUPTION_FILTER_ALL, store = store)
        r.controller.restoreLeftover()
        assertEquals(INTERRUPTION_FILTER_ALL, r.dnd.current)
        assertEquals(2, r.audio.vol)
    }

    @Test
    fun startFailureRestoresAndReportsNotRinging() {
        val r = Rig(vol = 2, filter = INTERRUPTION_FILTER_NONE)
        val failing = object : AlarmAudio by r.audio {
            override fun startLoop() = throw IllegalStateException("boom")
        }
        val dnd = r.dnd
        val states = mutableListOf<RingState>()
        val c = RingController(failing, dnd, r.notifier, r.store) { states += it }
        c.start()
        assertFalse(c.ringing.value)
        assertEquals(2, r.audio.vol)
        assertEquals(INTERRUPTION_FILTER_NONE, dnd.current)
        assertEquals(null, r.store.saved)
        assertEquals(false, states.last().ringing)
    }
}
