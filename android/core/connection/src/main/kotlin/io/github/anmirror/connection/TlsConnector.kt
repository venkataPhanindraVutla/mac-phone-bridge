package io.github.anmirror.connection

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket

/**
 * None of [tried] gave a pinned TLS 1.3 connection. [causes] has one entry per host.
 *
 * [refusedByPeer] is true when at least one host presented the pinned certificate but then
 * ended the handshake: the right Mac, refusing this phone's certificate (it is not paired
 * and no pairing window is open). Every host is still tried before this is reported.
 */
class UnreachableException(
    val tried: List<String>,
    val causes: List<Throwable> = emptyList(),
    val refusedByPeer: Boolean = false,
) : IOException("unreachable: ${tried.joinToString()}${if (refusedByPeer) " (refused by peer)" else ""}", causes.lastOrNull())

/** Opens a control connection to a Mac. [TlsConnector] is the real one; tests substitute fakes. */
fun interface MacConnector {
    /** Tries [hosts] in order; throws [UnreachableException] if none works. */
    suspend fun connect(hosts: List<String>, port: Int, pinnedFpHex: String): ControlChannel
}

/**
 * The phone's TLS client (SPEC 1): TCP, then mutual TLS 1.3 only, presenting [identity] and
 * accepting only a server whose certificate fingerprint is the pinned one.
 *
 * Each host gets [connectTimeoutMs] for the TCP connect and the same again for the TLS
 * handshake. A host that fails for any reason (refused, timeout, wrong certificate,
 * not TLS 1.3) is skipped and its socket closed.
 *
 * [tuner] runs on every dialed socket (control and bulk) right after the TCP connect. A tuner
 * that throws is logged by exception class only; the dial goes on.
 */
class TlsConnector(
    private val identity: TlsIdentity,
    private val connectTimeoutMs: Int = 3000,
    private val tuner: SocketTuner = TcpKeepAlive.BASIC,
) : MacConnector {

    override suspend fun connect(hosts: List<String>, port: Int, pinnedFpHex: String): ControlChannel {
        val causes = ArrayList<Throwable>()
        var refused = false
        for (host in hosts) {
            val pinMatched = AtomicBoolean(false)
            val context = SSLContext.getInstance("TLSv1.3").apply {
                init(identity.keyManagers(), arrayOf(PinnedTrustManager(setOf(pinnedFpHex)) { pinMatched.set(true) }), null)
            }
            try {
                return ControlChannel(dial(context, host, port), host)
            } catch (e: IOException) {
                causes += e
                // Our Mac answered and turned us away. Keep trying the other hosts; report the
                // refusal only if none works. (A timeout after the pin matched is not a refusal.)
                if (pinMatched.get() && e !is SocketTimeoutException) refused = true
            }
        }
        throw UnreachableException(hosts, causes, refusedByPeer = refused)
    }

    /**
     * One pinned TLS 1.3 socket to [host]:[port], with the same context and timeouts as
     * [connect]; used for bulk connections (SPEC 13). Throws [IOException] if the connect or handshake fails.
     */
    internal suspend fun dialPinned(host: String, port: Int, pinnedFpHex: String): SSLSocket {
        val context = SSLContext.getInstance("TLSv1.3").apply {
            init(identity.keyManagers(), arrayOf(PinnedTrustManager(setOf(pinnedFpHex))), null)
        }
        return dial(context, host, port)
    }

    private suspend fun dial(context: SSLContext, host: String, port: Int): SSLSocket = coroutineScope {
        val raw = Socket()
        val done = AtomicBoolean(false)
        // Blocking connect/handshake ignore coroutine cancellation: closing the socket unblocks them.
        val watchdog = launch {
            try {
                awaitCancellation()
            } finally {
                if (!done.get()) runCatching { raw.close() }
            }
        }
        try {
            // If cancellation lands after the block finished (done = true), withContext still
            // throws: the catch below closes the socket so it does not leak.
            withContext(Dispatchers.IO) {
                var ssl: SSLSocket? = null
                try {
                    raw.tcpNoDelay = true
                    raw.connect(InetSocketAddress(host, port), connectTimeoutMs)
                    runCatching { tuner.tune(raw) }.onFailure { e ->
                        System.err.println("TlsConnector: socket tuning failed: ${e.javaClass.simpleName}")
                    }
                    raw.soTimeout = connectTimeoutMs
                    ssl = context.socketFactory.createSocket(raw, host, port, true) as SSLSocket
                    ssl.enabledProtocols = arrayOf("TLSv1.3")
                    ssl.useClientMode = true
                    ssl.startHandshake()
                    if (ssl.session.protocol != "TLSv1.3") throw IOException("negotiated ${ssl.session.protocol}")
                    ssl.soTimeout = 0
                    done.set(true)
                    ssl
                } catch (t: Throwable) {
                    runCatching { ssl?.close() }
                    runCatching { raw.close() }
                    throw t
                }
            }
        } catch (t: Throwable) {
            runCatching { raw.close() } // autoClose: closes the SSL layer too
            throw t
        } finally {
            watchdog.cancel()
        }
    }
}
