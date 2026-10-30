package io.github.anmirror.phone

import io.github.anmirror.phone.service.WatchdogAction
import io.github.anmirror.phone.service.WatchdogDecision
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchdogDecisionTest {
    @Test
    fun nothingPairedCancels() {
        for (running in listOf(false, true)) {
            for (connected in listOf(false, true)) {
                assertEquals(WatchdogAction.CANCEL, WatchdogDecision.decide(false, running, connected), "running=$running connected=$connected")
            }
        }
    }

    @Test
    fun pairedAndNotRunningStartsService() =
        assertEquals(WatchdogAction.START_SERVICE, WatchdogDecision.decide(paired = true, serviceRunning = false, connected = false))

    @Test
    fun runningButNotConnectedKicks() =
        assertEquals(WatchdogAction.KICK, WatchdogDecision.decide(paired = true, serviceRunning = true, connected = false))

    @Test
    fun runningAndConnectedDoesNothing() =
        assertEquals(WatchdogAction.NOTHING, WatchdogDecision.decide(paired = true, serviceRunning = true, connected = true))

    @Test
    fun unreadableStoreCountsAsPaired() {
        assertTrue(WatchdogDecision.pairedForWatchdog(confirmedEmpty = false))
        assertFalse(WatchdogDecision.pairedForWatchdog(confirmedEmpty = true))
    }
}
