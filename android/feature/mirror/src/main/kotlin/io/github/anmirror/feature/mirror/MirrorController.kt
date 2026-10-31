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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** What [MirrorController] drives: a [MirrorSession] on the phone, a fake in tests. */
interface MirrorRun {
    /** Reports STARTING, RUNNING and the end through the report it was made with; returns once all is closed. */
    suspend fun run()

    /**
     * Ends the session (idempotent): STOPPED with [reason], nothing when null (a disconnect). With
     * [drainControl] (the Mac's own stop) the Mac's last control bytes reach the helper first.
     */
    fun stop(reason: MirrorReason?, drainControl: Boolean = false)
}

/**
 * The phone's side of `mirror.*` (SPEC 24): one session at a time. A start while [open] is not
 * enabled is answered with FAILED only; a new start replaces the session in progress (STOPPED
 * REPLACED), and begins once that one has closed. States, stops and test patterns for any other
 * session are ignored. [newSession] makes a session that reports through the given function.
 */
class MirrorController(
    private val open: () -> FeatureAvailability,
    private val newSession: (MirrorStart, suspend (MirrorState) -> Unit) -> MirrorRun,
    private val sendState: suspend (MirrorState) -> Unit,
    private val sendStop: suspend (MirrorStop) -> Unit,
    private val shell: suspend (String) -> Unit,
    private val scope: CoroutineScope,
    private val log: (String) -> Unit = {},
) {
    private class Entry(val start: MirrorStart) {
        lateinit var run: MirrorRun
    }

    private val lock = Any()
    private var current: Entry? = null
    private var last: Job? = null

    private val _running = MutableStateFlow<MirrorStart?>(null)

    /** The session the Mac is showing (RUNNING until it ends); null otherwise. */
    val running: StateFlow<MirrorStart?> = _running.asStateFlow()

    private val _active = MutableStateFlow(false)

    /** A session is in progress, from its start until it has closed everything. */
    val active: StateFlow<Boolean> = _active.asStateFlow()

    private val _testPattern = MutableStateFlow(TestPatternMode.TEST_PATTERN_MODE_OFF)

    /** The test screen the running session asked for; the activity finishes when it turns OFF. */
    val testPattern: StateFlow<TestPatternMode> = _testPattern.asStateFlow()

    fun onStart(s: MirrorStart) {
        val availability = open()
        if (!availability.enabled) {
            log("session ${s.session} refused ${availability.reason.name}")
            answerFailed(s.session, closedReason(availability.reason))
            return
        }
        synchronized(lock) {
            current?.run?.stop(MirrorReason.MIRROR_REASON_REPLACED)
            val entry = Entry(s)
            entry.run = try {
                newSession(s) { state -> onReport(entry, state) }
            } catch (e: Exception) {
                // No ADB identity (Full mode was forgotten meanwhile).
                log("session ${s.session} not made ${e.javaClass.simpleName}")
                answerFailed(s.session, MirrorReason.MIRROR_REASON_NEEDS_SETUP)
                return
            }
            val previous = last
            current = entry
            _active.value = true
            last = scope.launch {
                previous?.join() // its pkill must not meet this session's helper
                try {
                    entry.run.run()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    log("session ${s.session} crashed ${e.javaClass.simpleName}")
                } finally {
                    finished(entry)
                }
            }
        }
    }

    fun onStop(s: MirrorStop) {
        val entry = synchronized(lock) { current?.takeIf { it.start.session == s.session } } ?: return
        val reason = s.reason.takeIf { it != MirrorReason.MIRROR_REASON_UNSPECIFIED && it != MirrorReason.UNRECOGNIZED }
            ?: MirrorReason.MIRROR_REASON_USER
        entry.run.stop(reason, drainControl = true)
    }

    fun onTestPattern(t: MirrorTestPattern) {
        if (_running.value?.session != t.session) return
        when (t.mode) {
            TestPatternMode.TEST_PATTERN_MODE_DELAY, TestPatternMode.TEST_PATTERN_MODE_FPS -> {
                _testPattern.value = t.mode
                val mode = if (t.mode == TestPatternMode.TEST_PATTERN_MODE_DELAY) 1 else 2
                scope.launch {
                    try {
                        shell("am start -n $DELAY_TEST_COMPONENT --ei mode $mode")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        log("test pattern failed ${e.javaClass.simpleName}")
                    }
                }
            }
            else -> _testPattern.value = TestPatternMode.TEST_PATTERN_MODE_OFF
        }
    }

    /** The notification's Stop: `mirror.stop{USER}` to the Mac, then the session ends. */
    fun stopFromPhone() {
        val entry = synchronized(lock) { current } ?: return
        scope.launch {
            sendStop(MirrorStop.newBuilder().setSession(entry.start.session).setReason(MirrorReason.MIRROR_REASON_USER).build())
            entry.run.stop(MirrorReason.MIRROR_REASON_USER)
        }
    }

    /** Ends the session in progress: STOPPED with [reason], or nothing at all (null: the Mac disconnected). */
    fun stopAll(reason: MirrorReason?) {
        synchronized(lock) { current }?.run?.stop(reason)
    }

    private suspend fun onReport(entry: Entry, state: MirrorState) {
        when (state.phase) {
            MirrorPhase.MIRROR_PHASE_RUNNING -> synchronized(lock) { if (current === entry) _running.value = entry.start }
            MirrorPhase.MIRROR_PHASE_STOPPED, MirrorPhase.MIRROR_PHASE_FAILED -> ended(entry)
            else -> Unit
        }
        sendState(state)
    }

    /** [entry] is no longer shown: no running line, notification or test screen. */
    private fun ended(entry: Entry) = synchronized(lock) {
        if (_running.value === entry.start) {
            _running.value = null
            _testPattern.value = TestPatternMode.TEST_PATTERN_MODE_OFF
        }
    }

    private fun finished(entry: Entry) = synchronized(lock) {
        ended(entry)
        if (current === entry) {
            current = null
            _active.value = false
        }
    }

    private fun answerFailed(session: Int, reason: MirrorReason) {
        val state = MirrorState.newBuilder().setSession(session).setPhase(MirrorPhase.MIRROR_PHASE_FAILED).setReason(reason).build()
        scope.launch { sendState(state) }
    }

    companion object {
        /** `am start` runs as the shell, which may start activities from the background. */
        const val DELAY_TEST_COMPONENT = "io.github.anmirror.phone/.mirror.DelayTestActivity"

        /** The FAILED reason for a start while closed, from the availability's reason. */
        fun closedReason(reason: AvailabilityReason): MirrorReason = when (reason) {
            AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER -> MirrorReason.MIRROR_REASON_TURNED_OFF
            AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE -> MirrorReason.MIRROR_REASON_UNAVAILABLE
            else -> MirrorReason.MIRROR_REASON_NEEDS_SETUP
        }
    }
}
