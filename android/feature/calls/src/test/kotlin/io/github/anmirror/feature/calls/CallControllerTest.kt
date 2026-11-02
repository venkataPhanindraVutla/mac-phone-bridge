package io.github.anmirror.feature.calls

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.CallAction
import io.github.anmirror.protocol.v1.CallCommand
import io.github.anmirror.protocol.v1.CallCommandOutcome
import io.github.anmirror.protocol.v1.CallPhase
import io.github.anmirror.protocol.v1.CallState
import io.github.anmirror.protocol.v1.MissedCall
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class FakeSource : CallStateSource {
    var onChange: ((TelephonyPhase, String?) -> Unit)? = null
    var stopped = false
    var starts = 0
    var stops = 0
    override fun start(onChange: (TelephonyPhase, String?) -> Unit) { this.onChange = onChange; starts++ }
    override fun stop() { stopped = true; stops++ }
    fun emit(phase: TelephonyPhase, number: String? = null) = onChange!!(phase, number)
}

private class FakeActions(
    var answerOk: Boolean = true,
    var endOk: Boolean = true,
    var available: Boolean = true,
) : CallActions {
    val log = mutableListOf<String>()
    override fun isAvailable() = available
    override fun answer(): Boolean { log += "answer"; return answerOk }
    override fun end(): Boolean { log += "end"; return endOk }
}

private class FakeMic(var applyMute: Boolean = true) : MicMute {
    var muted: Boolean? = false
    override fun setMuted(muted: Boolean): Boolean { if (applyMute) this.muted = muted; return true }
    override fun isMuted(): Boolean? = muted
}

private class FakeLookup(var answer: Boolean?) : MissedCallLookup {
    var asked: Pair<String?, Long>? = null
    var lookups = 0
    /** Answers given first, one per lookup, before [answer]. */
    val queued = ArrayDeque<Boolean?>()
    override fun wasMissed(number: String?, sinceMs: Long): Boolean? {
        asked = number to sinceMs
        lookups++
        return if (queued.isEmpty()) answer else queued.removeFirst()
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
private class Rig(scope: CoroutineScope, dispatcher: CoroutineDispatcher) {
    val source = FakeSource()
    val primary = FakeActions()
    val fallback = FakeActions()
    val mic = FakeMic()
    var lookup: FakeLookup? = FakeLookup(null)
    var title: String? = null
    var now = 1_000L
    var ids = 0
    val states = mutableListOf<CallState>()
    val missed = mutableListOf<MissedCall>()
    var primaryOn = true
    val controller by lazy {
        CallController(
            source = source,
            primary = if (primaryOn) primary else null,
            fallback = fallback,
            mic = mic,
            missed = lookup,
            notificationNumber = { title },
            clock = { now },
            newId = { "call-${++ids}" },
            send = { type: String, m: MessageLite ->
                when (type) {
                    MessageType.CALLS_STATE -> states += m as CallState
                    MessageType.CALLS_MISSED -> missed += m as MissedCall
                    else -> error("unexpected $type")
                }
                true
            },
            scope = scope,
            io = dispatcher,
            lookupDelayMs = 0,
            lookupRetryMs = 0,
        )
    }

    fun begin() = controller.start()
    fun cmd(id: String, a: CallAction) = CallCommand.newBuilder().setCallId(id).setAction(a).build()
    val last get() = states.last()
}

@OptIn(ExperimentalCoroutinesApi::class)
private fun test(setup: Rig.() -> Unit = {}, body: suspend Rig.() -> Unit) {
    val d = UnconfinedTestDispatcher()
    runTest(d) {
        val rig = Rig(backgroundScope, d)
        rig.setup()
        rig.begin()
        rig.body()
    }
}

class CallControllerTest {
    @Test fun ringingThenOffhookIsActive() = test {
        source.emit(TelephonyPhase.RINGING, "+911234")
        assertEquals(CallPhase.CALL_PHASE_RINGING, last.phase)
        assertTrue(last.incoming)
        assertTrue(last.canAnswer)
        assertEquals("+911234", last.number)
        assertEquals("call-1", last.callId)
        now = 5_000
        source.emit(TelephonyPhase.OFFHOOK, "+911234")
        assertEquals(CallPhase.CALL_PHASE_ACTIVE, last.phase)
        assertEquals("call-1", last.callId)
        assertEquals(5_000L, last.sinceMs)
        assertEquals(CallPhase.CALL_PHASE_ACTIVE, controller.current.value?.phase)
    }

    @Test fun outgoingCallIsActiveNotIncoming() = test {
        source.emit(TelephonyPhase.OFFHOOK, "+911234")
        assertEquals(CallPhase.CALL_PHASE_ACTIVE, last.phase)
        assertFalse(last.incoming)
        assertFalse(last.canAnswer)
    }

    @Test fun endedIsSentOnce() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        source.emit(TelephonyPhase.IDLE)
        source.emit(TelephonyPhase.IDLE)
        assertEquals(1, states.count { it.phase == CallPhase.CALL_PHASE_ENDED })
        assertEquals(CallPhase.CALL_PHASE_ENDED, last.phase)
        assertNull(controller.current.value)
    }

    @Test fun answerUsesPrimaryThenFallback() = test {
        source.emit(TelephonyPhase.RINGING, "1")
        val id = last.callId
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(id, CallAction.CALL_ACTION_ANSWER)).outcome)
        assertEquals(listOf("answer"), primary.log)
        assertTrue(fallback.log.isEmpty())

        primary.answerOk = false
        val r = controller.onCommand(cmd(id, CallAction.CALL_ACTION_ANSWER))
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, r.outcome)
        assertEquals(id, r.callId)
        assertEquals(listOf("answer"), fallback.log)

        fallback.answerOk = false
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_FAILED, controller.onCommand(cmd(id, CallAction.CALL_ACTION_ANSWER)).outcome)
    }

    @Test fun declineOnlyWhileRinging() = test {
        source.emit(TelephonyPhase.RINGING, "1")
        val id = last.callId
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(id, CallAction.CALL_ACTION_HANG_UP)).outcome)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(id, CallAction.CALL_ACTION_DECLINE)).outcome)
        source.emit(TelephonyPhase.OFFHOOK, "1")
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(id, CallAction.CALL_ACTION_DECLINE)).outcome)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(id, CallAction.CALL_ACTION_ANSWER)).outcome)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(id, CallAction.CALL_ACTION_HANG_UP)).outcome)
    }

    @Test fun commandOnEndedCallReturnsNoSuchCall() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val id = last.callId
        source.emit(TelephonyPhase.IDLE)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NO_SUCH_CALL, controller.onCommand(cmd(id, CallAction.CALL_ACTION_HANG_UP)).outcome)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NO_SUCH_CALL, controller.onCommand(cmd("nope", CallAction.CALL_ACTION_MUTE)).outcome)
    }

    @Test fun noActionsAvailableIsNotAllowed() = test(setup = { primaryOn = false; fallback.available = false }) {
        source.emit(TelephonyPhase.RINGING, "1")
        val r = controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_ANSWER))
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, r.outcome)
        assertTrue(fallback.log.isEmpty())
    }

    @Test fun muteReadBackSetsSupported() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val id = last.callId
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(id, CallAction.CALL_ACTION_MUTE)).outcome)
        assertTrue(last.muted)
        assertTrue(last.muteSupported)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(id, CallAction.CALL_ACTION_UNMUTE)).outcome)
        assertFalse(last.muted)
        assertTrue(last.muteSupported)
    }

    @Test fun muteReadBackMismatchMarksUnsupported() = test {
        mic.applyMute = false
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val r = controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_MUTE))
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_FAILED, r.outcome)
        assertFalse(last.muted)
        assertFalse(last.muteSupported)
    }

    @Test fun missedWhenRangOutUnanswered() = test {
        now = 2_000
        source.emit(TelephonyPhase.RINGING, "+911234")
        now = 9_000
        source.emit(TelephonyPhase.IDLE)
        assertEquals(1, missed.size)
        assertEquals("+911234", missed[0].number)
        assertEquals(9_000L, missed[0].atMs)
        assertEquals(2_000L, lookup!!.asked!!.second)
        assertEquals(CallPhase.CALL_PHASE_ENDED, last.phase)
    }

    @Test fun notMissedWhenDeclinedFromMac() = test {
        source.emit(TelephonyPhase.RINGING, "1")
        controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_DECLINE))
        source.emit(TelephonyPhase.IDLE)
        assertTrue(missed.isEmpty())
    }

    @Test fun notMissedWhenAnswered() = test {
        source.emit(TelephonyPhase.RINGING, "1")
        source.emit(TelephonyPhase.OFFHOOK, "1")
        source.emit(TelephonyPhase.IDLE)
        assertTrue(missed.isEmpty())
    }

    @Test fun callLogSaysNotMissed() = test {
        lookup!!.answer = false
        source.emit(TelephonyPhase.RINGING, "1")
        source.emit(TelephonyPhase.IDLE)
        assertTrue(missed.isEmpty())
        assertEquals(2, lookup!!.lookups) // asked again once before giving up
    }

    @Test fun callLogWrittenLateIsFoundOnRetry() = test {
        lookup!!.queued += listOf(false, true)
        source.emit(TelephonyPhase.RINGING, "+911234")
        source.emit(TelephonyPhase.IDLE)
        assertEquals(listOf("+911234"), missed.map { it.number })
        assertEquals(2, lookup!!.lookups)
    }

    @Test fun missedCallIsLookedUpOnceWhenFound() = test {
        lookup!!.answer = true
        source.emit(TelephonyPhase.RINGING, "1")
        source.emit(TelephonyPhase.IDLE)
        assertEquals(1, missed.size)
        assertEquals(1, lookup!!.lookups)
    }

    @Test fun numberFallsBackToNotification() = test {
        title = "+91 98765 43210"
        source.emit(TelephonyPhase.RINGING, null)
        assertEquals("+91 98765 43210", last.number)
        assertEquals("", last.displayName)
        title = "Asha Rao"
        source.emit(TelephonyPhase.OFFHOOK, null)
        assertEquals("Asha Rao", last.displayName)
        assertEquals("+91 98765 43210", last.number)
    }

    @Test fun secondRingingDuringActiveIsReported() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val first = last.callId
        source.emit(TelephonyPhase.RINGING, "2")
        assertEquals(CallPhase.CALL_PHASE_RINGING, last.phase)
        assertNotEqualsId(first, last.callId)
        assertFalse(last.canAnswer)
        assertTrue(last.incoming)
        // The first call is still tracked: it can be hung up, the waiting one cannot be answered.
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_ANSWER)).outcome)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(first, CallAction.CALL_ACTION_HANG_UP)).outcome)
        assertEquals(first, controller.current.value?.callId)
    }

    @Test fun connectResendsCurrentCall() = test {
        controller.onConnected()
        assertTrue(states.isEmpty())
        source.emit(TelephonyPhase.OFFHOOK, "1")
        states.clear()
        controller.onConnected()
        assertEquals(1, states.size)
        assertEquals(CallPhase.CALL_PHASE_ACTIVE, last.phase)
    }

    @Test fun stopStopsTheSource() = test {
        controller.stop()
        assertTrue(source.stopped)
    }

    @Test fun declineOnWaitingCallIsNotAllowed() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        source.emit(TelephonyPhase.RINGING, "2")
        val waiting = last.callId
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(waiting, CallAction.CALL_ACTION_DECLINE)).outcome)
        assertTrue(primary.log.isEmpty() && fallback.log.isEmpty())
    }

    @Test fun muteWorksWithoutPrimary() = test(setup = { primaryOn = false }) {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_MUTE)).outcome)
        assertTrue(last.muted)
    }

    @Test fun identityResolvesWhenNotificationArrivesAfterRinging() = test {
        source.emit(TelephonyPhase.RINGING, null)
        assertEquals("", last.number)
        title = "+91 98765 43210"
        controller.refreshIdentity()
        assertEquals("+91 98765 43210", last.number)
        assertEquals(CallPhase.CALL_PHASE_RINGING, last.phase)
        // The missed call carries it too.
        source.emit(TelephonyPhase.IDLE)
        assertEquals("+91 98765 43210", missed.single().number)
    }

    @Test fun identityDoesNotLeakToOtherCall() = test {
        title = "Asha Rao"
        source.emit(TelephonyPhase.OFFHOOK, null)
        val first = last.callId
        assertEquals("Asha Rao", last.displayName)
        source.emit(TelephonyPhase.RINGING, null)
        assertEquals("", last.displayName)
        controller.refreshIdentity()
        assertEquals(1, states.count { it.callId == last.callId })
        assertEquals("", last.displayName)
        assertEquals("Asha Rao", controller.current.value?.displayName)
        assertEquals(first, controller.current.value?.callId)
    }

    @Test fun reconnectKeepsTheSameCallId() = test {
        val runtime = CallsRuntime { controller }
        assertTrue(runtime.update(on = true, granted = true))
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val id = last.callId
        // A reconnect changes nothing about the switch or the permission: no new controller.
        assertFalse(runtime.update(on = true, granted = true))
        states.clear()
        runtime.controller!!.onConnected()
        assertEquals(listOf(id), states.map { it.callId })
        assertFalse(states.single().incoming)
        runtime.update(on = true, granted = false)
        assertNull(runtime.controller)
        assertTrue(source.stopped)
    }

    @Test fun sameStateRedeliveryIsNoOp() = test {
        source.emit(TelephonyPhase.OFFHOOK, "1")
        val n = states.size
        source.emit(TelephonyPhase.OFFHOOK, "1")
        assertEquals(n, states.size)
        source.emit(TelephonyPhase.IDLE)
        val m = states.size
        source.emit(TelephonyPhase.IDLE)
        assertEquals(m, states.size)
    }

    @Test fun callLogGrantRestartsSourceKeepingCallId() = test {
        val runtime = CallsRuntime { controller }
        runtime.update(on = true, granted = true)
        source.emit(TelephonyPhase.RINGING, null)
        val id = last.callId
        val starts = source.starts
        runtime.restartSource()
        assertEquals(starts + 1, source.starts)
        // The new listener delivers the same phase, now with the number.
        source.emit(TelephonyPhase.RINGING, "+911234")
        assertEquals(id, last.callId)
        assertEquals("+911234", last.number)
        assertEquals(1, states.map { it.callId }.distinct().size)
    }

    @Test fun cannotAnswerWhenNothingCanAnswer() = test({ primary.available = false; fallback.available = false }) {
        source.emit(TelephonyPhase.RINGING, "+911234")
        assertFalse(last.canAnswer)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED, controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_ANSWER)).outcome)
    }

    @Test fun canAnswerTurnsOnWhenTheDialerNotificationAppears() = test({ primary.available = false; fallback.available = false }) {
        source.emit(TelephonyPhase.RINGING, "+911234")
        assertFalse(last.canAnswer)
        fallback.available = true // the dialer's CallStyle notification was posted
        controller.refreshIdentity()
        assertTrue(last.canAnswer)
        assertEquals(CallCommandOutcome.CALL_COMMAND_OUTCOME_OK, controller.onCommand(cmd(last.callId, CallAction.CALL_ACTION_ANSWER)).outcome)
    }

    @Test fun canAnswerWithOnlyThePermissionPath() = test({ fallback.available = false }) {
        source.emit(TelephonyPhase.RINGING, "+911234")
        assertTrue(last.canAnswer)
    }

    private fun assertNotEqualsId(a: String, b: String) = assertTrue(a != b)
}
