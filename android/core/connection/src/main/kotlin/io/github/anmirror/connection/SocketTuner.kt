package io.github.anmirror.connection

import java.net.Socket

/** Socket options applied to every connection the phone dials, right after the TCP connect. */
fun interface SocketTuner {
    fun tune(socket: Socket)
}

/**
 * TCP keepalive on the control and bulk sockets (SPEC 7): probe after [IDLE_S] idle seconds,
 * every [INTERVAL_S] seconds, [COUNT] probes. It finds a dead path (Wi-Fi gone, Mac powered
 * off); it cannot find a frozen app, whose kernel still answers the probes.
 */
object TcpKeepAlive {
    const val IDLE_S = 60
    const val INTERVAL_S = 10
    const val COUNT = 3

    /** Turns keepalive on with the system's timings; platforms that can set the three values tune on top of it. */
    val BASIC: SocketTuner = SocketTuner { it.keepAlive = true }
}
