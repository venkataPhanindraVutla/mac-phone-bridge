package io.github.anmirror.connection

import kotlin.test.Test
import kotlin.test.assertEquals

class PhoneLivenessTest {
    private fun liveness(macDriven: Boolean) = PhoneLiveness(
        macDriven = macDriven,
        pingIntervalMs = 30_000,
        fallbackIdleMs = 45_000,
        pongTimeoutMs = 10_000,
        startMs = 0,
    )

    @Test
    fun legacyPingsThirtySecondsAfterLastPong() {
        val l = liveness(macDriven = false)
        assertEquals(LivenessStep.WaitUntil(30_000), l.next(0))
        assertEquals(LivenessStep.SendPing, l.next(30_000))
        l.onPingSent(30_000)
        l.onIncoming(35_000, isPong = true)
        assertEquals(LivenessStep.WaitUntil(65_000), l.next(35_000))
    }

    @Test
    fun legacyDeadTenSecondsAfterUnansweredPing() {
        val l = liveness(macDriven = false)
        l.onPingSent(30_000)
        assertEquals(LivenessStep.WaitUntil(40_000), l.next(39_999))
        assertEquals(LivenessStep.Dead, l.next(40_000))
    }

    @Test
    fun legacyModeIgnoresNonPongTraffic() {
        val l = liveness(macDriven = false)
        l.onPingSent(30_000)
        l.onIncoming(31_000, isPong = false)
        assertEquals(LivenessStep.Dead, l.next(40_000))
    }

    @Test
    fun macDrivenWaitsFortyFiveSecondsOfQuiet() {
        val l = liveness(macDriven = true)
        assertEquals(LivenessStep.WaitUntil(45_000), l.next(0))
        l.onIncoming(30_000, isPong = false)
        assertEquals(LivenessStep.WaitUntil(75_000), l.next(30_000))
    }

    @Test
    fun macDrivenAnyMessageAnswersFallbackPing() {
        val l = liveness(macDriven = true)
        l.onPingSent(45_000)
        l.onIncoming(50_000, isPong = false)
        assertEquals(LivenessStep.WaitUntil(95_000), l.next(50_000))
    }

    @Test
    fun macDrivenDeadTenSecondsAfterUnansweredFallbackPing() {
        val l = liveness(macDriven = true)
        l.onPingSent(45_000)
        assertEquals(LivenessStep.WaitUntil(55_000), l.next(54_999))
        assertEquals(LivenessStep.Dead, l.next(55_000))
    }

    @Test
    fun requestPingSendsAtOnceInBothModes() {
        for (macDriven in listOf(false, true)) {
            val l = liveness(macDriven)
            l.requestPing()
            assertEquals(LivenessStep.SendPing, l.next(1), "macDriven=$macDriven")
        }
    }

    @Test
    fun requestPingWhilePingUnansweredKeepsItsDeadline() {
        // A burst of kicks after a dead link: one ping, and the drop 10 s after it, not later.
        for (macDriven in listOf(false, true)) {
            val l = liveness(macDriven)
            l.requestPing()
            assertEquals(LivenessStep.SendPing, l.next(1))
            l.onPingSent(1)
            l.requestPing()
            l.requestPing()
            assertEquals(LivenessStep.WaitUntil(10_001), l.next(5_000), "macDriven=$macDriven")
            assertEquals(LivenessStep.Dead, l.next(10_001), "macDriven=$macDriven")
        }
    }
}
