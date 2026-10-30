package io.github.anmirror.feature.media

import io.github.anmirror.protocol.v1.MediaState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class StateThrottleTest {
    private fun state(n: Int) = MediaState.newBuilder().setActive(true).setTitle("t$n").build()

    private val emitted = mutableListOf<Pair<Long, MediaState>>()

    private fun TestScope.throttle() = StateThrottle(this, clock = { currentTime }) { emitted += currentTime to it }

    @Test fun firstChangeAfterQuietGoesAtOnce() = runTest {
        val t = throttle()
        t.offer(state(1))
        assertEquals(listOf(0L to state(1)), emitted)
        advanceTimeBy(300)
        t.offer(state(2))
        assertEquals(300L to state(2), emitted.last())
        assertEquals(2, emitted.size)
    }

    @Test fun atMostFourStatesPerSecond() = runTest {
        val t = throttle()
        repeat(20) { i ->
            t.offer(state(i))
            advanceTimeBy(50)
        }
        advanceUntilIdle()
        assertTrue(emitted.count { it.first < 1_000 } <= 4, "emits: ${emitted.map { it.first }}")
        emitted.zipWithNext().forEach { (a, b) -> assertTrue(b.first - a.first >= 250, "emits: ${emitted.map { it.first }}") }
        assertEquals(state(19), emitted.last().second)
    }

    private fun playing(positionMs: Long, speed: Float = 1f, durationMs: Long = 0, playing: Boolean = true) =
        MediaState.newBuilder().setActive(true).setPlaying(playing).setPositionMs(positionMs).setSpeed(speed).setDurationMs(durationMs).build()

    @Test fun positionIsCarriedForwardToEmitTime() = runTest {
        val t = throttle()
        t.offer(state(1)) // leading edge at 0
        advanceTimeBy(100)
        t.offer(playing(positionMs = 1_000, speed = 2f)) // trailing, at 250
        advanceUntilIdle()
        assertEquals(250L, emitted.last().first)
        assertEquals(1_000 + 150 * 2L, emitted.last().second.positionMs)
    }

    @Test fun carriedPositionStopsAtTheDurationAndNeverMovesWhilePaused() = runTest {
        val t = throttle()
        t.offer(state(1))
        advanceTimeBy(100)
        t.offer(playing(positionMs = 1_000, speed = 0f, durationMs = 1_100)) // speed 0 counts as 1
        advanceUntilIdle()
        assertEquals(1_100, emitted.last().second.positionMs)

        advanceTimeBy(1_000)
        t.offer(state(2))
        advanceTimeBy(100)
        t.offer(playing(positionMs = 5_000, playing = false))
        advanceUntilIdle()
        assertEquals(5_000, emitted.last().second.positionMs)
    }

    @Test fun resetDropsThePendingStateAndOpensTheLeadingEdge() = runTest {
        val t = throttle()
        t.offer(state(1))
        t.offer(state(2)) // pending
        t.reset()
        advanceUntilIdle()
        assertEquals(listOf(state(1)), emitted.map { it.second })
        t.offer(state(3))
        assertEquals(state(3), emitted.last().second)
    }
}
