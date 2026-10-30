package io.github.anmirror.feature.input

import io.github.anmirror.protocol.v1.MouseButton
import kotlin.math.hypot

/** One finger on the surface, in dp. */
data class Touch(val id: Long, val x: Float, val y: Float)

/** Every finger down at [timeMs]; an empty list means all were lifted. */
data class TouchFrame(val timeMs: Long, val touches: List<Touch>)

/** What a gesture asks of the Mac's pointer; moves and scrolls are in Mac points. */
sealed interface InputEvent {
    data class Move(val dx: Float, val dy: Float) : InputEvent
    data class Scroll(val dx: Float, val dy: Float) : InputEvent
    data class Button(val button: MouseButton, val down: Boolean) : InputEvent
    data class Click(val button: MouseButton, val count: Int) : InputEvent
}

/**
 * Turns the fingers on the trackpad surface into pointer events:
 * - one finger moves the pointer (accelerated, [TrackpadMath.move]);
 * - a tap (at most [TAP_MAX_MS], within [SLOP_DP]) is a left click, and a second tap that comes
 *   down within [DOUBLE_TAP_MS] of the first one's lift is a double-click;
 * - a two-finger tap is a right click; a two-finger drag scrolls by the centroid's movement
 *   ([TrackpadMath.SCROLL_POINTS_PER_DP], not accelerated);
 * - a tap, then down again within [DOUBLE_TAP_MS] and moved past the slop, is a drag: the left
 *   button goes down, the pointer follows, and the button comes up when that finger lifts.
 *
 * A held button always gets its up: when its finger lifts, whatever else is going on, and on [cancel].
 * Not thread-safe: feed it from one thread (the UI's).
 */
class TrackpadGestures(private val math: TrackpadMath = TrackpadMath) {
    /** The fingers in the last frame, by id. */
    private var last: Map<Long, Touch> = emptyMap()
    private var lastTimeMs = 0L

    // The current gesture: from the first finger down to the last one up.
    private var downMs = 0L
    private val starts = HashMap<Long, Touch>()
    private var maxFingers = 0
    private var pastSlop = false

    /** This gesture came down soon after a tap: a tap now is a double-click, a move a drag. */
    private var afterTap = false
    private var heldDx = 0f
    private var heldDy = 0f

    /** The finger holding the left button down, or null. */
    private var dragFinger: Long? = null

    /** When the last single click's finger lifted, while a second tap can still follow it. */
    private var lastTapUpMs: Long? = null

    fun onFrame(f: TouchFrame): List<InputEvent> {
        val now = f.touches.associateBy { it.id }
        val events = ArrayList<InputEvent>(2)
        if (last.isEmpty() && now.isNotEmpty()) begin(f.timeMs)
        for (t in now.values) {
            val start = starts.getOrPut(t.id) { t }
            if (hypot(t.x - start.x, t.y - start.y) > SLOP_DP) pastSlop = true
        }
        maxFingers = maxOf(maxFingers, now.size)
        val dt = f.timeMs - lastTimeMs

        val drag = dragFinger
        if (drag != null) {
            val was = last[drag]
            val cur = now[drag]
            if (cur == null) {
                events += InputEvent.Button(MouseButton.MOUSE_BUTTON_LEFT, down = false)
                dragFinger = null
            } else if (was != null) {
                move(cur.x - was.x, cur.y - was.y, dt)?.let(events::add)
            }
        } else if (now.size == 1 && now.keys == last.keys) {
            val cur = now.values.first()
            val was = last.getValue(cur.id)
            if (afterTap && maxFingers == 1) {
                // Held back until it is clearly a drag, so a double-click doesn't nudge the pointer.
                val (dx, dy) = math.move(cur.x - was.x, cur.y - was.y, dt)
                heldDx += dx
                heldDy += dy
                if (pastSlop) {
                    dragFinger = cur.id
                    events += InputEvent.Button(MouseButton.MOUSE_BUTTON_LEFT, down = true)
                    if (heldDx != 0f || heldDy != 0f) events += InputEvent.Move(heldDx, heldDy)
                    heldDx = 0f
                    heldDy = 0f
                }
            } else {
                move(cur.x - was.x, cur.y - was.y, dt)?.let(events::add)
            }
        } else if (now.size == 2 && now.keys == last.keys && pastSlop) {
            val dx = now.values.sumOf { it.x.toDouble() } - last.values.sumOf { it.x.toDouble() }
            val dy = now.values.sumOf { it.y.toDouble() } - last.values.sumOf { it.y.toDouble() }
            // The centroid moves by half the sum of the fingers' movements.
            val scale = TrackpadMath.SCROLL_POINTS_PER_DP / 2
            if (dx != 0.0 || dy != 0.0) events += InputEvent.Scroll((dx * scale).toFloat(), (dy * scale).toFloat())
        }

        if (now.isEmpty() && last.isNotEmpty()) end(f.timeMs)?.let(events::add)
        last = now
        lastTimeMs = f.timeMs
        return events
    }

    /** The gesture was taken away (ACTION_CANCEL, the screen going away): the up for a held button, and nothing else. */
    fun cancel(): List<InputEvent> {
        val events = if (dragFinger != null) listOf(InputEvent.Button(MouseButton.MOUSE_BUTTON_LEFT, down = false)) else emptyList()
        dragFinger = null
        last = emptyMap()
        starts.clear()
        afterTap = false
        lastTapUpMs = null
        return events
    }

    private fun begin(timeMs: Long) {
        downMs = timeMs
        starts.clear()
        maxFingers = 0
        pastSlop = false
        heldDx = 0f
        heldDy = 0f
        afterTap = lastTapUpMs?.let { timeMs - it <= DOUBLE_TAP_MS } == true
        lastTapUpMs = null
    }

    /** All fingers lifted: a click if it was a tap. */
    private fun end(timeMs: Long): InputEvent? {
        val tap = !pastSlop && timeMs - downMs <= TAP_MAX_MS
        return when {
            !tap -> null
            maxFingers == 1 && afterTap -> InputEvent.Click(MouseButton.MOUSE_BUTTON_LEFT, 2)
            maxFingers == 1 -> {
                lastTapUpMs = timeMs
                InputEvent.Click(MouseButton.MOUSE_BUTTON_LEFT, 1)
            }
            maxFingers == 2 -> InputEvent.Click(MouseButton.MOUSE_BUTTON_RIGHT, 1)
            else -> null
        }
    }

    private fun move(dxDp: Float, dyDp: Float, dtMs: Long): InputEvent.Move? {
        if (dxDp == 0f && dyDp == 0f) return null
        val (dx, dy) = math.move(dxDp, dyDp, dtMs)
        return InputEvent.Move(dx, dy)
    }

    companion object {
        const val TAP_MAX_MS = 250L
        const val SLOP_DP = 8f
        const val DOUBLE_TAP_MS = 300L
    }
}
