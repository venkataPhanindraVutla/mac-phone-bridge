package io.github.anmirror.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/** The two Wireless debugging services the phone advertises over NSD. */
enum class AdbService(internal val nsdType: String) {
    /** Up only while "Pair device with pairing code" is open. */
    PAIRING("_adb-tls-pairing._tcp"),

    /** Up while Wireless debugging is on. */
    CONNECT("_adb-tls-connect._tcp"),
}

/** Where a service listens: the phone's own address and port. */
data class AdbEndpoint(val host: String, val port: Int)

interface AdbServiceFinder {
    /** The phone's own endpoint for [service], or null when none is found within [timeoutMs]. */
    suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint?
}

/** A service NSD reported; [raw] is the platform's record, handed back to [NsdApi.resolve]. */
internal class FoundService(val name: String, val raw: Any?)

/** A resolved service: its addresses and port. */
internal class ResolvedService(val hosts: List<InetAddress>, val port: Int)

internal interface DiscoveryCallbacks {
    fun onStarted()
    fun onStartFailed()
    fun onFound(service: FoundService)
}

/** The parts of [NsdManager] the finder uses, so tests can drive them. */
internal interface NsdApi {
    /** Starts browsing [type]; returns the token [stopDiscovery] takes. */
    fun startDiscovery(type: String, callbacks: DiscoveryCallbacks): Any

    fun stopDiscovery(token: Any)

    /** Resolves [service]; [done] gets null when the resolve failed. */
    fun resolve(service: FoundService, done: (ResolvedService?) -> Unit)
}

/**
 * [AdbServiceFinder] over NSD (ruling R47), keeping only records whose address is one of this
 * phone's own ([ownAddresses]): other phones on the network advertise the same services. Resolves
 * run one at a time for the whole finder (before API 34 the platform refuses a second one), and a
 * failed resolve is tried once more. A search ended before its discovery has started is still
 * stopped. Nothing here binds or listens. Some phones never advertise; the typed port is the
 * fallback.
 */
internal class NsdAdbFinder(
    private val nsd: NsdApi,
    private val ownAddresses: () -> Set<InetAddress>,
) : AdbServiceFinder {
    private val lock = Any()
    private val queue = ArrayDeque<Pending>()
    private var resolving = false

    private class Pending(val search: Search, val service: FoundService, val retried: Boolean)

    override suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint? {
        val search = Search(service.nsdType)
        try {
            return withTimeoutOrNull(timeoutMs) {
                suspendCancellableCoroutine { cont -> search.start(cont) }
            }
        } finally {
            search.stop()
        }
    }

    private fun enqueue(pending: Pending) {
        synchronized(lock) {
            queue.addLast(pending)
            if (resolving) return
            resolving = true
        }
        resolveNext()
    }

    private fun resolveNext() {
        val next = synchronized(lock) {
            while (queue.isNotEmpty() && queue.first().search.finished) queue.removeFirst()
            queue.removeFirstOrNull().also { if (it == null) resolving = false }
        } ?: return
        val handled = AtomicBoolean(false)
        val done: (ResolvedService?) -> Unit = { resolved ->
            if (handled.compareAndSet(false, true)) {
                when {
                    resolved != null -> next.search.onResolved(resolved)
                    !next.retried -> synchronized(lock) { queue.addLast(Pending(next.search, next.service, retried = true)) }
                }
                resolveNext()
            }
        }
        try {
            nsd.resolve(next.service, done)
        } catch (e: RuntimeException) { // the platform refused the request
            done(null)
        }
    }

    private inner class Search(private val type: String) : DiscoveryCallbacks {
        private val stateLock = Any()
        private var token: Any? = null
        private var stopped = false
        private var cont: CancellableContinuation<AdbEndpoint?>? = null
        private val answered = AtomicBoolean(false)

        val finished: Boolean get() = answered.get() || synchronized(stateLock) { stopped }

        fun start(continuation: CancellableContinuation<AdbEndpoint?>) {
            cont = continuation
            val t = try {
                nsd.startDiscovery(type, this)
            } catch (e: RuntimeException) {
                answer(null)
                return
            }
            val stopNow = synchronized(stateLock) {
                token = t
                stopped
            }
            if (stopNow) stopDiscovery(t)
        }

        /** Idempotent; also stops a discovery whose start the platform has not confirmed yet. */
        fun stop() {
            val t = synchronized(stateLock) {
                if (stopped) return
                stopped = true
                token
            } ?: return
            stopDiscovery(t)
        }

        private fun stopDiscovery(t: Any) {
            try {
                nsd.stopDiscovery(t)
            } catch (e: RuntimeException) { // the platform had already dropped it
            }
        }

        override fun onStarted() = Unit

        override fun onStartFailed() = answer(null)

        override fun onFound(service: FoundService) {
            if (!finished) enqueue(Pending(this, service, retried = false))
        }

        fun onResolved(resolved: ResolvedService) {
            if (resolved.port !in 1..MAX_PORT) return
            val own = ownAddresses()
            val host = resolved.hosts.firstOrNull { it in own }?.hostAddress ?: return
            answer(AdbEndpoint(host, resolved.port))
        }

        private fun answer(endpoint: AdbEndpoint?) {
            if (answered.compareAndSet(false, true)) cont?.resume(endpoint)
        }
    }

    private companion object {
        const val MAX_PORT = 65_535
    }
}

/** [NsdApi] over the platform's [NsdManager]. */
internal class AndroidNsdApi(context: Context) : NsdApi {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)

    override fun startDiscovery(type: String, callbacks: DiscoveryCallbacks): Any {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = callbacks.onStarted()
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = callbacks.onStartFailed()
            override fun onServiceFound(info: NsdServiceInfo) = callbacks.onFound(FoundService(info.serviceName, info))
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        // Registers the listener at once, so stopServiceDiscovery works before onDiscoveryStarted.
        nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
        return listener
    }

    override fun stopDiscovery(token: Any) {
        nsd.stopServiceDiscovery(token as NsdManager.DiscoveryListener)
    }

    // resolveService is deprecated from API 34 but still works there, and is the only call below it.
    @Suppress("DEPRECATION")
    override fun resolve(service: FoundService, done: (ResolvedService?) -> Unit) {
        nsd.resolveService(
            service.raw as NsdServiceInfo,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done(null)
                override fun onServiceResolved(info: NsdServiceInfo) = done(ResolvedService(hostsOf(info), info.port))
            },
        )
    }

    @Suppress("DEPRECATION")
    private fun hostsOf(info: NsdServiceInfo): List<InetAddress> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) info.hostAddresses else listOfNotNull(info.host)
}

/** The Wireless debugging services on this phone, found over NSD. */
class NsdAdbServices(context: Context) : AdbServiceFinder by NsdAdbFinder(AndroidNsdApi(context), ::ownAddresses)

/** Every address of every interface of this phone; empty when they can't be listed. */
internal fun ownAddresses(): Set<InetAddress> = try {
    NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().flatMap { it.inetAddresses.toList() }.toSet()
} catch (e: Exception) {
    emptySet()
}
