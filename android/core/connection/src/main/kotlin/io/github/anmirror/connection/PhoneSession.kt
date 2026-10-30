package io.github.anmirror.connection

import com.google.protobuf.InvalidProtocolBufferException
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.ProtocolException
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.Ping
import io.github.anmirror.protocol.v1.Pong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException
import kotlinx.coroutines.channels.Channel as KChannel
import io.github.anmirror.protocol.v1.Error as ProtoError

/** The protocol version this implementation speaks (SPEC 3). */
const val PROTOCOL_VERSION = 1

sealed interface HelloResult {
    /** [shared] is the intersection of both sides' capabilities. */
    data class Ok(val remote: Hello, val shared: Set<String>) : HelloResult

    data class Failed(val reason: HelloFailure) : HelloResult
}

enum class HelloFailure {
    /** Explicit, authenticated `system.error NOT_PAIRED` from the pinned Mac. */
    NOT_PAIRED,

    /**
     * Heuristic: a TLS error (SSLException) on the first read or write after the handshake.
     * Usually the Mac refusing the phone's certificate (TLS 1.3 reports that late), but a
     * reset or abort on a flaky network can look the same (Conscrypt reports ECONNRESET as
     * SSLException). Not proof that the Mac forgot this phone.
     */
    TLS_REFUSED,

    /** `system.goodbye UNPAIRED` instead of a hello: the Mac has forgotten this phone. */
    UNPAIRED,

    /** `system.error BUSY`: another phone is connected. */
    BUSY,

    /** Different protocol versions (either side detected it). */
    PROTOCOL_MISMATCH,

    /** No hello within the timeout. */
    TIMED_OUT,

    /** The connection ended (EOF, reset, framing error, other goodbye) before a hello. */
    CLOSED,

    /** Any other `system.error`. */
    REJECTED,
}

/**
 * The connect handshake (SPEC 3 "Capabilities"): the phone sends `system.hello` first and
 * waits [timeoutMs] for the Mac's. On any failure, or cancellation, the channel is closed.
 */
suspend fun exchangeHello(channel: ControlChannel, hello: Hello, timeoutMs: Long = 10_000): HelloResult {
    val result = try {
        try {
            channel.send(Channel.CHANNEL_SYSTEM, MessageType.HELLO, hello)
        } catch (e: IOException) {
            // The write failed (broken pipe): the reader may hold the reason, e.g. a TLS alert.
            throw channel.closeCause() as? SSLException ?: e
        }
        withTimeoutOrNull(timeoutMs) { awaitHello(channel, hello) } ?: HelloResult.Failed(HelloFailure.TIMED_OUT)
    } catch (e: SSLException) {
        HelloResult.Failed(HelloFailure.TLS_REFUSED)
    } catch (e: IOException) {
        HelloResult.Failed(HelloFailure.CLOSED)
    } catch (e: ProtocolException) {
        HelloResult.Failed(HelloFailure.CLOSED)
    } catch (t: Throwable) {
        // Cancellation or anything unexpected: do not leak the socket.
        channel.close()
        throw t
    }
    if (result is HelloResult.Failed) channel.close()
    return result
}

private suspend fun awaitHello(channel: ControlChannel, local: Hello): HelloResult {
    while (true) {
        val env = channel.receive() ?: return HelloResult.Failed(HelloFailure.CLOSED)
        when (env.type) {
            MessageType.HELLO -> {
                val remote = parseOrNull { Hello.parseFrom(env.payload) } ?: return HelloResult.Failed(HelloFailure.CLOSED)
                if (remote.protocolVersion != PROTOCOL_VERSION) {
                    runCatching {
                        channel.send(
                            Channel.CHANNEL_SYSTEM, MessageType.ERROR,
                            ProtoError.newBuilder().setCode(ErrorCode.ERROR_CODE_PROTOCOL_MISMATCH)
                                .setMessage("protocol version ${remote.protocolVersion}, expected $PROTOCOL_VERSION").build(),
                        )
                    }
                    return HelloResult.Failed(HelloFailure.PROTOCOL_MISMATCH)
                }
                return HelloResult.Ok(remote, local.capabilitiesList.toSet().intersect(remote.capabilitiesList.toSet()))
            }
            MessageType.ERROR -> return HelloResult.Failed(
                when (parseOrNull { ProtoError.parseFrom(env.payload) }?.code) {
                    ErrorCode.ERROR_CODE_NOT_PAIRED -> HelloFailure.NOT_PAIRED
                    ErrorCode.ERROR_CODE_BUSY -> HelloFailure.BUSY
                    ErrorCode.ERROR_CODE_PROTOCOL_MISMATCH -> HelloFailure.PROTOCOL_MISMATCH
                    else -> HelloFailure.REJECTED
                },
            )
            MessageType.GOODBYE -> return HelloResult.Failed(
                if (parseOrNull { Goodbye.parseFrom(env.payload) }?.reason == GoodbyeReason.GOODBYE_REASON_UNPAIRED) {
                    HelloFailure.UNPAIRED
                } else {
                    HelloFailure.CLOSED
                },
            )
            else -> Unit // Anything else before the hello is ignored.
        }
    }
}

internal inline fun <T> parseOrNull(parse: () -> T): T? = try {
    parse()
} catch (e: InvalidProtocolBufferException) {
    null
}

/** Why a connected [PhoneSession] ended. */
enum class SessionEnd {
    /** EOF, a transport/framing error, or a local close. */
    CLOSED,

    /** No `system.pong` within the pong timeout (SPEC 7). */
    PONG_TIMEOUT,

    /** `system.goodbye UNPAIRED`: the Mac forgot this phone. */
    UNPAIRED,

    /** Any other `system.goodbye` (SHUTDOWN, SWITCHING_MAC, ...). */
    GOODBYE,

    /** `system.error` from the Mac. */
    ERROR,
}

/**
 * Content-free codes for why a session ended, for the phone's event log ([PhoneSession.endCode]).
 * Only enum names and exception class names, never a message, host or name.
 */
object SessionEndCode {
    /** The Mac closed the connection (FIN). */
    const val EOF = "EOF"

    /** This phone closed it (stop, forget, a switch to another Mac). */
    const val LOCAL_CLOSE = "LOCAL_CLOSE"

    /** No answer within the pong timeout (SPEC 7). */
    const val PING_TIMEOUT = "PING_TIMEOUT"

    /** The session's coroutine was cancelled (the manager stopped). */
    const val CANCELLED = "CANCELLED"

    /** A session that lived this long counts as matured in the log (the immediate-redial threshold). */
    const val MATURED_MS = 60_000L

    fun goodbye(reason: GoodbyeReason?): String =
        "GOODBYE_" + (reason?.name?.removePrefix("GOODBYE_REASON_") ?: "UNKNOWN")

    fun error(code: ErrorCode?): String = "ERROR_" + (code?.name?.removePrefix("ERROR_CODE_") ?: "UNKNOWN")

    /** `TLS_<Class>`, `IO_<Class>` or `ERR_<Class>`; the message is never included. */
    fun of(e: Throwable): String {
        val name = e.javaClass.simpleName.ifEmpty { "Unknown" }
        return when (e) {
            is SSLException -> "TLS_$name"
            is IOException -> "IO_$name"
            else -> "ERR_$name"
        }
    }

    /** The event-log detail: `<reason>,matured=<bool>,liveness=<bool>,s=<seconds connected>`. */
    fun logDetail(reason: String, connectedMs: Long, liveness: Boolean): String =
        "$reason,matured=${connectedMs >= MATURED_MS},liveness=$liveness,s=${connectedMs / 1000}"
}

/**
 * A connected control channel after a successful hello: keep-alive plus message dispatch.
 *
 * Keep-alive follows SPEC 7, through [PhoneLiveness]:
 * - Without `liveness.v1` in [shared] (0.1): `system.ping` every [pingIntervalMs]; if no
 *   `system.pong` arrives within [pongTimeoutMs], the session ends with `PONG_TIMEOUT`.
 * - With it, the Mac pings. Each Mac ping is answered at once with `system.pong`. The phone
 *   pings only after [fallbackIdleMs] with nothing received, and ends the session if nothing
 *   at all arrives within [pongTimeoutMs] of that ping.
 *
 * [uptimeMs] is monotonic uptime (it stops in deep sleep, like the coroutine delays here).
 * Other messages go to `onMessage` (hello, ping/pong, goodbye and error are handled here).
 */
class PhoneSession(
    val channel: ControlChannel,
    val shared: Set<String>,
    private val pingIntervalMs: Long = 30_000,
    private val pongTimeoutMs: Long = 10_000,
    private val fallbackIdleMs: Long = 45_000,
    private val uptimeMs: () -> Long = monotonicUptimeMs,
) {
    /** Why [run] ended, as a [SessionEndCode]; null while it runs. */
    @Volatile var endCode: String? = null
        private set

    /**
     * Runs until the connection ends; the channel is closed on return or cancellation.
     * An element on [pingNow] (for example "the network changed") sends a ping right away.
     * [onMacPing] runs after each Mac `system.ping` whose `system.pong` was written.
     * Exceptions thrown by `onMessage` are dropped so one bad handler cannot end the session.
     */
    suspend fun run(
        pingNow: ReceiveChannel<Unit>? = null,
        onMacPing: (() -> Unit)? = null,
        onMessage: suspend (Envelope) -> Unit,
    ): SessionEnd = try {
        coroutineScope {
            val end = AtomicReference<SessionEnd?>(null)
            fun finish(reason: SessionEnd, code: String) {
                if (end.compareAndSet(null, reason)) endCode = code
                channel.close()
            }

            val liveness = PhoneLiveness(
                macDriven = LIVENESS_CAPABILITY in shared,
                pingIntervalMs = pingIntervalMs,
                fallbackIdleMs = fallbackIdleMs,
                pongTimeoutMs = pongTimeoutMs,
                startMs = uptimeMs(),
            )
            // Something arrived: the pinger looks at the liveness state again.
            val heard = KChannel<Unit>(KChannel.CONFLATED)
            val pinger = launch {
                var kicks = pingNow
                while (true) {
                    val now = uptimeMs()
                    when (val step = liveness.next(now)) {
                        LivenessStep.SendPing -> {
                            // Marked before the write, so an answer racing the write is not missed.
                            liveness.onPingSent(now)
                            try {
                                channel.send(Channel.CHANNEL_SYSTEM, MessageType.PING, Ping.getDefaultInstance())
                            } catch (e: IOException) {
                                finish(SessionEnd.CLOSED, SessionEndCode.of(e))
                                return@launch
                            }
                        }
                        is LivenessStep.WaitUntil -> withTimeoutOrNull(step.atMs - now) {
                            val k = kicks
                            select<Unit> {
                                heard.onReceive {}
                                if (k != null) {
                                    k.onReceiveCatching { r ->
                                        // A closed pingNow just stops being listened to.
                                        if (r.isClosed) kicks = null else liveness.requestPing()
                                    }
                                }
                            }
                        }
                        LivenessStep.Dead -> {
                            finish(SessionEnd.PONG_TIMEOUT, SessionEndCode.PING_TIMEOUT)
                            return@launch
                        }
                    }
                }
            }

            var readEnd: String? = null
            try {
                while (end.get() == null) {
                    val env = channel.receive()
                    if (env == null) {
                        // A null read is the peer's FIN, or our own close.
                        readEnd = if (channel.isClosed) SessionEndCode.LOCAL_CLOSE else SessionEndCode.EOF
                        break
                    }
                    liveness.onIncoming(uptimeMs(), isPong = env.type == MessageType.PONG)
                    heard.trySend(Unit)
                    when (env.type) {
                        MessageType.PONG -> Unit
                        MessageType.PING -> {
                            // At once, whatever the timers say (SPEC 7: the Mac's drop rule relies on it).
                            runCatching {
                                channel.send(Channel.CHANNEL_SYSTEM, MessageType.PONG, Pong.getDefaultInstance(), env.id)
                            }.onSuccess { onMacPing?.invoke() }
                        }
                        MessageType.HELLO -> Unit
                        MessageType.GOODBYE -> {
                            val reason = parseOrNull { Goodbye.parseFrom(env.payload) }?.reason
                            finish(
                                if (reason == GoodbyeReason.GOODBYE_REASON_UNPAIRED) SessionEnd.UNPAIRED else SessionEnd.GOODBYE,
                                SessionEndCode.goodbye(reason),
                            )
                        }
                        MessageType.ERROR -> finish(SessionEnd.ERROR, SessionEndCode.error(parseOrNull { ProtoError.parseFrom(env.payload) }?.code))
                        else -> try {
                            onMessage(env)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            // Dropped on purpose; see run().
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // TLS, I/O or framing error: the connection is gone.
                readEnd = SessionEndCode.of(e)
            }
            finish(SessionEnd.CLOSED, readEnd ?: SessionEndCode.EOF)
            pinger.cancel()
            end.get() ?: SessionEnd.CLOSED
        }
    } catch (e: CancellationException) {
        if (endCode == null) endCode = SessionEndCode.CANCELLED
        throw e
    } finally {
        channel.close()
    }
}
