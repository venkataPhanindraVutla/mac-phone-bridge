package io.github.anmirror.feature.input

import kotlin.math.hypot

/**
 * The trackpad's pointer acceleration: a finger's movement in dp becomes Mac points
 * ([POINTS_PER_DP]) times a gain that grows with the finger's speed, so a slow finger is precise
 * and a fast flick crosses the screen. Scrolls are not accelerated ([SCROLL_POINTS_PER_DP]).
 */
object TrackpadMath {
    const val POINTS_PER_DP = 1.5f
    const val SCROLL_POINTS_PER_DP = 2.0f

    private const val SLOW_DP_PER_MS = 0.1f
    private const val FAST_DP_PER_MS = 1.5f
    private const val MAX_GAIN = 3.0f

    /** 1.0 at ≤ 0.1 dp/ms, 3.0 at ≥ 1.5 dp/ms, linear between. */
    fun gain(speedDpPerMs: Float): Float = when {
        speedDpPerMs <= SLOW_DP_PER_MS -> 1f
        speedDpPerMs >= FAST_DP_PER_MS -> MAX_GAIN
        else -> 1f + (speedDpPerMs - SLOW_DP_PER_MS) / (FAST_DP_PER_MS - SLOW_DP_PER_MS) * (MAX_GAIN - 1f)
    }

    /** A movement of ([dxDp], [dyDp]) over [dtMs] in Mac points. Events in the same millisecond count as 1 ms apart. */
    fun move(dxDp: Float, dyDp: Float, dtMs: Long): Pair<Float, Float> {
        val speed = hypot(dxDp, dyDp) / dtMs.coerceAtLeast(1)
        val scale = POINTS_PER_DP * gain(speed)
        return dxDp * scale to dyDp * scale
    }
}
