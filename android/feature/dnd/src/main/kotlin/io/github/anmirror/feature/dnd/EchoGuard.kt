package io.github.anmirror.feature.dnd

/** How a local transition relates to the last state applied from the Mac (SPEC 21). */
enum class Echo {
    /** The applied state, reported back within the window: not sent. */
    SUPPRESS,

    /** The applied state, reported back after the window with no other transition in between: sent as `SYNC`. */
    SYNC,

    /** Anything else: sent as `USER`. */
    USER,
}

/**
 * Remembers the last state applied from the Mac and when, and classifies the next local
 * transition against it. Any classified transition ends the match, so only the first one after an
 * apply can be an echo. Not thread-safe: the caller serializes.
 */
class EchoGuard(private val windowMs: Long = 10_000) {
    private var appliedOn: Boolean? = null
    private var appliedAtMs = 0L

    fun applied(on: Boolean, nowMs: Long) {
        appliedOn = on
        appliedAtMs = nowMs
    }

    fun classify(on: Boolean, nowMs: Long): Echo {
        val matched = appliedOn == on
        appliedOn = null
        return when {
            !matched -> Echo.USER
            nowMs - appliedAtMs < windowMs -> Echo.SUPPRESS
            else -> Echo.SYNC
        }
    }
}
