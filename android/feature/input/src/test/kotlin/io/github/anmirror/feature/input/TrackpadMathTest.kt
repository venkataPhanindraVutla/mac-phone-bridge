package io.github.anmirror.feature.input

import kotlin.test.Test
import kotlin.test.assertEquals

class TrackpadMathTest {
    @Test fun gainIsOneWhenSlow() {
        assertEquals(1.0f, TrackpadMath.gain(0f))
        assertEquals(1.0f, TrackpadMath.gain(0.05f))
        assertEquals(1.0f, TrackpadMath.gain(0.1f))
        // A slow move is the finger's movement at POINTS_PER_DP.
        assertEquals(3f to -1.5f, TrackpadMath.move(2f, -1f, dtMs = 100))
    }

    @Test fun gainCapsAtThree() {
        assertEquals(3.0f, TrackpadMath.gain(1.5f))
        assertEquals(3.0f, TrackpadMath.gain(10f))
        // 30 dp in 10 ms: 3 dp/ms, capped.
        assertEquals(135f to 0f, TrackpadMath.move(30f, 0f, dtMs = 10))
        // Two events in the same millisecond count as 1 ms apart, not as infinite speed.
        assertEquals(0.15f, TrackpadMath.move(0.1f, 0f, dtMs = 0).first, 1e-6f)
    }

    @Test fun gainIsLinearBetween() {
        assertEquals(2.0f, TrackpadMath.gain(0.8f), 1e-5f)
        assertEquals(1.5f, TrackpadMath.gain(0.45f), 1e-5f)
        assertEquals(2.5f, TrackpadMath.gain(1.15f), 1e-5f)
        // 8 dp in 10 ms is 0.8 dp/ms: gain 2, so 8 × 1.5 × 2.
        val (dx, dy) = TrackpadMath.move(0f, 8f, dtMs = 10)
        assertEquals(0f, dx)
        assertEquals(24f, dy, 1e-4f)
    }

    private fun assertEquals(expected: Float, actual: Float, tolerance: Float) =
        kotlin.test.assertEquals(expected, actual, absoluteTolerance = tolerance)
}
