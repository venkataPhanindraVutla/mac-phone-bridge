package io.github.anmirror.feature.input

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.InputButton
import io.github.anmirror.protocol.v1.InputClick
import io.github.anmirror.protocol.v1.InputKey
import io.github.anmirror.protocol.v1.InputLaser
import io.github.anmirror.protocol.v1.InputMove
import io.github.anmirror.protocol.v1.InputScroll
import io.github.anmirror.protocol.v1.MouseButton
import io.github.anmirror.protocol.v1.RemoteKey
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Sends the trackpad's `input.*` frames (SPEC 23) in order, one at a time, from one loop on [scope].
 *
 * Moves and scrolls are summed into one pending value each, never queued: the loop sends at most
 * one `input.move` and one `input.scroll` per slot, and nothing while a send is in flight, so the
 * sums keep growing until the next one goes out. A slot is [minIntervalMs], and never shorter than
 * 1/120 s, so neither goes out more than 120 times in any second. Every other event (button, click,
 * key, laser) is sent in the order it came, right after the pending move and scroll it flushes.
 *
 * It tracks the held buttons and the laser: [close] sends an up for each and the laser off, then
 * stops. [send] does the gating (it returns false and sends nothing while the feature is closed).
 * The methods may be called from any thread.
 */
class InputSender(
    private val scope: CoroutineScope,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val minIntervalMs: Long = 8,
    private val clock: () -> Long,
) {
    private val lock = Any()
    private var moveDx = 0f
    private var moveDy = 0f
    private var scrollDx = 0f
    private var scrollDy = 0f

    /** Discrete events, each after the move and scroll it flushed, in order. */
    private val queue = ArrayDeque<Pair<String, MessageLite>>()
    private val held = LinkedHashSet<MouseButton>()
    private var laserOn = false
    private var closed = false

    // Slots are counted in 1/120 ms, so the 120 Hz cadence (8⅓ ms) adds up exactly.
    private val slotUnits = maxOf(minIntervalMs * UNITS_PER_MS, 1_000L * UNITS_PER_MS / MAX_PER_SECOND)

    /** The earliest time, in units, the next move (scroll) may go; on a cadence of [slotUnits] while they keep coming. */
    private var nextMoveAt = Long.MIN_VALUE
    private var nextScrollAt = Long.MIN_VALUE

    private val wake = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch { run() }
    }

    fun move(dx: Float, dy: Float) = update {
        moveDx += dx
        moveDy += dy
    }

    fun scroll(dx: Float, dy: Float) = update {
        scrollDx += dx
        scrollDy += dy
    }

    fun button(b: MouseButton, down: Boolean) = update {
        if (down) held += b else held -= b
        enqueue(MessageType.INPUT_BUTTON, InputButton.newBuilder().setButton(b).setDown(down).build())
    }

    fun click(b: MouseButton, count: Int) = update {
        enqueue(MessageType.INPUT_CLICK, InputClick.newBuilder().setButton(b).setCount(count).build())
    }

    fun key(k: RemoteKey) = update {
        enqueue(MessageType.INPUT_KEY, InputKey.newBuilder().setKey(k).build())
    }

    fun laser(on: Boolean) = update {
        laserOn = on
        enqueue(MessageType.INPUT_LASER, InputLaser.newBuilder().setOn(on).build())
    }

    /** An up for every held button and the laser off (after what is pending), then the loop stops. Later calls do nothing. */
    fun close() = update {
        for (b in held) enqueue(MessageType.INPUT_BUTTON, InputButton.newBuilder().setButton(b).setDown(false).build())
        held.clear()
        if (laserOn) enqueue(MessageType.INPUT_LASER, InputLaser.newBuilder().setOn(false).build())
        laserOn = false
        closed = true
    }

    private inline fun update(block: () -> Unit) {
        synchronized(lock) {
            if (closed) return
            block()
        }
        wake.trySend(Unit)
    }

    /** Under [lock]: the pending move and scroll go first, whatever their slot, then the event. */
    private fun enqueue(type: String, message: MessageLite) {
        val now = clock()
        takeMove(now)?.let(queue::addLast)
        takeScroll(now)?.let(queue::addLast)
        queue.addLast(type to message)
    }

    private sealed interface Step {
        class Send(val type: String, val message: MessageLite) : Step
        class Wait(val ms: Long) : Step
        data object Idle : Step
        data object Stop : Step
    }

    private suspend fun run() {
        while (true) {
            when (val step = synchronized(lock) { next(clock()) }) {
                is Step.Send -> try {
                    send(step.type, step.message)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // A failed send is a dropped frame, like a closed gate; the loop goes on.
                }
                is Step.Wait -> withTimeoutOrNull(step.ms) { wake.receive() }
                Step.Idle -> wake.receive()
                Step.Stop -> return
            }
        }
    }

    /** What to do now, under [lock]: the queue in order, then a move or scroll whose slot has come. */
    private fun next(now: Long): Step {
        queue.removeFirstOrNull()?.let { (type, message) -> return Step.Send(type, message) }
        val nowUnits = now * UNITS_PER_MS
        val moveDue = if (moveDx != 0f || moveDy != 0f) nextMoveAt else null
        val scrollDue = if (scrollDx != 0f || scrollDy != 0f) nextScrollAt else null
        if (moveDue != null && nowUnits >= moveDue) return takeMove(now)!!.let { (t, m) -> Step.Send(t, m) }
        if (scrollDue != null && nowUnits >= scrollDue) return takeScroll(now)!!.let { (t, m) -> Step.Send(t, m) }
        val due = listOfNotNull(moveDue, scrollDue).minOrNull()
        return when {
            due != null -> Step.Wait(ceilDiv(due - nowUnits, UNITS_PER_MS).coerceAtLeast(1))
            closed -> Step.Stop
            else -> Step.Idle
        }
    }

    private fun takeMove(now: Long): Pair<String, MessageLite>? {
        if (moveDx == 0f && moveDy == 0f) return null
        val message = InputMove.newBuilder().setDx(moveDx).setDy(moveDy).build()
        moveDx = 0f
        moveDy = 0f
        nextMoveAt = nextSlot(nextMoveAt, now)
        return MessageType.INPUT_MOVE to message
    }

    private fun takeScroll(now: Long): Pair<String, MessageLite>? {
        if (scrollDx == 0f && scrollDy == 0f) return null
        val message = InputScroll.newBuilder().setDx(scrollDx).setDy(scrollDy).build()
        scrollDx = 0f
        scrollDy = 0f
        nextScrollAt = nextSlot(nextScrollAt, now)
        return MessageType.INPUT_SCROLL to message
    }

    /**
     * The slot after one used at [now] (ms), in units. Taken on time (the wait on the integer
     * clock rounds up by under 1 ms) the cadence is kept, so slots are exactly [slotUnits] apart;
     * taken early (a flush ahead of a discrete event) it takes the due slot's place; taken late
     * (idle, or after a slow send) the cadence starts again from now.
     */
    private fun nextSlot(due: Long, now: Long): Long {
        val nowUnits = now * UNITS_PER_MS
        val onCadence = due != Long.MIN_VALUE && nowUnits - due < UNITS_PER_MS
        return (if (onCadence) due else nowUnits) + slotUnits
    }

    private fun ceilDiv(a: Long, b: Long): Long = -Math.floorDiv(-a, b)

    private companion object {
        const val MAX_PER_SECOND = 120L
        const val UNITS_PER_MS = MAX_PER_SECOND
    }
}
