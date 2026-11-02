package io.github.anmirror.feature.calls

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.CallAction
import io.github.anmirror.protocol.v1.CallCommand
import io.github.anmirror.protocol.v1.CallCommandOutcome
import io.github.anmirror.protocol.v1.CallCommandResult
import io.github.anmirror.protocol.v1.CallPhase
import io.github.anmirror.protocol.v1.CallState
import io.github.anmirror.protocol.v1.MissedCall
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Turns the phone's call state into `calls.state` / `calls.missed` and carries out the Mac's
 * `calls.command`s (SPEC 12). State changes from [source] and commands from the Mac run one at a
 * time: the source callback only queues, one consumer applies, and [onCommand] takes the same lock.
 *
 * The telephony stack reports one phase for the whole phone, so a waiting call (RINGING while
 * another call is active) cannot be told apart from the end of the active one by phase alone. When
 * the phase goes RINGING -> OFFHOOK with a call already active, the waiting call is closed (it may
 * have been answered, which is not detectable here); the first call stays tracked.
 */
class CallController(
    private val source: CallStateSource,
    /** Telecom actions; null only when answering/ending is switched off in this build (permission is checked live). */
    private val primary: CallActions?,
    /** The dialer notification's CallStyle intents. */
    private val fallback: CallActions,
    /** The microphone mute; independent of the answer permission. */
    private val mic: MicMute,
    /** Null only when the call log is switched off in this build (permission is checked live; null verdict = cannot tell). */
    private val missed: MissedCallLookup?,
    /** Title of the active call notification, if any: a number or a contact name. */
    private val notificationNumber: () -> String?,
    private val clock: () -> Long,
    private val newId: () -> String,
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** The call log is written a moment after the phone goes idle. */
    private val lookupDelayMs: Long = 1_500,
    /** Sometimes later still: a "not missed" is checked once more after this long. */
    private val lookupRetryMs: Long = 2_000,
) {
    /** A phase change from the source, or (phase == null) a nudge to re-read the caller's identity. */
    private class Event(val phase: TelephonyPhase?, val number: String?)

    private class Call(val id: String, val incoming: Boolean, val startedMs: Long) {
        var phase = CallPhase.CALL_PHASE_RINGING
        var number = ""
        var displayName = ""
        var canAnswer = false
        var sinceMs = startedMs
        var muted = false
        var muteSupported = false
        var everActive = false
        var declined = false
        var waiting = false
    }

    private val mutex = Mutex()
    private val events = Channel<Event>(Channel.UNLIMITED)
    private var consumer: Job? = null
    private val calls = mutableListOf<Call>()
    private var lastPhase = TelephonyPhase.IDLE
    private var micMutedByUs = false

    private val _current = MutableStateFlow<CallState?>(null)

    /** The oldest call still in progress, or null. */
    val current: StateFlow<CallState?> = _current.asStateFlow()

    fun start() {
        if (consumer != null) return
        consumer = scope.launch {
            for (event in events) {
                try {
                    mutex.withLock { handle(event) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // One bad event must not end call tracking.
                }
            }
        }
        source.start { phase, number -> events.trySend(Event(phase, number)) }
    }

    /**
     * Re-registers the telephony listener (e.g. READ_CALL_LOG was granted, so a source can now
     * deliver the number) without touching the calls: ids and state survive. The re-registered
     * listener re-delivers the current phase, which is a no-op while it is unchanged.
     */
    fun restartSource() {
        if (consumer == null) return
        source.stop()
        source.start { phase, number -> events.trySend(Event(phase, number)) }
    }

    fun stop() {
        source.stop()
        consumer?.cancel()
        consumer = null
    }

    /** The call notification changed: queue a re-read of the newest call's number / name. */
    fun refreshIdentity() {
        events.trySend(Event(null, null))
    }

    /** The Mac (re)connected: tell it about every call in progress. */
    suspend fun onConnected() = mutex.withLock {
        calls.forEach { send(MessageType.CALLS_STATE, it.toState()) }
    }

    suspend fun onCommand(c: CallCommand): CallCommandResult = mutex.withLock {
        val call = calls.firstOrNull { it.id == c.callId }
        val outcome = if (call == null) CallCommandOutcome.CALL_COMMAND_OUTCOME_NO_SUCH_CALL else execute(call, c.action)
        CallCommandResult.newBuilder().setCallId(c.callId).setOutcome(outcome).build()
    }

    private suspend fun execute(call: Call, action: CallAction): CallCommandOutcome {
        val ringing = call.phase == CallPhase.CALL_PHASE_RINGING
        val active = call.phase == CallPhase.CALL_PHASE_ACTIVE
        return when (action) {
            // End/decline act on the foreground call, never on a waiting one: not offered for it.
            CallAction.CALL_ACTION_ANSWER ->
                if (ringing && call.canAnswer && !call.waiting) attempt { it.answer() } else NOT_ALLOWED
            CallAction.CALL_ACTION_DECLINE ->
                if (ringing && !call.waiting) attempt { it.end() }.also { if (it == OK) call.declined = true } else NOT_ALLOWED
            CallAction.CALL_ACTION_HANG_UP ->
                if (active) attempt { it.end() } else NOT_ALLOWED
            CallAction.CALL_ACTION_MUTE -> if (active) mute(call, true) else NOT_ALLOWED
            CallAction.CALL_ACTION_UNMUTE -> if (active) mute(call, false) else NOT_ALLOWED
            else -> NOT_ALLOWED
        }
    }

    /** Primary first, then the fallback. Nothing to try is NOT_ALLOWED; everything tried failing is FAILED. */
    private fun attempt(op: (CallActions) -> Boolean): CallCommandOutcome {
        val candidates = listOfNotNull(primary, fallback).filter { it.isAvailable() }
        if (candidates.isEmpty()) return NOT_ALLOWED
        return if (candidates.any { op(it) }) OK else FAILED
    }

    private suspend fun mute(call: Call, muted: Boolean): CallCommandOutcome {
        val applied = mic.setMuted(muted)
        val readBack = mic.isMuted()
        call.muteSupported = readBack == muted
        call.muted = readBack ?: call.muted
        if (muted && call.muteSupported) micMutedByUs = true
        send(MessageType.CALLS_STATE, call.toState())
        publish()
        return if (applied && call.muteSupported) OK else FAILED
    }

    private suspend fun handle(e: Event) {
        if (e.phase == null) {
            refreshAnswerability()
            refreshIdentity(null)
            publish()
            return
        }
        val prev = lastPhase
        lastPhase = e.phase
        when (e.phase) {
            TelephonyPhase.RINGING -> when (prev) {
                TelephonyPhase.IDLE -> open(incoming = true, e.number, canAnswer = canAnswerNow(), active = false)
                TelephonyPhase.OFFHOOK -> open(incoming = true, e.number, canAnswer = false, active = false).waiting = true
                TelephonyPhase.RINGING -> Unit
            }
            TelephonyPhase.OFFHOOK -> when (prev) {
                TelephonyPhase.IDLE -> open(incoming = false, e.number, canAnswer = false, active = true)
                TelephonyPhase.RINGING -> {
                    val ringing = calls.lastOrNull { it.phase == CallPhase.CALL_PHASE_RINGING }
                    val active = calls.any { it.phase == CallPhase.CALL_PHASE_ACTIVE }
                    if (ringing != null && !active) {
                        ringing.phase = CallPhase.CALL_PHASE_ACTIVE
                        ringing.canAnswer = false
                        ringing.everActive = true
                        ringing.sinceMs = clock()
                        initMute(ringing)
                        send(MessageType.CALLS_STATE, ringing.toState())
                    } else if (ringing != null) {
                        close(ringing)
                    }
                }
                TelephonyPhase.OFFHOOK -> Unit
            }
            TelephonyPhase.IDLE -> {
                calls.toList().forEach { close(it) }
                if (micMutedByUs) {
                    micMutedByUs = false
                    mic.setMuted(false)
                }
            }
        }
        refreshIdentity(e.number)
        publish()
    }

    private suspend fun open(incoming: Boolean, number: String?, canAnswer: Boolean, active: Boolean): Call {
        val now = clock()
        val call = Call(newId(), incoming, now)
        call.canAnswer = canAnswer
        // The notification is only the caller's while this is the one call; with two it may be the other's.
        val (n, name) = identify(number, useNotification = calls.isEmpty())
        call.number = n
        call.displayName = name
        if (active) {
            call.phase = CallPhase.CALL_PHASE_ACTIVE
            call.everActive = true
            initMute(call)
        }
        calls += call
        send(MessageType.CALLS_STATE, call.toState())
        return call
    }

    /** Answer is offered only when some way to answer exists now: the permission path or the dialer's notification. */
    private fun canAnswerNow(): Boolean =
        // Reading the dialer's notification can throw (unparcelling extras): that must not drop the call.
        runCatching { primary?.isAvailable() == true || fallback.isAvailable() }.getOrDefault(false)

    /** The dialer's notification may appear (or the permission arrive) after the ring began: update the ringing call. */
    private suspend fun refreshAnswerability() {
        val can = canAnswerNow()
        for (call in calls) {
            if (call.phase != CallPhase.CALL_PHASE_RINGING || call.waiting || !call.incoming || call.canAnswer == can) continue
            call.canAnswer = can
            send(MessageType.CALLS_STATE, call.toState())
        }
    }

    /** Mute can be offered when the microphone state can be read at all. */
    private fun initMute(call: Call) {
        val state = mic.isMuted()
        call.muteSupported = state != null
        call.muted = state ?: false
    }

    /** ENDED goes out once, then the call is forgotten; an unanswered, undeclined ring may be a missed call. */
    private suspend fun close(call: Call) {
        calls -= call
        val wasMissedCandidate = !call.everActive && !call.declined
        val ended = call.toState().toBuilder().setPhase(CallPhase.CALL_PHASE_ENDED).setCanAnswer(false).build()
        send(MessageType.CALLS_STATE, ended)
        if (wasMissedCandidate) reportMissed(call)
    }

    private fun reportMissed(call: Call) {
        val ringStart = call.startedMs
        val atMs = clock()
        scope.launch {
            delay(lookupDelayMs)
            val lookup = suspend { withContext(io) { missed?.wasMissed(call.number.ifEmpty { null }, ringStart) } }
            var verdict = lookup()
            if (verdict == false) {
                delay(lookupRetryMs)
                verdict = lookup()
            }
            // A waiting call may have been answered; without a call log to say so, stay quiet about it.
            if (verdict == false || (verdict == null && call.waiting)) return@launch
            send(
                MessageType.CALLS_MISSED,
                MissedCall.newBuilder().setNumber(call.number).setDisplayName(call.displayName).setAtMs(atMs).build(),
            )
        }
    }

    /**
     * The number / name may show up after the first callback (the dialer posts its notification
     * later): fills what is still empty on the newest call only. Other calls are never backfilled.
     */
    private suspend fun refreshIdentity(sourceNumber: String?) {
        val call = calls.lastOrNull() ?: return
        if (call.number.isNotEmpty() && call.displayName.isNotEmpty()) return
        val (n, name) = identify(sourceNumber, useNotification = calls.size == 1)
        val number = call.number.ifEmpty { n }
        val display = call.displayName.ifEmpty { name }
        if (number == call.number && display == call.displayName) return
        call.number = number
        call.displayName = display
        send(MessageType.CALLS_STATE, call.toState())
    }

    /** (number, display name): the number from the source, else from the notification title when it is one. */
    private fun identify(sourceNumber: String?, useNotification: Boolean): Pair<String, String> {
        val title = if (useNotification) notificationNumber()?.trim()?.takeIf { it.isNotEmpty() } else null
        val titleIsNumber = title != null && looksLikeNumber(title)
        val number = sourceNumber?.takeIf { it.isNotBlank() } ?: title.takeIf { titleIsNumber }.orEmpty()
        val name = title.takeIf { !titleIsNumber }.orEmpty()
        return number to name
    }

    private fun publish() {
        _current.value = calls.firstOrNull()?.toState()
    }

    private fun Call.toState(): CallState = CallState.newBuilder()
        .setCallId(id)
        .setPhase(phase)
        .setNumber(number)
        .setDisplayName(displayName)
        .setMuted(muted)
        .setMuteSupported(muteSupported)
        .setCanAnswer(canAnswer)
        .setSinceMs(sinceMs)
        .setIncoming(incoming)
        .build()

    private companion object {
        val OK = CallCommandOutcome.CALL_COMMAND_OUTCOME_OK
        val FAILED = CallCommandOutcome.CALL_COMMAND_OUTCOME_FAILED
        val NOT_ALLOWED = CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED
        val NUMBER_LIKE = Regex("""^[+\d\s().*#-]*\d[+\d\s().*#-]*$""")

        fun looksLikeNumber(s: String) = NUMBER_LIKE.matches(s)
    }
}
