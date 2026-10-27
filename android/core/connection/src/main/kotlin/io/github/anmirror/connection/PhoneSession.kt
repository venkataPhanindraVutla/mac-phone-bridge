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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    /**
     * The Mac does not know this phone: `system.error NOT_PAIRED`, or the Mac refused the
     * phone's certificate in the TLS handshake (TLS 1.3 reports that on the first read).
     */
    NOT_PAIRED,

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
 * waits [timeoutMs] for the Mac's. On any failure the channel is closed.
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
        HelloResult.Failed(HelloFailure.NOT_PAIRED)
    } catch (e: IOException) {
        HelloResult.Failed(HelloFailure.CLOSED)
    } catch (e: ProtocolException) {
        HelloResult.Failed(HelloFailure.CLOSED)
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
 * A connected control channel after a successful hello: keep-alive plus message dispatch.
 *
 * Every [pingIntervalMs] it sends `system.ping`; if no `system.pong` arrives within
 * [pongTimeoutMs], it closes the channel (SPEC 7). Other messages go to `onMessage`
 * (hello, ping/pong, goodbye and error are handled here).
 */
class PhoneSession(
    val channel: ControlChannel,
    val shared: Set<String>,
    private val pingIntervalMs: Long = 30_000,
    private val pongTimeoutMs: Long = 10_000,
) {
    /**
     * Runs until the connection ends; the channel is closed on return or cancellation.
     * An element on [pingNow] (for example "the network changed") sends a ping right away.
     * Exceptions thrown by `onMessage` are dropped so one bad handler cannot end the session.
     */
    suspend fun run(pingNow: ReceiveChannel<Unit>? = null, onMessage: suspend (Envelope) -> Unit): SessionEnd = try {
        coroutineScope {
            val end = AtomicReference<SessionEnd?>(null)
            fun finish(reason: SessionEnd) {
                end.compareAndSet(null, reason)
                channel.close()
            }

            val pongs = KChannel<Unit>(KChannel.CONFLATED)
            val pinger = launch {
                while (true) {
                    val early = pingNow?.let { withTimeoutOrNull(pingIntervalMs) { it.receiveCatching() } }
                    // No pingNow, or it was closed: just wait out the interval.
                    if (pingNow == null || early?.isClosed == true) delay(pingIntervalMs)
                    while (pongs.tryReceive().isSuccess) continue
                    try {
                        channel.send(Channel.CHANNEL_SYSTEM, MessageType.PING, Ping.getDefaultInstance())
                    } catch (e: IOException) {
                        finish(SessionEnd.CLOSED)
                        return@launch
                    }
                    if (withTimeoutOrNull(pongTimeoutMs) { pongs.receive() } == null) {
                        finish(SessionEnd.PONG_TIMEOUT)
                        return@launch
                    }
                }
            }

            try {
                while (end.get() == null) {
                    val env = channel.receive() ?: break
                    when (env.type) {
                        MessageType.PONG -> pongs.trySend(Unit)
                        MessageType.PING -> runCatching {
                            channel.send(Channel.CHANNEL_SYSTEM, MessageType.PONG, Pong.getDefaultInstance(), env.id)
                        }
                        MessageType.HELLO -> Unit
                        MessageType.GOODBYE -> {
                            val reason = parseOrNull { Goodbye.parseFrom(env.payload) }?.reason
                            finish(if (reason == GoodbyeReason.GOODBYE_REASON_UNPAIRED) SessionEnd.UNPAIRED else SessionEnd.GOODBYE)
                        }
                        MessageType.ERROR -> finish(SessionEnd.ERROR)
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
            }
            finish(SessionEnd.CLOSED)
            pinger.cancel()
            end.get() ?: SessionEnd.CLOSED
        }
    } finally {
        channel.close()
    }
}
