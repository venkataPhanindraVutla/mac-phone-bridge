package io.github.anmirror.feature.input

import io.github.anmirror.feature.input.InputEvent.Button
import io.github.anmirror.feature.input.InputEvent.Click
import io.github.anmirror.feature.input.InputEvent.Move
import io.github.anmirror.feature.input.InputEvent.Scroll
import io.github.anmirror.protocol.v1.MouseButton.MOUSE_BUTTON_LEFT
import io.github.anmirror.protocol.v1.MouseButton.MOUSE_BUTTON_RIGHT
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TrackpadGesturesTest {
    private val g = TrackpadGestures()

    private fun frame(timeMs: Long, vararg touches: Touch) = g.onFrame(TouchFrame(timeMs, touches.toList()))
    private fun a(x: Float, y: Float = 0f) = Touch(1, x, y)
    private fun b(x: Float, y: Float = 0f) = Touch(2, x, y)

    /** A one-finger tap: down at [downMs], lifted 80 ms later, 2 dp of jitter. Returns the lift's events. */
    private fun tap(downMs: Long): List<InputEvent> {
        frame(downMs, a(0f))
        frame(downMs + 40, a(2f))
        return frame(downMs + 80)
    }

    /** A tap at 0 (lifted at 80), then a second finger down at 200 that moves past the slop: the drag is on. */
    private fun startDrag() {
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(0))
        assertEquals(emptyList(), frame(200, a(0f)))
        assertEquals(emptyList(), frame(216, a(4f))) // inside the slop: held, nothing sent
        val started = frame(232, a(12f))
        assertEquals(Button(MOUSE_BUTTON_LEFT, down = true), started.first())
        val held = assertIs<Move>(started[1])
        assertTrue(held.dx > 12f * TrackpadMath.POINTS_PER_DP) // the held 4 dp and this frame's 8 dp, accelerated
        assertEquals(0f, held.dy)
        assertEquals(2, started.size)
    }

    @Test fun oneFingerMoveSendsMoves() {
        assertEquals(emptyList(), frame(0, a(0f)))
        // 5 dp in 100 ms is slow: gain 1.
        assertEquals(listOf(Move(7.5f, 0f)), frame(100, a(5f)))
        val fast = frame(110, a(25f, 10f)).single()
        assertIs<Move>(fast)
        assertTrue(fast.dx > 20f * TrackpadMath.POINTS_PER_DP) // accelerated
        assertTrue(fast.dy > 10f * TrackpadMath.POINTS_PER_DP)
        assertEquals(emptyList(), frame(120, a(25f, 10f))) // no movement, no move
        assertEquals(emptyList(), frame(400)) // a move is not a click
    }

    @Test fun tapIsLeftClick() {
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(0))
        // Held past 250 ms, it is not a tap.
        frame(1_000, a(0f))
        assertEquals(emptyList(), frame(1_251))
        // Moved past 8 dp, it is not a tap either.
        frame(2_000, a(0f))
        frame(2_050, a(9f))
        assertEquals(emptyList(), frame(2_100))
    }

    @Test fun secondTapWithin300msIsDoubleClick() {
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(0))
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 2)), tap(380)) // down 300 ms after the first lift
        // A double-click is not extended into a triple one.
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(560))
    }

    @Test fun slowSecondTapIsSingleClick() {
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(0))
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(381)) // down 301 ms after the first lift
    }

    @Test fun twoFingerTapIsRightClick() {
        assertEquals(emptyList(), frame(0, a(0f)))
        assertEquals(emptyList(), frame(20, a(0f), b(30f)))
        assertEquals(emptyList(), frame(100, a(1f), b(31f)))
        assertEquals(emptyList(), frame(110, b(31f)))
        assertEquals(listOf(Click(MOUSE_BUTTON_RIGHT, 1)), frame(120))
        // Both fingers lifting at once is a right-click too, and never starts a double-click.
        frame(200, a(0f), b(30f))
        assertEquals(listOf(Click(MOUSE_BUTTON_RIGHT, 1)), frame(280))
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(300))
    }

    @Test fun twoFingerDragScrolls() {
        val events = mutableListOf<InputEvent>()
        events += frame(0, a(0f, 0f), b(30f, 0f))
        events += frame(16, a(0f, 4f), b(30f, 4f)) // inside the slop
        assertEquals(emptyList(), events)
        // The centroid's movement × 2, not accelerated, however fast.
        assertEquals(listOf(Scroll(0f, 12f)), frame(20, a(0f, 10f), b(30f, 10f)))
        assertEquals(listOf(Scroll(-4f, 40f)), frame(24, a(-2f, 30f), b(28f, 30f)))
        assertEquals(emptyList(), frame(40, a(-2f, 30f)))
        // The finger left behind moves from where it is, without a jump.
        assertEquals(listOf(Move(1.5f, 0f)), frame(140, a(-1f, 30f)))
        assertEquals(emptyList(), frame(160)) // no click
    }

    @Test fun doubleTapHoldDragSendsDownMovesUp() {
        startDrag()
        val more = frame(248, a(20f)).single()
        assertIs<Move>(more)
        assertTrue(more.dx > 0f)
        assertEquals(listOf(Button(MOUSE_BUTTON_LEFT, down = false)), frame(300))
        // A drag is not a click: the next tap is a single click.
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(400))
    }

    @Test fun liftAfterDragAlwaysSendsUp() {
        // Lifted long after, past the tap time.
        startDrag()
        assertEquals(listOf(Button(MOUSE_BUTTON_LEFT, down = false)), frame(5_000))

        // A second finger joins the drag and both lift at once: one up, no right-click.
        g.cancel()
        startDrag()
        assertEquals(emptyList(), frame(250, a(12f), b(50f)))
        assertEquals(listOf(Button(MOUSE_BUTTON_LEFT, down = false)), frame(260))

        // The dragging finger lifts while another stays down: the up goes out at once.
        g.cancel()
        startDrag()
        frame(250, a(12f), b(50f))
        assertEquals(listOf(Button(MOUSE_BUTTON_LEFT, down = false)), frame(260, b(50f)))
        assertEquals(emptyList(), frame(270))
    }

    @Test fun cancelDuringDragSendsUp() {
        startDrag()
        assertEquals(listOf(Button(MOUSE_BUTTON_LEFT, down = false)), g.cancel())
        assertEquals(emptyList(), g.cancel()) // nothing held any more
        // The cancelled gesture is forgotten: no up, no click, and the next tap starts afresh.
        assertEquals(emptyList(), frame(240))
        assertEquals(listOf(Click(MOUSE_BUTTON_LEFT, 1)), tap(260))
        // A cancelled tap is no click either.
        frame(1_000, a(0f))
        assertEquals(emptyList(), g.cancel())
        assertEquals(emptyList(), frame(1_050))
    }
}
