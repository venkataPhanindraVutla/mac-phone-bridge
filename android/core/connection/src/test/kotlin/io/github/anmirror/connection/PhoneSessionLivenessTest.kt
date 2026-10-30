package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.Ping
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.channels.Channel as KChannel

@OptIn(ExperimentalCoroutinesApi::class)
class PhoneSessionLivenessTest {
    private val livenessShared = setOf("find.v1", LIVENESS_CAPABILITY, "status.v1")

    /** A phone session over a [MemoryWire]; the Mac side records what the phone sends, with the virtual time. */
    private class Rig(
        val scope: TestScope,
        shared: Set<String>,
        pingNow: ReceiveChannel<Unit>? = null,
    ) {
        private val wires = MemoryWire.pair()
        val macWire: MemoryWire = wires.second
        val mac = ControlChannel(wires.second, "h", 1, Identities.PHONE_FP)
        val fromPhone = CopyOnWriteArrayList<Pair<Long, Envelope>>()
        val macPings = AtomicInteger()
        val end: Deferred<SessionEnd>

        init {
            val phone = ControlChannel(wires.first, "h", 1, Identities.MAC_FP)
            val session = PhoneSession(phone, shared, uptimeMs = { scope.testScheduler.currentTime })
            scope.backgroundScope.launch {
                while (true) {
                    val e = mac.receive() ?: break
                    fromPhone += scope.testScheduler.currentTime to e
                }
            }
            end = scope.backgroundScope.async {
                session.run(pingNow = pingNow, onMacPing = { macPings.incrementAndGet() }) { }
            }
        }

        fun sent(type: String): List<Pair<Long, Envelope>> = fromPhone.filter { it.second.type == type }
    }

    @Test
    fun answersMacPingWithPongReplyTo() = runTest {
        val r = Rig(this, livenessShared)
        runCurrent()
        r.macWire.write(envelope(Channel.CHANNEL_SYSTEM, 7, MessageType.PING, Ping.getDefaultInstance()))
        runCurrent()
        val (at, pong) = r.sent(MessageType.PONG).single()
        assertEquals(0L, at, "answered before virtual time advanced")
        assertEquals(7L, pong.replyTo)
        assertEquals(Channel.CHANNEL_SYSTEM, pong.channel)
        assertEquals(1, r.macPings.get())
    }

    @Test
    fun macDrivenSessionSendsNoTimerPingWhileMacPings() = runTest {
        val r = Rig(this, livenessShared)
        runCurrent()
        repeat(10) {
            advanceTimeBy(30_000)
            r.mac.send(Channel.CHANNEL_SYSTEM, MessageType.PING, Ping.getDefaultInstance())
            runCurrent()
        }
        assertEquals(300_000L, testScheduler.currentTime)
        assertEquals(0, r.sent(MessageType.PING).size)
        assertEquals(10, r.sent(MessageType.PONG).size)
        assertFalse(r.end.isCompleted, "the session is still running")
    }

    @Test
    fun macDrivenSessionFallsBackToOwnPingAfter45sQuiet() = runTest {
        val r = Rig(this, livenessShared)
        advanceTimeBy(44_999)
        runCurrent()
        assertEquals(0, r.sent(MessageType.PING).size)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(45_000L), r.sent(MessageType.PING).map { it.first })
    }

    @Test
    fun macDrivenSessionEndsAfterUnansweredFallbackPing() = runTest {
        val r = Rig(this, livenessShared)
        advanceTimeBy(54_999)
        runCurrent()
        assertFalse(r.end.isCompleted, "still waiting for an answer to the 45 s ping")
        advanceTimeBy(1)
        runCurrent()
        assertTrue(r.end.isCompleted)
        assertEquals(SessionEnd.PONG_TIMEOUT, r.end.await())
        assertEquals(55_000L, testScheduler.currentTime)
    }

    @Test
    fun kickPingsAtOnceInMacDrivenMode() = runTest {
        val kicks = KChannel<Unit>(KChannel.CONFLATED)
        val r = Rig(this, livenessShared, pingNow = kicks)
        advanceTimeBy(10_000)
        kicks.trySend(Unit)
        runCurrent()
        assertEquals(listOf(10_000L), r.sent(MessageType.PING).map { it.first })
    }
}
