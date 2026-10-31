package io.github.anmirror.adb

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/** The peer on an ADB port did not prove it is this phone's own adbd (ruling R58); its connection was closed. */
class AdbPeerProofException : IOException("adb: the peer did not prove it is this phone's adbd")

/**
 * Proof that an ADB peer is this phone's own adbd (ruling R58). libadb accepts any certificate
 * (or none) from the port it dials, so an app that took a port adbd left could pose as it and
 * receive everything the Mac types. Each new connection therefore runs
 * `am broadcast -a <action> -n <component> --es n <nonce>` over itself, with a fresh 128-bit
 * [nonce][newNonce]. The receiver at [component] requires `android.permission.DUMP`, which the
 * shell (uid 2000, what adbd runs commands as) holds and no other app can be granted, so only a
 * peer that really runs the command as the shell can make the broadcast arrive. The receiver
 * hands the nonce to [deliver]; the connection is accepted only if that happens within
 * [timeoutMs]. No certificate is pinned: adbd's can change.
 */
class AdbPeerProof(
    private val component: String,
    private val action: String,
    private val timeoutMs: Long = TIMEOUT_MS,
    private val random: SecureRandom = SecureRandom(),
) {
    private val pending = ConcurrentHashMap<String, CompletableDeferred<Unit>>()

    /** The shell command for [nonce]: built from fixed words, the app's own names and hex digits only. */
    fun command(nonce: String): String = "am broadcast -a $action -n $component --es $EXTRA_NONCE $nonce"

    /** The receiver's half: true when [nonce] completes a proof in progress (each completes once). */
    fun deliver(nonce: String?): Boolean {
        if (nonce == null || !NONCE.matches(nonce)) return false
        return pending.remove(nonce)?.complete(Unit) == true
    }

    /**
     * Runs the broadcast through [open] (a stream on the connection being proved, not yet in use)
     * and waits for it to arrive. False on a timeout, a failed open, or no broadcast; a
     * cancellation is passed on. The exec stream is closed either way.
     */
    suspend fun prove(open: suspend (service: String) -> AdbPipe): Boolean {
        val nonce = newNonce()
        val arrived = CompletableDeferred<Unit>()
        pending[nonce] = arrived
        val pipe = AtomicReference<AdbPipe?>(null)
        return try {
            withTimeoutOrNull(timeoutMs) {
                pipe.set(open("exec:" + command(nonce)))
                arrived.await()
                true
            } ?: false
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            false
        } finally {
            pending.remove(nonce)
            pipe.get()?.close()
        }
    }

    /** 128 random bits as 32 lowercase hex digits. */
    fun newNonce(): String {
        val bytes = ByteArray(NONCE_BYTES).also(random::nextBytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    companion object {
        /** How long the broadcast may take (ruling R58). */
        const val TIMEOUT_MS = 3_000L

        /** The broadcast's string extra that carries the nonce. */
        const val EXTRA_NONCE = "n"
        private const val NONCE_BYTES = 16
        private val NONCE = Regex("[0-9a-f]{32}")
    }
}
