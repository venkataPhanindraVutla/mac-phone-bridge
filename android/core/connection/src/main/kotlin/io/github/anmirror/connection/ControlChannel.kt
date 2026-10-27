package io.github.anmirror.connection

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.Frame
import io.github.anmirror.protocol.FrameDecoder
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.ChannelResult
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.selects.SelectClause1
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread
import kotlinx.coroutines.channels.Channel as KChannel

/** Where envelopes come from and go to. The socket implementation is [SocketWire]. */
internal interface Wire {
    /** Starts delivering envelopes; [onEnd] gets null on EOF/local close, else the error. */
    fun start(onEnvelope: (Envelope) -> Unit, onEnd: (Throwable?) -> Unit)

    suspend fun write(envelope: Envelope)

    fun close()
}

/**
 * A framed, mutual-TLS control connection to the Mac (SPEC 2 and 3).
 *
 * - [send] numbers envelopes from 1 per connection and writes them in call order.
 * - [incoming] delivers received envelopes in order. It completes normally on EOF or [close],
 *   and with an exception on a framing or TLS error (the connection is then closed, SPEC 2).
 *   Envelopes are buffered from the moment the channel exists, so none are lost before
 *   someone collects. Collect from one place at a time: each envelope goes to one collector.
 */
class ControlChannel internal constructor(
    private val wire: Wire,
    /** The host this channel was dialed at (as given to the connector). */
    val host: String,
    val port: Int,
    /** Lowercase hex SHA-256 of the peer's certificate. */
    val peerFingerprintHex: String?,
) {
    constructor(socket: SSLSocket, host: String = socket.inetAddress.hostAddress) : this(
        SocketWire(socket),
        host,
        socket.port,
        runCatching { fingerprintHex(socket.session.peerCertificates[0].encoded) }.getOrNull(),
    )

    private val inbox = KChannel<Envelope>(KChannel.UNLIMITED)
    private val sendLock = Mutex()
    private var nextId = 1L
    private val closed = AtomicBoolean(false)

    val incoming: Flow<Envelope> = inbox.receiveAsFlow()

    /** True after [close]. (A connection the peer ended shows up as the end of [incoming].) */
    val isClosed: Boolean get() = closed.get()

    init {
        wire.start(
            onEnvelope = { inbox.trySend(it) },
            onEnd = { error -> if (closed.get() || error == null) inbox.close() else inbox.close(error) },
        )
    }

    /** Sends one envelope and returns its id. Throws [IOException] if the connection is gone. */
    suspend fun send(channel: Channel, type: String, payload: MessageLite, replyTo: Long = 0): Long =
        sendLock.withLock {
            if (closed.get()) throw IOException("channel closed")
            val id = nextId++
            wire.write(envelope(channel, id, type, payload, replyTo))
            id
        }

    /** The next envelope, or null after EOF/close. Throws on a framing or TLS error. */
    internal suspend fun receive(): Envelope? = try {
        inbox.receive()
    } catch (e: ClosedReceiveChannelException) {
        null
    }

    /**
     * After a failed [send]: waits up to [timeoutMs] for the reader to see the end of the
     * connection, dropping anything still buffered, and returns its error (null for EOF).
     * A TLS alert from the peer (for example a refused certificate) comes back as SSLException.
     */
    internal suspend fun closeCause(timeoutMs: Long = 1_000): Throwable? {
        var cause: Throwable? = null
        withTimeoutOrNull(timeoutMs) {
            while (true) {
                val r = inbox.receiveCatching()
                if (r.isClosed) {
                    cause = r.exceptionOrNull()
                    break
                }
            }
        }
        return cause
    }

    /** [receive] as a select clause (closed: `isClosed`, with the error if any). */
    internal val onReceiveCatching: SelectClause1<ChannelResult<Envelope>> get() = inbox.onReceiveCatching

    /** Closes the connection. Idempotent. [incoming] then completes normally. */
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { wire.close() }
        inbox.close()
    }
}

/** Blocking socket I/O: a reader thread feeds a [FrameDecoder]; writes go out on [Dispatchers.IO]. */
internal class SocketWire(private val socket: SSLSocket) : Wire {
    private val writeLock = Any()

    override fun start(onEnvelope: (Envelope) -> Unit, onEnd: (Throwable?) -> Unit) {
        thread(isDaemon = true, name = "anmirror-control-reader") {
            val decoder = FrameDecoder()
            val buf = ByteArray(64 * 1024)
            var error: Throwable? = null
            try {
                val input = socket.inputStream
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    decoder.append(buf, 0, n)
                    while (true) onEnvelope(decoder.next() ?: break)
                }
            } catch (t: Throwable) {
                // Framing errors (ProtocolException), TLS alerts and I/O errors end the connection.
                error = t
            } finally {
                runCatching { socket.close() }
                onEnd(error)
            }
        }
    }

    override suspend fun write(envelope: Envelope) {
        val frame = Frame.encode(envelope)
        withContext(Dispatchers.IO) {
            synchronized(writeLock) {
                val out = socket.outputStream
                out.write(frame)
                out.flush()
            }
        }
    }

    override fun close() {
        socket.close()
    }
}
