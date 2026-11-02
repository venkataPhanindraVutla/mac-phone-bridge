package io.github.anmirror.feature.media

import kotlin.test.Test
import kotlin.test.assertEquals

class ExtrapolatedPositionTest {
    @Test fun speedZeroWhilePlayingCountsAsOne() {
        assertEquals(6_000L, extrapolatedPosition(5_000, updatedAt = 100, speed = 0f, now = 1_100, durationMs = 0))
    }

    @Test fun usesTheReportedSpeed() {
        assertEquals(7_000L, extrapolatedPosition(5_000, updatedAt = 100, speed = 2f, now = 1_100, durationMs = 0))
    }

    @Test fun staysWithinTheDuration() {
        assertEquals(10_000L, extrapolatedPosition(9_500, updatedAt = 100, speed = 1f, now = 5_100, durationMs = 10_000))
    }

    @Test fun noExtrapolationWithoutAnUpdateTime() {
        assertEquals(5_000L, extrapolatedPosition(5_000, updatedAt = 0, speed = 1f, now = 99_000, durationMs = 0))
    }
}
