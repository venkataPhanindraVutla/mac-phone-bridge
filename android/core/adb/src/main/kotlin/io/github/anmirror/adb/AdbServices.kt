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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
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

    /** Resolves [service]; [done] gets null when the resolve failed. Returns the token [stopResolve] takes. */
    fun resolve(service: FoundService, done: (ResolvedService?) -> Unit): Any

    /** Gives up a resolve that never answered (API 34+; earlier the platform has no way to). */
    fun stopResolve(token: Any)
}

/** Runs [action] after [delayMs]; the returned function cancels it. Tests drive time by hand. */
internal fun interface Timer {
    fun schedule(delayMs: Long, action: () -> Unit): () -> Unit
}

/** [Timer] on one shared daemon thread. */
internal object ExecutorTimer : Timer {
    private val executor = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "adb-nsd-timer").apply { isDaemon = true } }

    override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
        val future = executor.schedule(action, delayMs, TimeUnit.MILLISECONDS)
        return { future.cancel(false) }
    }
}

/**
 * [AdbServiceFinder] over NSD (ruling R47), keeping only records whose address is one of this
 * phone's own ([ownAddresses]): other phones on the network advertise the same services. Resolves
 * run one at a time for the whole finder (before API 34 the platform refuses a second one); one
 * that doesn't answer within [RESOLVE_TIMEOUT_MS] is given up (and stopped on API 34+), so it can't
 * hold up later lookups. A failed or silent resolve is tried once more, [RETRY_DELAY_MS] later
 * (another resolve on the same NsdManager, the Mac discovery's, may be what refused it). A search ended before its discovery has started is still
 * stopped. Nothing here binds or listens. Some phones never advertise; the typed port is the
 * fallback.
 */
internal class NsdAdbFinder(
    private val nsd: NsdApi,
    private val ownAddresses: () -> Set<InetAddress>,
    private val timer: Timer = ExecutorTimer,
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
        val token = AtomicReference<Any?>(null)
        val cancelTimeout = AtomicReference<() -> Unit>({})
        val done: (ResolvedService?) -> Unit = { resolved ->
            if (handled.compareAndSet(false, true)) {
                cancelTimeout.get().invoke()
                when {
                    resolved != null -> next.search.onResolved(resolved)
                    !next.retried -> timer.schedule(RETRY_DELAY_MS) {
                        if (!next.search.finished) enqueue(Pending(next.search, next.service, retried = true))
                    }
                }
                resolveNext()
            }
        }
        // Armed first: a resolve may answer before resolve() returns.
        cancelTimeout.set(
            timer.schedule(RESOLVE_TIMEOUT_MS) {
                if (!handled.get()) {
                    token.get()?.let { t -> runCatching { nsd.stopResolve(t) } }
                    done(null)
                }
            },
        )
        try {
            token.set(nsd.resolve(next.service, done))
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

    companion object {
        private const val MAX_PORT = 65_535
        const val RESOLVE_TIMEOUT_MS = 3_000L
        const val RETRY_DELAY_MS = 750L
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
    override fun resolve(service: FoundService, done: (ResolvedService?) -> Unit): Any {
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done(null)
            override fun onServiceResolved(info: NsdServiceInfo) = done(ResolvedService(hostsOf(info), info.port))
        }
        nsd.resolveService(service.raw as NsdServiceInfo, listener)
        return listener
    }

    override fun stopResolve(token: Any) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            nsd.stopServiceResolution(token as NsdManager.ResolveListener)
        }
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
