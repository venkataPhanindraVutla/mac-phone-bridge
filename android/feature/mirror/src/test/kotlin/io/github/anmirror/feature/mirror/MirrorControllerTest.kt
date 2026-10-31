package io.github.anmirror.feature.mirror

import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.FeatureAvailability
import io.github.anmirror.protocol.v1.MirrorPhase
import io.github.anmirror.protocol.v1.MirrorReason
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.MirrorState
import io.github.anmirror.protocol.v1.MirrorStop
import io.github.anmirror.protocol.v1.MirrorTestPattern
import io.github.anmirror.protocol.v1.TestPatternMode
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * A session that reports STARTING, waits for the previous one, then RUNNING (unless
 * [reachesRunning] is false), then STOPPED with the stop's reason; closing takes [closeTakesMs].
 */
private class FakeRun(
    val start: MirrorStart,
    val report: suspend (MirrorState) -> Unit,
    val reachesRunning: Boolean,
    val clock: () -> Long,
    val closeTakesMs: Long,
) : MirrorRun {
    val stops = CopyOnWriteArrayList<Pair<MirrorReason?, Boolean>>()
    private val ended = CompletableDeferred<MirrorReason?>()
    @Volatile var helperAt: Long? = null
    @Volatile var returnedAt: Long? = null

    override suspend fun run(awaitPrevious: suspend () -> Unit) {
        report(state(MirrorPhase.MIRROR_PHASE_STARTING))
        awaitPrevious()
        helperAt = clock()
        if (reachesRunning) report(state(MirrorPhase.MIRROR_PHASE_RUNNING))
        ended.await()?.let { report(state(MirrorPhase.MIRROR_PHASE_STOPPED, it)) }
        delay(closeTakesMs)
        returnedAt = clock()
    }

    override fun stop(reason: MirrorReason?, drainControl: Boolean) {
        stops += reason to drainControl
        ended.complete(reason)
    }

    private fun state(phase: MirrorPhase, reason: MirrorReason = MirrorReason.MIRROR_REASON_UNSPECIFIED) =
        MirrorState.newBuilder().setSession(start.session).setPhase(phase).setReason(reason).build()
}

@OptIn(ExperimentalCoroutinesApi::class)
class MirrorControllerTest {
    private var availability: FeatureAvailability = FeatureAvailability.newBuilder().setEnabled(true).build()
    private val sent = CopyOnWriteArrayList<String>()
    private val shells = CopyOnWriteArrayList<String>()
    private val runs = CopyOnWriteArrayList<FakeRun>()
    private var reachesRunning = true
    private var closeTakesMs = 0L
    private val actives = CopyOnWriteArrayList<Boolean>()

    private fun TestScope.controller() = MirrorController(
        open = { availability },
        newSession = { start, report ->
            FakeRun(start, report, reachesRunning, { testScheduler.currentTime }, closeTakesMs).also { runs += it }
        },
        onActive = { actives += it },
        sendState = { sent += "state ${it.session} ${it.phase.name.removePrefix("MIRROR_PHASE_")} ${it.reason.name.removePrefix("MIRROR_REASON_")}" },
        sendStop = { sent += "stop ${it.session} ${it.reason.name.removePrefix("MIRROR_REASON_")}" },
        shell = { shells += it },
        // Not backgroundScope: advanceUntilIdle runs only foreground work. Not a child: sessions may outlive the test.
        scope = CoroutineScope(coroutineContext + SupervisorJob()),
    )

    private fun start(session: Int) = mirrorStart(session)
    private fun stop(session: Int) = MirrorStop.newBuilder().setSession(session).setReason(MirrorReason.MIRROR_REASON_USER).build()
    private fun pattern(session: Int, mode: TestPatternMode) = MirrorTestPattern.newBuilder().setSession(session).setMode(mode).build()

    @Test
    fun secondStartReplacesFirst() = runTest {
        val c = controller()
        c.onStart(start(1))
        advanceUntilIdle()
        assertEquals(1, c.running.value?.session)
        c.onStart(start(2))
        advanceUntilIdle()
        assertEquals(listOf<Pair<MirrorReason?, Boolean>>(MirrorReason.MIRROR_REASON_REPLACED to false), runs[0].stops)
        assertEquals(
            listOf("state 1 STARTING UNSPECIFIED", "state 1 RUNNING UNSPECIFIED", "state 1 STOPPED REPLACED", "state 2 STARTING UNSPECIFIED", "state 2 RUNNING UNSPECIFIED"),
            sent,
        )
        assertEquals(2, c.running.value?.session)
        assertTrue(c.active.value)
    }

    @Test
    fun replacingStartSaysStartingAtOnceAndWaitsForTheOldClose() = runTest {
        closeTakesMs = 1_000 // the old session's close and pkill
        val c = controller()
        c.onStart(start(1))
        advanceUntilIdle()
        c.onStart(start(2))
        runCurrent()
        assertTrue("state 2 STARTING UNSPECIFIED" in sent, "STARTING is not held back by the old close")
        assertNull(runs[1].helperAt)
        advanceUntilIdle()
        assertEquals(1_000L, runs[0].returnedAt)
        assertTrue(runs[1].helperAt!! >= runs[0].returnedAt!!, "the new helper waits for the old session's pkill")
        assertEquals(2, c.running.value?.session)
    }

    @Test
    fun activeIsToldAtOnce() = runTest {
        val c = controller()
        c.onStart(start(1))
        assertEquals(listOf(true), actives, "before any dispatch: an idle close can't slip in")
        assertTrue(c.active.value)
        c.onStart(start(2))
        advanceUntilIdle()
        assertEquals(listOf(true), actives, "a replacement keeps it active")
        c.stopAll(null)
        advanceUntilIdle()
        assertEquals(listOf(true, false), actives)
    }

    @Test
    fun startWhileClosedAnswersFailed() = runTest {
        val c = controller()
        val cases = listOf(
            AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER to "TURNED_OFF",
            AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP to "NEEDS_SETUP",
            AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE to "UNAVAILABLE",
        )
        for ((i, case) in cases.withIndex()) {
            availability = FeatureAvailability.newBuilder().setEnabled(false).setReason(case.first).build()
            c.onStart(start(i + 1))
            advanceUntilIdle()
            assertEquals("state ${i + 1} FAILED ${case.second}", sent.last())
        }
        assertEquals(3, sent.size)
        assertTrue(runs.isEmpty())
        assertNull(c.running.value)
    }

    @Test
    fun startThatCannotBeMadeAnswersNeedsSetup() = runTest {
        val c = MirrorController(
            open = { availability },
            newSession = { _, _ -> throw java.io.IOException("no ADB identity") },
            sendState = { sent += "state ${it.session} ${it.phase.name} ${it.reason.name}" },
            sendStop = {},
            shell = {},
            scope = CoroutineScope(coroutineContext + SupervisorJob()),
        )
        c.onStart(start(1))
        advanceUntilIdle()
        assertEquals(listOf("state 1 MIRROR_PHASE_FAILED MIRROR_REASON_NEEDS_SETUP"), sent)
        assertTrue(!c.active.value)
    }

    @Test
    fun staleStopIsIgnored() = runTest {
        val c = controller()
        c.onStart(start(1))
        c.onStart(start(2))
        advanceUntilIdle()
        c.onStop(stop(1))
        advanceUntilIdle()
        assertTrue(runs[1].stops.isEmpty())
        assertEquals(2, c.running.value?.session)
        c.onStop(stop(2))
        advanceUntilIdle()
        assertEquals(listOf<Pair<MirrorReason?, Boolean>>(MirrorReason.MIRROR_REASON_USER to true), runs[1].stops)
        assertEquals("state 2 STOPPED USER", sent.last())
        assertNull(c.running.value)
        assertTrue(!c.active.value)
    }

    @Test
    fun switchOffStopsWithTurnedOff() = runTest {
        val c = controller()
        c.onStart(start(1))
        advanceUntilIdle()
        c.stopAll(MirrorReason.MIRROR_REASON_TURNED_OFF)
        advanceUntilIdle()
        assertEquals("state 1 STOPPED TURNED_OFF", sent.last())
        assertTrue(sent.none { it.startsWith("stop") })
        assertNull(c.running.value)
    }

    @Test
    fun disconnectStopsWithoutMessage() = runTest {
        val c = controller()
        c.onStart(start(1))
        advanceUntilIdle()
        val before = sent.toList()
        c.stopAll(null)
        advanceUntilIdle()
        assertEquals(before, sent)
        assertEquals(listOf<Pair<MirrorReason?, Boolean>>(null to false), runs[0].stops)
        assertNull(c.running.value)
        assertTrue(!c.active.value)
        c.stopAll(null) // nothing running: nothing happens
    }

    @Test
    fun notificationStopTellsMac() = runTest {
        val c = controller()
        c.onStart(start(3))
        advanceUntilIdle()
        c.stopFromPhone()
        advanceUntilIdle()
        assertEquals(listOf("stop 3 USER", "state 3 STOPPED USER"), sent.takeLast(2))
        assertNull(c.running.value)
    }

    @Test
    fun testPatternRunsAmStartOnlyWhileRunning() = runTest {
        reachesRunning = false
        val c = controller()
        c.onStart(start(1))
        advanceUntilIdle()
        c.onTestPattern(pattern(1, TestPatternMode.TEST_PATTERN_MODE_DELAY))
        advanceUntilIdle()
        assertTrue(shells.isEmpty(), "not while starting")

        reachesRunning = true
        c.onStart(start(2))
        advanceUntilIdle()
        c.onTestPattern(pattern(1, TestPatternMode.TEST_PATTERN_MODE_DELAY)) // another session
        advanceUntilIdle()
        assertTrue(shells.isEmpty())
        c.onTestPattern(pattern(2, TestPatternMode.TEST_PATTERN_MODE_DELAY))
        advanceUntilIdle()
        assertEquals(listOf("am start -n io.github.anmirror.phone/.mirror.DelayTestActivity --ei mode 1"), shells)
        assertEquals(TestPatternMode.TEST_PATTERN_MODE_DELAY, c.testPattern.value)
        c.onTestPattern(pattern(2, TestPatternMode.TEST_PATTERN_MODE_FPS))
        advanceUntilIdle()
        assertEquals("am start -n io.github.anmirror.phone/.mirror.DelayTestActivity --ei mode 2", shells.last())
        assertEquals(TestPatternMode.TEST_PATTERN_MODE_FPS, c.testPattern.value)
        c.onTestPattern(pattern(2, TestPatternMode.TEST_PATTERN_MODE_OFF))
        advanceUntilIdle()
        assertEquals(TestPatternMode.TEST_PATTERN_MODE_OFF, c.testPattern.value)
        assertEquals(2, shells.size)

        c.onTestPattern(pattern(2, TestPatternMode.TEST_PATTERN_MODE_DELAY))
        advanceUntilIdle()
        c.stopAll(MirrorReason.MIRROR_REASON_TURNED_OFF)
        advanceUntilIdle()
        assertEquals(TestPatternMode.TEST_PATTERN_MODE_OFF, c.testPattern.value, "the session's end finishes it")
    }
}
