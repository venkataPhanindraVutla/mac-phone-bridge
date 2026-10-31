package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import kotlin.coroutines.CoroutineContext

/**
 * Puts the helper jar on the phone before every session, at the session's own path: old leftover
 * jars are swept first ([ServerCommand.sweepStaleJars]), then `exec:cat > <path>`, then
 * `sha256sum` against [sha256] up to [VERIFY_TRIES] times, [VERIFY_GAP_MS] apart (the write may
 * still be landing). [io] runs the blocking copy.
 */
class HelperInstaller(
    private val adb: AdbClient,
    private val jar: () -> InputStream,
    private val sha256: String,
    private val io: CoroutineContext = Dispatchers.IO,
) {
    /**
     * Pushes to [path] and checks it. The push pipe goes to [register] (the session's close group,
     * review M4), so a stop or deadline that closes the group ends a push adbd stopped answering;
     * false means the session already ended. Throws [IOException] when the push fails or the jar on
     * the phone never matches.
     */
    suspend fun install(path: String, register: (Closeable) -> Boolean) {
        // Fail closed: an empty expected hash must not match an empty sha256sum.
        if (!SHA256_HEX.matches(sha256)) throw IOException("expected helper hash is not a SHA-256")
        try {
            adb.shell(ServerCommand.sweepStaleJars())
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            // Best effort: leftovers wait for the next session.
        }
        val pipe = adb.open("exec:cat > $path")
        if (!register(pipe)) throw IOException("session ended")
        try {
            withContext(io) {
                jar().use { it.copyTo(pipe.output, BUFFER_BYTES) }
                pipe.output.flush()
            }
        } finally {
            pipe.close()
        }
        val want = sha256.lowercase()
        repeat(VERIFY_TRIES) { attempt ->
            val got = adb.shell("sha256sum $path").trim().substringBefore(' ').lowercase()
            if (got == want) return
            if (attempt < VERIFY_TRIES - 1) delay(VERIFY_GAP_MS)
        }
        throw IOException("helper jar does not match")
    }

    companion object {
        const val VERIFY_TRIES = 20
        const val VERIFY_GAP_MS = 200L
        private const val BUFFER_BYTES = 64 * 1024
        private val SHA256_HEX = Regex("[0-9a-fA-F]{64}")
    }
}
