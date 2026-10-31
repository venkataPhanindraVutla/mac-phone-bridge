package io.github.anmirror.feature.mirror

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * When the phone's own ADB link closes: [idleMs] after the last mirror session ends, or after
 * the Full mode setup (or a re-arm) connected with no session; at once when the Mac disconnects,
 * or as soon as the session then in progress ends.
 */
class AdbIdleClose(
    private val scope: CoroutineScope,
    private val close: () -> Unit,
    private val idleMs: Long = IDLE_MS,
) {
    private val lock = Any()
    private var busy = false
    private var closeWhenFree = false
    private var timer: Job? = null

    /** A mirror session is in progress ([on]), or none is. */
    fun busy(on: Boolean) = synchronized(lock) {
        busy = on
        timer?.cancel()
        timer = null
        if (on) return@synchronized
        if (closeWhenFree) {
            closeWhenFree = false
            close()
        } else {
            startTimer()
        }
    }

    /** The setup or a re-arm connected: the link is closed after [idleMs] unless a session holds it. */
    fun connected() = synchronized(lock) {
        if (busy) return@synchronized
        closeWhenFree = false
        timer?.cancel()
        startTimer()
    }

    /** The Mac disconnected: close now, or when the session in progress has ended. */
    fun disconnected() = synchronized(lock) {
        timer?.cancel()
        timer = null
        if (busy) {
            closeWhenFree = true
        } else {
            close()
        }
    }

    private fun startTimer() {
        timer = scope.launch {
            delay(idleMs)
            synchronized(lock) {
                // Superseded meanwhile (a session began, or the wait restarted).
                if (busy || timer !== coroutineContext[Job]) return@launch
                timer = null
            }
            close()
        }
    }

    companion object {
        const val IDLE_MS = 10 * 60 * 1000L
    }
}
