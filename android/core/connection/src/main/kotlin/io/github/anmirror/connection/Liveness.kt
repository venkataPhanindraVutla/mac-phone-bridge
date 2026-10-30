package io.github.anmirror.connection

/** The Mac-driven keep-alive capability (SPEC 7). */
const val LIVENESS_CAPABILITY = "liveness.v1"

/**
 * The keep-alive timers' default clock: monotonic ms. On Android `System.nanoTime` is
 * CLOCK_MONOTONIC, which stops in deep sleep, like coroutine `delay`; time asleep never counts.
 */
val monotonicUptimeMs: () -> Long = { System.nanoTime() / 1_000_000 }

/** What a [PhoneSession]'s pinger does next. */
sealed interface LivenessStep {
    /** Send `system.ping` now, then call [PhoneLiveness.onPingSent]. */
    data object SendPing : LivenessStep

    /** Nothing to do until [atMs], unless something arrives or a ping is requested first. */
    data class WaitUntil(val atMs: Long) : LivenessStep

    /** The ping went unanswered: drop the connection. */
    data object Dead : LivenessStep
}

/**
 * The phone's keep-alive rules for one connection (SPEC 7), as a clock-free state machine.
 *
 * - Legacy ([macDriven] false, `liveness.v1` not shared): a ping [pingIntervalMs] after the
 *   connection starts or the last pong; only a `system.pong` answers it, within [pongTimeoutMs].
 * - Mac-driven (`liveness.v1` shared): the Mac pings, so the phone pings only after
 *   [fallbackIdleMs] with nothing received. Any incoming envelope answers that ping, within
 *   [pongTimeoutMs].
 * - [requestPing] (a kick) pings at once in both modes. A ping already waiting for its answer
 *   covers the kick: no second ping, and its deadline stays.
 *
 * Times are monotonic uptime ms (stop in deep sleep, like coroutine delay): time asleep never counts against the Mac.
 * Thread-safe: the session's reader and pinger call it from different coroutines.
 */
class PhoneLiveness(
    private val macDriven: Boolean,
    private val pingIntervalMs: Long,
    private val fallbackIdleMs: Long,
    private val pongTimeoutMs: Long,
    startMs: Long,
) {
    /** When the idle wait started: the connection start, the last answer, or (Mac-driven) the last envelope. */
    private var quietSinceMs = startMs

    /** When the unanswered ping went out, or null. */
    private var pingSentAtMs: Long? = null

    private var pingRequested = false

    @Synchronized
    fun onIncoming(nowMs: Long, isPong: Boolean) {
        if (macDriven) {
            quietSinceMs = nowMs
            pingSentAtMs = null
        } else if (isPong && pingSentAtMs != null) {
            // 0.1: the next ping is one interval after the pong. A stray pong changes nothing.
            quietSinceMs = nowMs
            pingSentAtMs = null
        }
    }

    @Synchronized
    fun onPingSent(nowMs: Long) {
        pingRequested = false
        if (pingSentAtMs == null) pingSentAtMs = nowMs
    }

    @Synchronized
    fun requestPing() {
        if (pingSentAtMs == null) pingRequested = true
    }

    @Synchronized
    fun next(nowMs: Long): LivenessStep {
        pingSentAtMs?.let { sent ->
            val deadline = sent + pongTimeoutMs
            return if (nowMs >= deadline) LivenessStep.Dead else LivenessStep.WaitUntil(deadline)
        }
        if (pingRequested) return LivenessStep.SendPing
        val due = quietSinceMs + if (macDriven) fallbackIdleMs else pingIntervalMs
        return if (nowMs >= due) LivenessStep.SendPing else LivenessStep.WaitUntil(due)
    }
}
