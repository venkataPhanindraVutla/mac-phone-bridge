package io.github.anmirror.feature.mirror

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * Copies one direction of a mirror stream: blocking reads into one [BUFFER_BYTES] buffer, each
 * chunk written and flushed before the next read, no queue. A slow reader on the far side
 * therefore holds the helper back instead of piling bytes up here.
 */
object RelayPump {
    const val BUFFER_BYTES = 65_536

    /** The write side failed; the read side is fine (so the far end of [run]'s `to` went away). */
    class WriteFailed(cause: IOException) : IOException(cause)

    /** How long the write in progress has been blocked, by [clock] (ms); 0 between writes. */
    class WriteMeter(private val clock: () -> Long) {
        @Volatile private var since = IDLE

        fun blockedMs(): Long = since.let { if (it == IDLE) 0L else (clock() - it).coerceAtLeast(0L) }

        internal fun begin() {
            since = clock()
        }

        internal fun end() {
            since = IDLE
        }

        private companion object {
            const val IDLE = Long.MIN_VALUE
        }
    }

    /**
     * Runs until [from] ends or either side fails, then calls [onEnd] once: null at EOF, the read
     * failure, or [WriteFailed]. [meter] times each write and flush. Returns the bytes copied.
     */
    fun run(from: InputStream, to: OutputStream, meter: WriteMeter? = null, onEnd: (Throwable?) -> Unit): Long {
        val buffer = ByteArray(BUFFER_BYTES)
        var copied = 0L
        var end: Throwable? = null
        try {
            while (true) {
                val n = from.read(buffer)
                if (n < 0) break
                if (n == 0) continue
                try {
                    meter?.begin()
                    to.write(buffer, 0, n)
                    to.flush()
                } catch (e: IOException) {
                    end = WriteFailed(e)
                    break
                } finally {
                    meter?.end()
                }
                copied += n
            }
        } catch (e: Exception) {
            end = e
        }
        onEnd(end)
        return copied
    }
}
