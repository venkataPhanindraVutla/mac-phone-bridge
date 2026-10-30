package io.github.anmirror.feature.media

import io.github.anmirror.protocol.v1.MediaState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * At most one `media.state` per [minIntervalMs] (4 per second), leading and trailing edge: the
 * first state after [minIntervalMs] without one goes at once; later ones inside the interval
 * coalesce, and the latest goes when the interval ends. Emits never overlap.
 */
class StateThrottle(
    private val scope: CoroutineScope,
    private val minIntervalMs: Long = 250,
    private val clock: () -> Long,
    private val emit: suspend (MediaState) -> Unit,
) {
    private val lock = Any()
    private val emitting = Mutex()

    // Guarded by [lock].
    private var lastEmitAt: Long? = null
    private var pending: MediaState? = null
    private var trailing: Job? = null

    /** Bumped by [reset]: an emit started before it is dropped. */
    @Volatile private var generation = 0

    fun offer(state: MediaState) {
        val gen: Int
        synchronized(lock) {
            val now = clock()
            val last = lastEmitAt
            if (trailing != null || (last != null && now - last < minIntervalMs)) {
                pending = state
                if (trailing == null) {
                    val wait = last!! + minIntervalMs - now
                    trailing = scope.launch { trailingEdge(wait) }
                }
                return
            }
            lastEmitAt = now
            gen = generation
        }
        // Undispatched: the state is on its way (in order) before offer returns.
        scope.launch(start = CoroutineStart.UNDISPATCHED) { deliver(state, gen) }
    }

    /** Forgets the pending state and the last emit time: the next offer goes at once. */
    fun reset() {
        synchronized(lock) {
            generation++
            trailing?.cancel()
            trailing = null
            pending = null
            lastEmitAt = null
        }
    }

    private suspend fun trailingEdge(wait: Long) {
        delay(wait)
        val gen: Int
        val state = synchronized(lock) {
            val s = pending
            pending = null
            trailing = null
            lastEmitAt = clock()
            gen = generation
            s
        } ?: return
        deliver(state, gen)
    }

    private suspend fun deliver(state: MediaState, gen: Int) {
        emitting.withLock { if (gen == generation) emit(state) }
    }
}
