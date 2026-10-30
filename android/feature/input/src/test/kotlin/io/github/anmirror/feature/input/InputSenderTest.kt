package io.github.anmirror.feature.input

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.InputButton
import io.github.anmirror.protocol.v1.InputClick
import io.github.anmirror.protocol.v1.InputKey
import io.github.anmirror.protocol.v1.InputLaser
import io.github.anmirror.protocol.v1.InputMove
import io.github.anmirror.protocol.v1.InputScroll
import io.github.anmirror.protocol.v1.MouseButton.MOUSE_BUTTON_LEFT
import io.github.anmirror.protocol.v1.MouseButton.MOUSE_BUTTON_RIGHT
import io.github.anmirror.protocol.v1.RemoteKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class InputSenderTest {
    private data class Sent(val atMs: Long, val type: String, val message: MessageLite)

    private val sent = mutableListOf<Sent>()
    private var gate = true

    /** A sender on [TestScope]'s virtual clock; its `send` records what passes the gate. */
    private fun TestScope.sender(send: (suspend (String, MessageLite) -> Boolean)? = null) = InputSender(
        scope = backgroundScope,
        send = send ?: { type, m ->
            if (gate) sent += Sent(testScheduler.currentTime, type, m)
            gate
        },
        clock = { testScheduler.currentTime },
    )

    private fun types() = sent.map { it.type }

    @Test fun movesAreSummedNotQueued() = runTest {
        val s = sender()
        repeat(100) { s.move(1f, -0.5f) }
        runCurrent()
        advanceTimeBy(1_000)
        assertEquals(listOf(MessageType.INPUT_MOVE), types())
        assertEquals(InputMove.newBuilder().setDx(100f).setDy(-50f).build(), sent.single().message)

        // While a send is in flight, the sum keeps growing; one send carries it afterwards.
        sent.clear()
        val release = CompletableDeferred<Unit>()
        var calls = 0
        val slow = sender { type, m ->
            calls++
            if (calls == 1) release.await()
            sent += Sent(testScheduler.currentTime, type, m)
            true
        }
        slow.move(1f, 0f)
        runCurrent() // the first send is now stuck
        repeat(500) { slow.move(1f, 0f); slow.scroll(0f, 2f) }
        advanceTimeBy(5_000)
        assertEquals(1, calls)
        release.complete(Unit)
        runCurrent()
        advanceTimeBy(100)
        assertEquals(listOf(MessageType.INPUT_MOVE, MessageType.INPUT_MOVE, MessageType.INPUT_SCROLL), types())
        assertEquals(500f, (sent[1].message as InputMove).dx)
        assertEquals(1_000f, (sent[2].message as InputScroll).dy)
    }

    @Test fun atMost120MovesPerSecond() = runTest {
        val s = sender()
        // A finger moving for 3 s, reporting every millisecond; scrolls alongside.
        repeat(3_000) {
            s.move(1f, 0f)
            s.scroll(0f, 1f)
            runCurrent()
            advanceTimeBy(1)
        }
        runCurrent()
        advanceTimeBy(100)
        for (type in listOf(MessageType.INPUT_MOVE, MessageType.INPUT_SCROLL)) {
            val times = sent.filter { it.type == type }.map { it.atMs }
            for (start in times) {
                val inWindow = times.count { it >= start && it < start + 1_000 }
                assertTrue(inWindow <= 120, "$inWindow $type frames in the second from $start ms")
            }
            assertTrue(times.size >= 3 * 110, "only ${times.size} $type frames in 3 s")
        }
        // Nothing is lost: every delta arrives, summed.
        assertEquals(3_000f, sent.filter { it.type == MessageType.INPUT_MOVE }.sumOf { (it.message as InputMove).dx.toDouble() }.toFloat())
        assertEquals(3_000f, sent.filter { it.type == MessageType.INPUT_SCROLL }.sumOf { (it.message as InputScroll).dy.toDouble() }.toFloat())
    }

    @Test fun clickFlushesPendingMoveFirst() = runTest {
        val s = sender()
        s.move(5f, 0f)
        runCurrent() // sent at once; the next move must wait for its slot
        s.move(3f, 1f)
        s.scroll(0f, 4f)
        s.click(MOUSE_BUTTON_LEFT, 2)
        s.key(RemoteKey.REMOTE_KEY_NEXT_SLIDE)
        runCurrent()
        assertEquals(
            listOf(
                MessageType.INPUT_MOVE, MessageType.INPUT_MOVE, MessageType.INPUT_SCROLL,
                MessageType.INPUT_CLICK, MessageType.INPUT_KEY,
            ),
            types(),
        )
        assertEquals(0L, sent.last().atMs) // not held back by the move's 120 Hz slot
        assertEquals(InputMove.newBuilder().setDx(3f).setDy(1f).build(), sent[1].message)
        assertEquals(InputClick.newBuilder().setButton(MOUSE_BUTTON_LEFT).setCount(2).build(), sent[3].message)
        assertEquals(InputKey.newBuilder().setKey(RemoteKey.REMOTE_KEY_NEXT_SLIDE).build(), sent[4].message)
        // Discrete events keep their order.
        sent.clear()
        s.button(MOUSE_BUTTON_LEFT, down = true)
        s.move(2f, 0f)
        s.button(MOUSE_BUTTON_LEFT, down = false)
        runCurrent()
        assertEquals(listOf(MessageType.INPUT_BUTTON, MessageType.INPUT_MOVE, MessageType.INPUT_BUTTON), types())
    }

    @Test fun closeReleasesHeldButtonAndLaser() = runTest {
        val s = sender()
        s.button(MOUSE_BUTTON_LEFT, down = true)
        s.button(MOUSE_BUTTON_RIGHT, down = true)
        s.button(MOUSE_BUTTON_RIGHT, down = false)
        s.laser(true)
        runCurrent()
        sent.clear()
        s.move(4f, 4f)
        s.close()
        runCurrent()
        assertEquals(
            listOf(
                Sent(0, MessageType.INPUT_MOVE, InputMove.newBuilder().setDx(4f).setDy(4f).build()),
                Sent(0, MessageType.INPUT_BUTTON, InputButton.newBuilder().setButton(MOUSE_BUTTON_LEFT).setDown(false).build()),
                Sent(0, MessageType.INPUT_LASER, InputLaser.newBuilder().setOn(false).build()),
            ),
            sent,
        )
        // Closed: nothing more goes out, and closing again sends nothing.
        sent.clear()
        s.move(1f, 1f)
        s.button(MOUSE_BUTTON_LEFT, down = true)
        s.close()
        runCurrent()
        advanceTimeBy(1_000)
        assertEquals(emptyList(), sent)

        // Nothing held: close sends nothing.
        val idle = sender()
        idle.laser(true)
        idle.laser(false)
        runCurrent()
        sent.clear()
        idle.close()
        runCurrent()
        assertEquals(emptyList(), sent)
    }

    @Test fun keepaliveRepeatsHeldFramesEvery2s() = runTest {
        val s = sender()
        val down = InputButton.newBuilder().setButton(MOUSE_BUTTON_LEFT).setDown(true).build()
        val laserOn = InputLaser.newBuilder().setOn(true).build()
        s.button(MOUSE_BUTTON_LEFT, down = true)
        s.laser(true)
        runCurrent()
        // A still finger for 7 s: both repeated every 2 s from the last frame sent.
        advanceTimeBy(7_001)
        assertEquals(
            listOf(
                Sent(0, MessageType.INPUT_BUTTON, down), Sent(0, MessageType.INPUT_LASER, laserOn),
                Sent(2_000, MessageType.INPUT_BUTTON, down), Sent(2_000, MessageType.INPUT_LASER, laserOn),
                Sent(4_000, MessageType.INPUT_BUTTON, down), Sent(4_000, MessageType.INPUT_LASER, laserOn),
                Sent(6_000, MessageType.INPUT_BUTTON, down), Sent(6_000, MessageType.INPUT_LASER, laserOn),
            ),
            sent,
        )

        // Any frame counts: while moves keep going nothing is repeated, and the 2 s run from the last one.
        sent.clear()
        repeat(30) {
            s.move(1f, 0f)
            advanceTimeBy(100)
        }
        runCurrent()
        assertTrue(sent.all { it.type == MessageType.INPUT_MOVE }, "${types()}")
        val lastMove = sent.last().atMs
        advanceTimeBy(2_001)
        assertEquals(
            listOf(Sent(lastMove + 2_000, MessageType.INPUT_BUTTON, down), Sent(lastMove + 2_000, MessageType.INPUT_LASER, laserOn)),
            sent.drop(30),
        )

        // Only what is still on: after the laser goes off, only the held button is repeated.
        sent.clear()
        s.laser(false)
        runCurrent()
        advanceTimeBy(2_001)
        assertEquals(listOf(MessageType.INPUT_LASER, MessageType.INPUT_BUTTON), types())
        assertEquals(down, sent.last().message)

        // Nothing held and no laser: nothing is repeated.
        sent.clear()
        s.button(MOUSE_BUTTON_LEFT, down = false)
        runCurrent()
        advanceTimeBy(10_000)
        assertEquals(listOf(MessageType.INPUT_BUTTON), types())

        // Closed: no keepalive after the releases.
        sent.clear()
        s.button(MOUSE_BUTTON_RIGHT, down = true)
        runCurrent()
        s.close()
        runCurrent()
        advanceTimeBy(10_000)
        assertEquals(listOf(MessageType.INPUT_BUTTON, MessageType.INPUT_BUTTON), types())
    }

    @Test fun failedSendIsLoggedOnceByClassOnly() = runTest {
        val logs = mutableListOf<String>()
        var calls = 0
        val s = InputSender(
            scope = backgroundScope,
            send = { _, _ ->
                calls++
                throw IllegalStateException("secret detail")
            },
            clock = { testScheduler.currentTime },
            log = { logs += it },
        )
        s.click(MOUSE_BUTTON_LEFT, 1)
        s.key(RemoteKey.REMOTE_KEY_NEXT_SLIDE)
        runCurrent()
        s.move(1f, 0f)
        runCurrent()
        assertEquals(3, calls) // the loop goes on
        assertEquals(listOf("input: send failed (IllegalStateException)"), logs)
    }

    @Test fun nothingSentWhenGateIsClosed() = runTest {
        var attempts = 0
        val s = sender { type, m ->
            attempts++
            if (gate) sent += Sent(testScheduler.currentTime, type, m)
            gate
        }
        gate = false
        s.move(10f, 0f)
        s.click(MOUSE_BUTTON_LEFT, 1)
        s.laser(true)
        runCurrent()
        advanceTimeBy(1_000)
        assertEquals(emptyList(), sent)
        assertTrue(attempts > 0) // each went to the gate, which refused it
        // When the gate opens, what it refused is not replayed.
        gate = true
        s.move(1f, 0f)
        runCurrent()
        assertEquals(listOf(InputMove.newBuilder().setDx(1f).build() as MessageLite), sent.map { it.message })
    }
}
