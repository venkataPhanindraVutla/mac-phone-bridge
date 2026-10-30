package io.github.anmirror.adb

import io.github.muntashirakon.adb.AdbAuthenticationFailedException
import io.github.muntashirakon.adb.AdbConnection
import io.github.muntashirakon.adb.AdbPairingRequiredException
import io.github.muntashirakon.adb.PairingConnectionCtx
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.security.GeneralSecurityException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Pairing with Wireless debugging failed. [stage] says how far it got: nothing listened on the
 * port, the TLS handshake failed (not a pairing port), or the exchange after it failed (the code).
 */
class AdbPairingException(val stage: Stage, cause: Throwable?) : IOException(cause) {
    enum class Stage { NOT_LISTENING, HANDSHAKE, AFTER_HANDSHAKE }
}

/** The phone's own ADB daemon, reached over Wireless debugging. One connection at a time. */
interface AdbClient {
    val isConnected: Boolean

    /** Pairs this app's identity with the code shown under "Pair device with pairing code". Throws [AdbPairingException]. */
    suspend fun pair(host: String, port: Int, code: String)

    /** Connects to the TLS port (replacing any connection). Throws [IOException]; 10 s timeout. */
    suspend fun connect(host: String, port: Int)

    /** Runs `shell:<command>` and returns its stdout. */
    suspend fun shell(command: String): String

    /** Opens a stream to an ADB service: `localabstract:…`, `exec:…`, `shell:…`. */
    suspend fun open(service: String): AdbPipe

    fun close()
}

/** libadb's pairing context, whose frames say where a pairing failed ([pairingStage]). */
internal val PAIRING_CTX_CLASS: String = PairingConnectionCtx::class.java.name

/**
 * Where libadb's `PairingConnectionCtx.start()` failed. A refused connection anywhere in the cause
 * chain is NOT_LISTENING; a failure raised inside `setupTlsConnection` (the socket and the TLS
 * handshake) is HANDSHAKE; anything later (the SPAKE2 and peer-info exchange, where a wrong code
 * shows) is AFTER_HANDSHAKE. libadb 3.1.1 names no stage itself, so its frames are read; the app
 * is not minified.
 */
internal fun pairingStage(e: Throwable): AdbPairingException.Stage {
    val chain = generateSequence(e) { it.cause }.take(MAX_CAUSES).toList()
    if (chain.any { it is ConnectException || it is NoRouteToHostException }) return AdbPairingException.Stage.NOT_LISTENING
    val inTlsSetup = chain.any { t ->
        t.stackTrace.any { it.className == PAIRING_CTX_CLASS && it.methodName == "setupTlsConnection" }
    }
    return if (inTlsSetup) AdbPairingException.Stage.HANDSHAKE else AdbPairingException.Stage.AFTER_HANDSHAKE
}

private const val MAX_CAUSES = 16

/**
 * [AdbClient] over libadb-android. [sdk] is the phone's API level (TLS from 30); [deviceName] is
 * what Wireless debugging lists under "Paired devices".
 */
class LibAdbClient(
    private val identity: AdbIdentity,
    private val sdk: Int,
    private val deviceName: String = "Android Mirroring",
) : AdbClient {
    private val lock = Any()
    @Volatile private var connection: AdbConnection? = null

    override val isConnected: Boolean
        get() = connection?.let { it.isConnected && it.isConnectionEstablished } == true

    override suspend fun pair(host: String, port: Int, code: String) {
        val ctx = try {
            PairingConnectionCtx(host, port, code.toByteArray(Charsets.UTF_8), identity.privateKey, identity.certificate, deviceName)
        } catch (e: GeneralSecurityException) {
            throw IOException("pairing context", e)
        }
        try {
            blocking(ctx, PAIR_TIMEOUT_MS) { ctx.start() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: SocketTimeoutException) {
            throw e
        } catch (e: IOException) {
            throw AdbPairingException(pairingStage(e), e)
        } catch (e: RuntimeException) {
            throw AdbPairingException(pairingStage(e), e)
        } finally {
            ctx.close()
        }
    }

    override suspend fun connect(host: String, port: Int) {
        val conn = withContext(Dispatchers.IO) {
            AdbConnection.Builder(host, port)
                .setApi(sdk)
                .setPrivateKey(identity.privateKey)
                .setCertificate(identity.certificate)
                .setDeviceName(deviceName)
                .build()
        }
        val ok = try {
            blocking(conn, CONNECT_TIMEOUT_MS + GUARD_SLACK_MS) {
                conn.connect(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS, true)
            }
        } catch (e: Exception) {
            runCatching { conn.close() }
            throw when (e) {
                is IOException -> e
                is InterruptedException -> InterruptedIOException("adb connect interrupted")
                is AdbPairingRequiredException -> IOException("adb: pairing required", e)
                is AdbAuthenticationFailedException -> IOException("adb: not authorised", e)
                else -> e
            }
        }
        if (!ok) {
            runCatching { conn.close() }
            throw SocketTimeoutException("adb connect timed out")
        }
        val old = synchronized(lock) { connection.also { connection = conn } }
        old?.let { runCatching { it.close() } }
    }

    override suspend fun shell(command: String): String {
        val pipe = open("shell:$command")
        try {
            return blocking(pipe, Long.MAX_VALUE) { pipe.input.readBytes() }.toString(Charsets.UTF_8)
        } finally {
            pipe.close()
        }
    }

    override suspend fun open(service: String): AdbPipe {
        val conn = connection ?: throw IOException("adb not connected")
        // adbd answers an open at once (OKAY, or CLSE for a socket nobody listens on).
        val stream = try {
            withContext(Dispatchers.IO) { conn.open(service) }
        } catch (e: InterruptedException) {
            throw InterruptedIOException("adb open interrupted")
        } catch (e: AdbPairingRequiredException) {
            throw IOException("adb: pairing required", e)
        }
        return AdbPipe(stream.openInputStream(), stream.openOutputStream()) { runCatching { stream.close() } }
    }

    override fun close() {
        val old = synchronized(lock) { connection.also { connection = null } }
        old?.let { runCatching { it.close() } }
    }

    /**
     * Runs a blocking libadb call on the IO pool. Neither a timeout nor a cancellation can
     * interrupt socket I/O, so both close [closeable], which makes [block] throw; a timeout then
     * surfaces as [SocketTimeoutException].
     */
    private suspend fun <T> blocking(closeable: Closeable, timeoutMs: Long, block: () -> T): T = withContext(Dispatchers.IO) {
        val done = AtomicBoolean(false)
        val timedOut = AtomicBoolean(false)
        val guard = launch {
            try {
                delay(timeoutMs)
                timedOut.set(true)
            } finally {
                if (!done.get()) runCatching { closeable.close() }
            }
        }
        try {
            block().also { ensureActive() }
        } catch (e: Exception) {
            if (timedOut.get()) throw SocketTimeoutException("adb: timed out").apply { initCause(e) }
            throw e
        } finally {
            done.set(true)
            guard.cancel()
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
        const val PAIR_TIMEOUT_MS = 10_000L
        const val GUARD_SLACK_MS = 2_000L
    }
}
