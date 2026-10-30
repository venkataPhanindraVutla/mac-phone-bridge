package io.github.anmirror.phone

import io.github.anmirror.phone.service.ReconnectNoticeGate
import io.github.anmirror.phone.service.WatchdogFire
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** One watchdog fire, without Android: what it records, starts, posts and re-arms. */
class WatchdogRunTest {
    private class Rig(
        var confirmedEmpty: () -> Boolean = { false },
        var running: Boolean = false,
        var connected: Boolean = false,
        var startAllowed: Boolean = true,
    ) {
        val log = mutableListOf<String>()
        val posted = mutableListOf<Unit>()
        var cleared = 0
        var starts = 0
        var kicks = 0
        var schedules = 0
        val gate = ReconnectNoticeGate(MemoryFlag())

        fun fire() = WatchdogFire(
            confirmedEmpty = { confirmedEmpty() },
            serviceRunning = { running },
            connected = { connected },
            startService = { starts++; startAllowed },
            kick = { kicks++ },
            postNotice = { posted += Unit },
            clearNotice = { cleared++ },
            gate = gate,
            record = { log += it },
            schedule = { schedules++ },
        )
    }

    @Test
    fun aThrowIsRecordedAndTheWatchdogReArms() = runTest {
        // T5-1: a failure inside the receiver shows up in the event log.
        val r = Rig(confirmedEmpty = { throw IllegalStateException("keystore") })
        r.fire().run()
        assertEquals(listOf("failed,IllegalStateException"), r.log)
        assertEquals(1, r.schedules, "re-armed even after a failure")
    }

    @Test
    fun cancelClearsTheNoticeAndDoesNotReArm() = runTest {
        // M2: the last Mac was forgotten; a "Tap to reconnect" left behind would open onboarding.
        val r = Rig(confirmedEmpty = { true })
        r.fire().run()
        assertEquals(listOf("CANCEL"), r.log)
        assertEquals(1, r.cleared)
        assertEquals(0, r.schedules)
    }

    @Test
    fun refusedStartPostsTheNoticeOncePerEpisode() = runTest {
        // K6: posted while not dismissed; after a dismissal, not again until the phone connects.
        val r = Rig(startAllowed = false)
        r.fire().run()
        assertEquals(listOf("START_SERVICE", "start-refused"), r.log)
        assertEquals(1, r.posted.size)

        r.gate.onDismissed()
        r.fire().run()
        assertEquals(1, r.posted.size, "dismissed: no re-post")
        assertEquals("start-refused,notice-suppressed", r.log.last())

        r.gate.onConnected()
        r.fire().run()
        assertEquals(2, r.posted.size, "a new disconnected episode may post again")
        assertEquals(3, r.schedules)
    }

    @Test
    fun startedServiceAndKickPostNothing() = runTest {
        val r = Rig()
        r.fire().run()
        assertEquals(1, r.starts)
        r.running = true
        r.fire().run()
        assertEquals(1, r.kicks)
        assertTrue(r.posted.isEmpty())
        assertEquals(listOf("START_SERVICE", "KICK"), r.log)
    }

    @Test
    fun gateStartsOpen() {
        val g = ReconnectNoticeGate(MemoryFlag())
        assertTrue(g.mayPost())
        g.onDismissed()
        assertFalse(g.mayPost())
        g.onConnected()
        assertTrue(g.mayPost())
    }
}

/** An in-memory [ReconnectNoticeGate.Flag]. */
class MemoryFlag(private var value: Boolean = false) : ReconnectNoticeGate.Flag {
    override fun get(): Boolean = value
    override fun set(value: Boolean) { this.value = value }
}
