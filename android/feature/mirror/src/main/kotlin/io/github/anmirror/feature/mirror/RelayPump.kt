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

    /**
     * Runs until [from] ends or either side fails, then calls [onEnd] once: null at EOF, the read
     * failure, or [WriteFailed]. Returns the bytes copied.
     */
    fun run(from: InputStream, to: OutputStream, onEnd: (Throwable?) -> Unit): Long {
        val buffer = ByteArray(BUFFER_BYTES)
        var copied = 0L
        var end: Throwable? = null
        try {
            while (true) {
                val n = from.read(buffer)
                if (n < 0) break
                if (n == 0) continue
                try {
                    to.write(buffer, 0, n)
                    to.flush()
                } catch (e: IOException) {
                    end = WriteFailed(e)
                    break
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
