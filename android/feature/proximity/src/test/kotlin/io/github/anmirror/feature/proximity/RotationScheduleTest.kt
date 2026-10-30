package io.github.anmirror.feature.proximity

import kotlin.test.Test
import kotlin.test.assertEquals

class RotationScheduleTest {
    /** The start of some epoch, in Unix ms. */
    private val boundary = 1_800_000L * 900_000L

    @Test fun msUntilNextEpochAtBoundaries() {
        assertEquals(900_000L, msUntilNextEpoch(0L))
        assertEquals(1L, msUntilNextEpoch(899_999L))
        assertEquals(900_000L, msUntilNextEpoch(900_000L))
    }

    @Test fun nextTriggerIsOneSecondPastTheNextBoundary() {
        assertEquals(boundary + 900_000L + 1_000L, RotationSchedule.nextRotationAt(boundary + 100_000L))
        // Fired on time (1 s past the boundary): the next one is a full epoch later.
        assertEquals(boundary + 900_000L + 1_000L, RotationSchedule.nextRotationAt(boundary + 1_000L))
        assertEquals(1_800_000L, RotationSchedule.epochAt(boundary + 1_000L))
    }

    @Test fun lateFireRecomputesFromTheWallClock() {
        // The alarm meant for boundary + 1 s fires 7 minutes late: the epoch is the one now, and the
        // next trigger follows the next boundary, not "a period after the last one".
        val late = boundary + 7 * 60_000L
        assertEquals(1_800_000L, RotationSchedule.epochAt(late))
        assertEquals(boundary + 900_000L + 1_000L, RotationSchedule.nextRotationAt(late))
        // Fired a whole epoch late.
        val veryLate = boundary + 900_000L + 300_000L
        assertEquals(1_800_001L, RotationSchedule.epochAt(veryLate))
        assertEquals(boundary + 2 * 900_000L + 1_000L, RotationSchedule.nextRotationAt(veryLate))
    }

    @Test fun timeJumpBackGivesTheEarlierEpoch() {
        val jumped = boundary - 3_600_000L + 10_000L
        assertEquals(1_800_000L - 4, RotationSchedule.epochAt(jumped))
        assertEquals(boundary - 3 * 900_000L + 1_000L, RotationSchedule.nextRotationAt(jumped))
    }

    @Test fun nextWakeIsTheEarlierOfRotationAndRetry() {
        val now = boundary + 100_000L
        assertEquals(boundary + 901_000L, RotationSchedule.nextWake(now, retries = emptyList()))
        assertEquals(now + 5_000L, RotationSchedule.nextWake(now, retries = listOf(now + 60_000L, now + 5_000L)))
        assertEquals(boundary + 901_000L, RotationSchedule.nextWake(now, retries = listOf(boundary + 2_000_000L)))
    }

    @Test fun retryBackoff() {
        assertEquals(listOf(5_000L, 15_000L, 60_000L, 300_000L, 300_000L), (0..4).map(RetryBackoff::delayMs))
    }
}
