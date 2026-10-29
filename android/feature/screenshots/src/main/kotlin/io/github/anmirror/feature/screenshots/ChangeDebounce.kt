package io.github.anmirror.feature.screenshots

/**
 * When to look after a MediaStore change: [quietMs] after the last change, but never more than
 * [maxWaitMs] after the first one of a burst, so an app syncing photos can't keep pushing a
 * screenshot past the detector's 30 s window. Not thread-safe: use from one thread.
 */
class ChangeDebounce(private val quietMs: Long, private val maxWaitMs: Long, private val clock: () -> Long) {
    /** When the first change since the last look came; null when none is waiting. */
    private var firstAt: Long? = null

    /** A change: returns how long to wait before looking (replacing any earlier wait). */
    fun onChange(): Long {
        val now = clock()
        val first = firstAt ?: now.also { firstAt = it }
        return minOf(quietMs, maxOf(0, first + maxWaitMs - now))
    }

    /** The look ran (or was called off): the next change starts a new burst. */
    fun fired() {
        firstAt = null
    }
}
