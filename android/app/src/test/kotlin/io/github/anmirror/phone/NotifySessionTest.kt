package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.ActionResult
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NotifySessionTest {
    private fun result(outcome: ActionOutcome) = ActionResult.newBuilder().setKey("k").setOutcome(outcome).build()

    @Test
    fun invokeWhileOffAnswersFailed() = runBlocking {
        var called = false
        val r = answerInvoke("k", sharedNotify = true, open = false) { called = true; result(ActionOutcome.ACTION_OUTCOME_OK) }
        assertEquals(ActionOutcome.ACTION_OUTCOME_FAILED, r?.outcome)
        assertEquals("k", r?.key)
        assertEquals(false, called)
        assertNull(answerInvoke("k", sharedNotify = false, open = false) { result(ActionOutcome.ACTION_OUTCOME_OK) })
    }

    @Test
    fun invokeWhileOnAnswersBridgeResult() = runBlocking {
        val r = answerInvoke("k", sharedNotify = true, open = true) { result(ActionOutcome.ACTION_OUTCOME_GONE) }
        assertEquals(ActionOutcome.ACTION_OUTCOME_GONE, r?.outcome)
    }

    @Test
    fun noSnapshotWhileListenerUnbound() = runBlocking {
        var resyncs = 0
        val s = NotifySession { resyncs++ }
        s.filterApplied(listenerBound = false)
        s.enabled(listenerBound = false)
        assertEquals(0, resyncs)
    }

    @Test
    fun bindingAfterFilterResyncs() = runBlocking {
        var resyncs = 0
        val s = NotifySession { resyncs++ }
        s.filterApplied(listenerBound = false)
        s.listenerBound()
        assertEquals(1, resyncs)
        s.filterApplied(listenerBound = true) // later filters do not resync
        assertEquals(1, resyncs)
    }

    @Test
    fun bindingBeforeFilterWaitsForFilter() = runBlocking {
        var resyncs = 0
        val s = NotifySession { resyncs++ }
        s.listenerBound()
        assertEquals(0, resyncs)
        s.filterApplied(listenerBound = true)
        assertEquals(1, resyncs)
        s.reset()
        s.listenerBound()
        assertEquals(1, resyncs)
    }
}
