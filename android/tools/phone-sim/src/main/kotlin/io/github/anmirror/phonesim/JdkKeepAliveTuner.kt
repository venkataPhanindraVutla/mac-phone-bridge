package io.github.anmirror.phonesim

import io.github.anmirror.connection.SocketTuner
import io.github.anmirror.connection.TcpKeepAlive
import jdk.net.ExtendedSocketOptions
import java.net.Socket
import java.net.SocketOption

/**
 * TCP keepalive with the SPEC 7 timings through the JDK's extended socket options. Best effort:
 * an option this platform does not support is skipped, and keepalive stays on with the system timings.
 */
object JdkKeepAliveTuner : SocketTuner {
    override fun tune(socket: Socket) {
        TcpKeepAlive.BASIC.tune(socket)
        set(socket, ExtendedSocketOptions.TCP_KEEPIDLE, TcpKeepAlive.IDLE_S)
        set(socket, ExtendedSocketOptions.TCP_KEEPINTERVAL, TcpKeepAlive.INTERVAL_S)
        set(socket, ExtendedSocketOptions.TCP_KEEPCOUNT, TcpKeepAlive.COUNT)
    }

    private fun set(socket: Socket, option: SocketOption<Int>, value: Int) {
        if (option in socket.supportedOptions()) runCatching { socket.setOption(option, value) }
    }
}
