package io.github.anmirror.phone.platform

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.github.anmirror.connection.SocketTuner
import io.github.anmirror.connection.TcpKeepAlive
import java.io.IOException
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * TCP keepalive with SPEC 7's timings on every socket the phone dials: keepalive on (as
 * [TcpKeepAlive.BASIC]), then idle [TcpKeepAlive.IDLE_S] s, interval [TcpKeepAlive.INTERVAL_S] s,
 * [TcpKeepAlive.COUNT] probes through `setsockopt` (API 21+, so every supported phone).
 *
 * If the timings cannot be set, the socket keeps BASIC keepalive with the system's timings and
 * [onFallback] hears once per tuner, with the exception's class (and errno name) only: no
 * address, no message.
 */
class AndroidKeepAliveTuner(
    private val setTcpOption: (socket: Socket, option: Int, value: Int) -> Unit = ::setsockoptTcp,
    private val onFallback: (detail: String) -> Unit = {},
) : SocketTuner {
    private val reported = AtomicBoolean(false)

    override fun tune(socket: Socket) {
        TcpKeepAlive.BASIC.tune(socket)
        try {
            setTcpOption(socket, TCP_KEEPIDLE, TcpKeepAlive.IDLE_S)
            setTcpOption(socket, TCP_KEEPINTVL, TcpKeepAlive.INTERVAL_S)
            setTcpOption(socket, TCP_KEEPCNT, TcpKeepAlive.COUNT)
        } catch (e: Exception) {
            if (reported.compareAndSet(false, true)) {
                val errno = (e as? ErrnoException)?.let { ",${OsConstants.errnoName(it.errno)}" }.orEmpty()
                onFallback("basic,${e.javaClass.simpleName}$errno")
            }
        }
    }

    private companion object {
        // Linux option numbers (not in the public OsConstants).
        const val TCP_KEEPIDLE = 4
        const val TCP_KEEPINTVL = 5
        const val TCP_KEEPCNT = 6
    }
}

/** `setsockopt(IPPROTO_TCP, option, value)` on a dup of [socket]'s descriptor; the option lands on the shared socket. */
private fun setsockoptTcp(socket: Socket, option: Int, value: Int) {
    val dup = ParcelFileDescriptor.fromSocket(socket) ?: throw IOException("no descriptor")
    dup.use { Os.setsockoptInt(it.fileDescriptor, OsConstants.IPPROTO_TCP, option, value) }
}
