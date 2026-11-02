package io.github.anmirror.adb

import io.github.muntashirakon.adb.AdbAuthenticationFailedException
import io.github.muntashirakon.adb.AdbConnection
import io.github.muntashirakon.adb.AdbPairingRequiredException
import io.github.muntashirakon.adb.AdbStream
import io.github.muntashirakon.adb.PairingConnectionCtx
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.GeneralSecurityException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException

/**
 * Pairing with Wireless debugging failed. [stage] says how far it got: nothing listened on the
 * port, the port answered but is not a pairing port, or the exchange after the handshake failed
 * (the code). [hint] is where libadb's stack frames put it, for the logs only.
 */
class AdbPairingException(val stage: Stage, cause: Throwable?, val hint: Stage? = null) : IOException(cause) {
    enum class Stage { NOT_LISTENING, HANDSHAKE, AFTER_HANDSHAKE }
}

/** The daemon refused this app's key: the pairing was removed (or never made). Pairing again is the way back. */
class AdbNotPairedException(cause: Throwable?) : IOException("adb: this app is not paired", cause)

/** The phone's own ADB daemon, reached over Wireless debugging. One connection at a time. */
interface AdbClient {
    val isConnected: Boolean

    /** Pairs this app's identity with the code shown under "Pair device with pairing code". Throws [AdbPairingException]. */
    suspend fun pair(host: String, port: Int, code: String)

    /**
     * Connects to the TLS port (replacing any connection, but only once the new one is proven).
     * Throws [IOException]; 10 s timeout; [AdbNotPairedException] when the daemon no longer trusts
     * this app; [AdbPeerProofException] when the peer did not prove it is this phone's adbd
     * (ruling R58), and then nothing changed.
     */
    suspend fun connect(host: String, port: Int)

    /** Runs `shell:<command>` and returns its stdout. */
    suspend fun shell(command: String): String

    /** Opens a stream to an ADB service: `localabstract:…`, `exec:…`, `shell:…`. */
    suspend fun open(service: String): AdbPipe

    fun close()
}

/** libadb's pairing context, whose frames are read for [framesHint]. */
internal val PAIRING_CTX_CLASS: String = PairingConnectionCtx::class.java.name

/** libadb 3.1.1's own failures after the TLS handshake, where a wrong code shows. */
private val AFTER_HANDSHAKE_MESSAGES = setOf("Could not exchange peer info.", "Exchanging message wasn't successful.")

/**
 * When SPAKE2 can't produce a key, libadb logs "Unable to initialize pairing cipher" and throws a
 * message-less IOException caused by spake2's IllegalStateException with this message.
 */
private const val SPAKE2_NO_KEY = "No key was returned"
private const val MAX_CAUSES = 16

private fun Throwable.chain(): List<Throwable> = generateSequence(this) { it.cause }.take(MAX_CAUSES).toList()

/**
 * The stage of a failed pairing, from what is known (ruling R46): a refused or unroutable connect
 * is NOT_LISTENING; libadb's post-handshake failures (an EOF outside a TLS handshake, its two
 * exchange messages, SPAKE2 returning no key) are AFTER_HANDSHAKE; anything else happened on a port
 * that answered and is not a pairing port: HANDSHAKE.
 */
internal fun pairingStage(e: Throwable): AdbPairingException.Stage {
    val chain = e.chain()
    if (chain.any { it is ConnectException || it is NoRouteToHostException }) return AdbPairingException.Stage.NOT_LISTENING
    val inTlsHandshake = chain.any { it is SSLHandshakeException }
    val afterHandshake = chain.any { t ->
        (t is EOFException && !inTlsHandshake) ||
            (t is IOException && t.message in AFTER_HANDSHAKE_MESSAGES) ||
            (t is IOException && t.message == null && (t.cause as? IllegalStateException)?.message == SPAKE2_NO_KEY)
    }
    return if (afterHandshake) AdbPairingException.Stage.AFTER_HANDSHAKE else AdbPairingException.Stage.HANDSHAKE
}

/**
 * Where libadb's frames place a failure: inside `setupTlsConnection` (socket and handshake) or
 * after it. A hint for the logs only; null when no libadb frame is left (a minified build).
 */
internal fun framesHint(e: Throwable): AdbPairingException.Stage? {
    val frames = e.chain().flatMap { it.stackTrace.asList() }.filter { it.className == PAIRING_CTX_CLASS }
    if (frames.isEmpty()) return null
    return if (frames.any { it.methodName == "setupTlsConnection" }) {
        AdbPairingException.Stage.HANDSHAKE
    } else {
        AdbPairingException.Stage.AFTER_HANDSHAKE
    }
}

/** One pairing attempt: [start] blocks until it ends; [close] releases it. */
internal interface PairingSession {
    fun start()
    fun close()
}

internal fun interface PairingSessionFactory {
    fun open(host: String, port: Int, code: String): PairingSession
}

/**
 * Runs [close] at most once and swallows what it throws: libadb's `PairingConnectionCtx.close()`
 * throws a NullPointerException after a failure before its streams exist, and must not run twice
 * (its SPAKE2 context is freed natively).
 */
internal class CloseOnce(private val close: () -> Unit) {
    private val closed = AtomicBoolean(false)

    operator fun invoke() {
        if (closed.compareAndSet(false, true)) runCatching(close)
    }
}

/**
 * [AdbClient] over libadb-android. [sdk] is the phone's API level (TLS from 30); [proof] proves
 * each new connection's peer is this phone's adbd before it is kept (ruling R58: libadb checks no
 * server certificate); [deviceName] is what Wireless debugging lists under "Paired devices";
 * [timeoutMs] bounds pairing and connecting. [log] gets content-free events (codes and class names).
 */
class LibAdbClient(
    private val identity: AdbIdentity,
    private val sdk: Int,
    private val proof: AdbPeerProof,
    private val deviceName: String = "Android Mirroring",
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val log: (String) -> Unit = {},
    private val openTimeoutMs: Long = OPEN_TIMEOUT_MS,
) : AdbClient {
    private val lock = Any()
    @Volatile private var connection: AdbConnection? = null

    /** Opens a pairing attempt; tests wrap the real one. */
    internal var pairingSessions = PairingSessionFactory { host, port, code -> libadbPairing(host, port, code) }

    /** Makes the connection's socket (libadb connects it here); tests slow it down. */
    internal var buildConnection: (host: String, port: Int) -> AdbConnection = { host, port ->
        AdbConnection.Builder(host, port)
            .setApi(sdk)
            .setPrivateKey(identity.privateKey)
            .setCertificate(identity.certificate)
            .setDeviceName(deviceName)
            .build()
    }

    /** Opens a stream on the connection (libadb waits for adbd's answer without a timeout); tests make it silent. */
    internal var openStream: (AdbConnection, String) -> AdbStream = { conn, service -> conn.open(service) }

    /** For tests: uses [conn] as the established connection. */
    internal fun useConnection(conn: AdbConnection) {
        synchronized(lock) { connection = conn }
    }

    init {
        // libadb caches one TLS context for the process, built with the first key it is given. A
        // client is made per identity: drop the cache, so a new identity is not paired or
        // connected with the old one's certificate. (A libadb thread already inside its lazy
        // init could still race this; only an abandoned connect can be there, and is accepted.)
        LibAdbTls.forgetCachedContext()?.let { log("tls-cache-not-cleared,class=$it") }
    }

    override val isConnected: Boolean
        get() = connection?.let { it.isConnected && it.isConnectionEstablished } == true

    internal fun libadbPairing(host: String, port: Int, code: String): PairingSession {
        val ctx = PairingConnectionCtx(host, port, code.toByteArray(Charsets.UTF_8), identity.privateKey, identity.certificate, deviceName)
        return object : PairingSession {
            override fun start() = ctx.start()
            override fun close() = ctx.close()
        }
    }

    /**
     * The attempt runs on its own thread and closes its context there, once, after it has left
     * libadb's native code. libadb's pairing socket can't be reached from here, so a pairing that
     * hangs (a port that accepts and stays silent) is abandoned at [timeoutMs]: the caller gets
     * [SocketTimeoutException] at once, and the thread ends when the peer closes.
     */
    override suspend fun pair(host: String, port: Int, code: String) {
        val session = try {
            withContext(Dispatchers.IO) { pairingSessions.open(host, port, code) }
        } catch (e: GeneralSecurityException) {
            throw IOException("pairing context", e)
        }
        val closeOnce = CloseOnce(session::close)
        try {
            abandonable("adb-pair", timeoutMs, abandon = {}) {
                try {
                    session.start()
                } finally {
                    closeOnce()
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: SocketTimeoutException) {
            throw e
        } catch (e: Exception) {
            throw AdbPairingException(pairingStage(e), e, framesHint(e))
        }
    }

    override suspend fun connect(host: String, port: Int) {
        val t0 = System.nanoTime()
        // Our own timed TCP connect first: libadb's socket has no connect timeout.
        withContext(Dispatchers.IO) {
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs.toInt()) }
        }
        val tTcp = System.nanoTime()
        val made = AtomicReference<AdbConnection?>(null)
        val abandoned = AtomicBoolean(false)
        val closeOnce = CloseOnce { made.get()?.close() }
        val ok = try {
            abandonable("adb-connect", timeoutMs + GUARD_SLACK_MS, abandon = {
                abandoned.set(true)
                closeOnce()
            }) {
                val conn = buildConnection(host, port)
                made.set(conn)
                // Given up while build() ran: this connection arrived too late; nobody tracks it.
                if (abandoned.get()) {
                    runCatching { conn.close() }
                    throw InterruptedIOException("adb connect abandoned")
                }
                conn.connect(timeoutMs, TimeUnit.MILLISECONDS, true)
            }
        } catch (e: Exception) {
            closeOnce()
            throw when (e) {
                is CancellationException, is IOException -> e
                is InterruptedException -> InterruptedIOException("adb connect interrupted")
                is AdbPairingRequiredException, is AdbAuthenticationFailedException -> AdbNotPairedException(e)
                else -> IOException("adb connect failed", e)
            }
        }
        val conn = made.get()
        if (!ok || conn == null) {
            closeOnce()
            throw SocketTimeoutException("adb connect timed out")
        }
        val tConn = System.nanoTime()
        // Ruling R58: before anything uses it (or it replaces the connection in use), the peer
        // proves it can run a command as the phone's shell. Its exec stream is the only one opened.
        var tOpened = 0L
        val proven = try {
            proof.prove { service -> openOn(conn, service).also { tOpened = System.nanoTime() } }
        } catch (e: Throwable) {
            closeOnce()
            throw e
        }
        val tEnd = System.nanoTime()
        fun ms(from: Long, to: Long) = if (to == 0L) -1 else (to - from) / 1_000_000
        log("adb-connect-ms tcp=${ms(t0, tTcp)} handshake=${ms(tTcp, tConn)} open=${ms(tConn, tOpened)} wait=${ms(if (tOpened == 0L) tConn else tOpened, tEnd)} proven=$proven")
        if (!proven) {
            closeOnce()
            throw AdbPeerProofException()
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

    /**
     * adbd answers an open at once (OKAY, or CLSE for a socket nobody listens on), but libadb waits
     * for that answer without a timeout. An open that takes longer than [openTimeoutMs] means adbd
     * has gone silent: the connection is dropped (which also ends the waiting call) and the caller
     * gets [SocketTimeoutException]. A cancelled open is left to finish on its own.
     */
    override suspend fun open(service: String): AdbPipe = openOn(connection ?: throw IOException("adb not connected"), service)

    /** [open] on [conn], which may not be the kept connection yet (the proof's exec stream). */
    private suspend fun openOn(conn: AdbConnection, service: String): AdbPipe {
        val stream = try {
            abandonable("adb-open", openTimeoutMs, abandonOnCancel = false, abandon = {
                log("adb-open-timeout")
                drop(conn)
            }) { openStream(conn, service) }
        } catch (e: InterruptedException) {
            throw InterruptedIOException("adb open interrupted")
        } catch (e: AdbPairingRequiredException) {
            throw AdbNotPairedException(e)
        } catch (e: IllegalStateException) {
            throw IOException("adb open failed", e)
        }
        val queued: () -> Long? = LibAdbQueue.meter(stream) ?: noMeter()
        return AdbPipe(stream.openInputStream(), stream.openOutputStream(), queued) { runCatching { stream.close() } }
    }

    private fun noMeter(): () -> Long? {
        log("adb-queue-meter-missing")
        return { null }
    }

    /** Closes [conn], and forgets it if it is still the connection. */
    private fun drop(conn: AdbConnection) {
        synchronized(lock) { if (connection === conn) connection = null }
        runCatching { conn.close() }
    }

    override fun close() {
        val old = synchronized(lock) { connection.also { connection = null } }
        old?.let { runCatching { it.close() } }
    }

    /**
     * Runs a blocking libadb call on its own daemon thread and waits at most [timeoutMs] for it.
     * On a timeout or a cancellation the call is abandoned: [abandon] runs (it may close what the
     * call blocks on), the caller gets [SocketTimeoutException] (or the cancellation) at once, and
     * nothing waits for the thread.
     */
    private suspend fun <T> abandonable(
        name: String,
        timeoutMs: Long,
        abandonOnCancel: Boolean = true,
        abandon: () -> Unit,
        block: () -> T,
    ): T {
        val done = CompletableDeferred<Unit>()
        val outcome = AtomicReference<Result<T>?>(null)
        val thread = Thread({
            try {
                outcome.set(Result.success(block()))
            } catch (t: Throwable) {
                outcome.set(Result.failure(t))
            } finally {
                done.complete(Unit)
            }
        }, name)
        thread.isDaemon = true
        thread.start()
        try {
            withTimeout(timeoutMs) { done.await() }
        } catch (e: TimeoutCancellationException) {
            runCatching(abandon)
            throw SocketTimeoutException("adb: $name timed out")
        } catch (e: CancellationException) {
            if (abandonOnCancel) runCatching(abandon)
            throw e
        }
        return checkNotNull(outcome.get()).getOrThrow()
    }

    /**
     * Runs a blocking read on the IO pool. Neither a timeout nor a cancellation can interrupt
     * socket I/O, so both close [closeable], which makes [block] throw; a timeout then surfaces as
     * [SocketTimeoutException].
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

    companion object {
        /** The brief's limit for pairing and connecting. */
        const val DEFAULT_TIMEOUT_MS = 10_000L

        /** How long adbd may take to answer a stream open. */
        const val OPEN_TIMEOUT_MS = 5_000L
        private const val GUARD_SLACK_MS = 2_000L
    }
}

/**
 * What a libadb stream holds that its reader has not taken: libadb acknowledges every WRTE as it
 * arrives and queues the payload (`AdbStream.mReadQueue`, unbounded), plus the rest of the payload
 * being read (`mReadBuffer`). `available()` shows only the head payload, so the fields are read by
 * reflection (kept by the app's -keep rule for io.github.muntashirakon.adb.**).
 */
internal object LibAdbQueue {
    private val queueField = runCatching { AdbStream::class.java.getDeclaredField("mReadQueue").apply { isAccessible = true } }.getOrNull()
    private val bufferField = runCatching { AdbStream::class.java.getDeclaredField("mReadBuffer").apply { isAccessible = true } }.getOrNull()

    /** Null when this libadb has no such fields. */
    fun meter(stream: AdbStream): (() -> Long?)? {
        val queue = queueField?.get(stream) as? java.util.Queue<*> ?: return null
        val buffer = bufferField?.get(stream) as? java.nio.ByteBuffer
        return { queuedBytes(queue, buffer) }
    }

    /**
     * The bytes in [queue]'s payloads plus [buffer]'s remainder. The queue is summed under its own
     * lock, the one libadb takes to add to it. The buffer is not guarded by that lock (the reading
     * thread drains it without it), so its remainder may be a moment stale: at most one payload
     * off, which is fine for a watchdog limit of hundreds of KiB.
     */
    fun queuedBytes(queue: java.util.Queue<*>, buffer: java.nio.ByteBuffer?): Long = synchronized(queue) {
        queue.sumOf { (it as? ByteArray)?.size?.toLong() ?: 0L } + (buffer?.remaining()?.toLong() ?: 0L)
    }

    /** For tests: the fields this reads exist in the bundled libadb. */
    val fieldsFound: Boolean get() = queueField != null && bufferField != null
}

/** libadb's process-wide TLS context cache (`SslUtils.sslContext`), reached by reflection; kept by the app's -keep rule. */
internal object LibAdbTls {
    private const val SSL_UTILS = "io.github.muntashirakon.adb.SslUtils"

    /** Null when cleared; otherwise the failure's class name (the field is gone in this libadb). */
    fun forgetCachedContext(className: String = SSL_UTILS): String? =
        runCatching { field(className).set(null, null) }.exceptionOrNull()?.javaClass?.simpleName

    /** For JVM tests, which have no Conscrypt: the context libadb uses next. */
    fun useContext(context: SSLContext) {
        field(SSL_UTILS).set(null, context)
    }

    private fun field(className: String) = Class.forName(className).getDeclaredField("sslContext").apply { isAccessible = true }
}
