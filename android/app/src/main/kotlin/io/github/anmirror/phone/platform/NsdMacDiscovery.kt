package io.github.anmirror.phone.platform

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import io.github.anmirror.connection.DiscoveredService
import io.github.anmirror.connection.MacDiscovery
import io.github.anmirror.phone.TAG
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executor

/**
 * Browses `_anmirror._tcp` with [NsdManager] and resolves each service (address, port, TXT).
 *
 * One browse is shared by every collector: it starts with the first and stops 5 s after the
 * last leaves (ConnectionManager subscribes only while disconnected). A new collector first
 * gets every service currently known, then each new or changed one.
 */
class NsdMacDiscovery(context: Context, scope: CoroutineScope) : MacDiscovery {
    private val app = context.applicationContext
    private val nsd: NsdManager = checkNotNull(app.getSystemService(NsdManager::class.java))

    private val known: StateFlow<Map<String, DiscoveredService>> = flow {
        while (true) {
            emitAll(browse())
            // The browse failed to start or was stopped by the system: start again a bit later.
            delay(RESTART_DELAY_MS)
        }
    }.stateIn(scope, SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000, replayExpirationMillis = 0), emptyMap())

    override fun services(): Flow<DiscoveredService> = flow {
        var seen = emptyMap<String, DiscoveredService>()
        known.collect { now ->
            for ((name, service) in now) if (seen[name] != service) emit(service)
            seen = now
        }
    }

    /** One NSD browse, as the map of service name to resolved service. Completes if it fails. */
    private fun browse(): Flow<Map<String, DiscoveredService>> = callbackFlow {
        val lock = Any()
        val services = HashMap<String, DiscoveredService>()
        val callbacks = HashMap<String, NsdManager.ServiceInfoCallback>()
        val resolver = if (useServiceInfoCallback()) null else SerialResolver()

        fun put(name: String, info: NsdServiceInfo) {
            val service = info.toDiscovered() ?: return
            synchronized(lock) {
                if (services[name] == service) return
                services[name] = service
                trySend(HashMap(services))
            }
            Log.d(TAG, "nsd: resolved ${service.host}:${service.port}")
        }

        fun drop(name: String) {
            synchronized(lock) { if (services.remove(name) != null) trySend(HashMap(services)) }
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "nsd: browsing $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                // Also when the system stops the browse: end this one so the loop starts another.
                Log.d(TAG, "nsd: stopped")
                channel.close()
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "nsd: start failed ($errorCode)")
                channel.close()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "nsd: stop failed ($errorCode)")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                val name = info.serviceName
                if (useServiceInfoCallback()) {
                    synchronized(lock) {
                        if (callbacks.containsKey(name)) return
                        lateinit var cb: NsdManager.ServiceInfoCallback
                        cb = infoCallback(name, ::put, ::drop) {
                            // Registration failed: forget it (only if still this callback), so the
                            // next onServiceFound retries.
                            synchronized(lock) { callbacks.remove(name, cb) }
                        }
                        callbacks[name] = cb
                        try {
                            nsd.registerServiceInfoCallback(info, DirectExecutor, cb)
                        } catch (e: IllegalArgumentException) {
                            callbacks.remove(name, cb)
                            Log.w(TAG, "nsd: cannot watch service", e)
                        }
                    }
                } else {
                    resolver?.resolve(info) { put(name, it) }
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                val name = info.serviceName
                drop(name)
                if (useServiceInfoCallback()) {
                    val cb = synchronized(lock) { callbacks.remove(name) }
                    if (cb != null) runCatching { nsd.unregisterServiceInfoCallback(cb) }
                }
            }
        }

        // Before API 34 some Wi-Fi drivers drop multicast unless an app holds this lock while
        // browsing. From 34 the system's mDNS stack handles it.
        val multicast = if (useServiceInfoCallback()) {
            null
        } else {
            app.getSystemService(WifiManager::class.java)?.createMulticastLock("anmirror-nsd")
                ?.apply { setReferenceCounted(false) }
        }
        multicast?.acquire()
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "nsd: cannot browse", e)
            channel.close()
        }
        awaitClose {
            runCatching { nsd.stopServiceDiscovery(listener) }
            val all = synchronized(lock) { callbacks.values.toList().also { callbacks.clear() } }
            if (useServiceInfoCallback()) all.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
            multicast?.release()
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun infoCallback(
        name: String,
        put: (String, NsdServiceInfo) -> Unit,
        drop: (String) -> Unit,
        failed: () -> Unit,
    ) = object : NsdManager.ServiceInfoCallback {
        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
            Log.w(TAG, "nsd: resolve failed ($errorCode)")
            failed()
        }

        override fun onServiceUpdated(info: NsdServiceInfo) = put(name, info)

        override fun onServiceLost() = drop(name)

        override fun onServiceInfoCallbackUnregistered() = Unit
    }

    /** Before API 34, NsdManager resolves one service at a time. */
    private inner class SerialResolver {
        private val lock = Any()
        private val queue = ArrayDeque<Pair<NsdServiceInfo, (NsdServiceInfo) -> Unit>>()
        private var busy = false

        fun resolve(info: NsdServiceInfo, onResolved: (NsdServiceInfo) -> Unit) {
            synchronized(lock) { queue.addLast(info to onResolved) }
            next()
        }

        @Suppress("DEPRECATION")
        private fun next() {
            val (info, onResolved) = synchronized(lock) {
                if (busy) return
                val item = queue.removeFirstOrNull() ?: return
                busy = true
                item
            }
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    onResolved(resolved)
                    done()
                }

                override fun onResolveFailed(failed: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "nsd: resolve failed ($errorCode)")
                    done()
                }
            })
        }

        private fun done() {
            synchronized(lock) { busy = false }
            next()
        }
    }

    private object DirectExecutor : Executor {
        override fun execute(command: Runnable) = command.run()
    }

    companion object {
        const val SERVICE_TYPE = "_anmirror._tcp"
        private const val RESTART_DELAY_MS = 10_000L

        @ChecksSdkIntAtLeast(api = Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        private fun useServiceInfoCallback(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

        @Suppress("DEPRECATION")
        private fun NsdServiceInfo.toDiscovered(): DiscoveredService? {
            val addresses: List<InetAddress> =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) hostAddresses else listOfNotNull(host)
            // IPv4 first: link-local IPv6 needs a scope and is the least likely to route.
            val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull() ?: return null
            if (port <= 0) return null
            val txt = attributes.mapValues { (_, v) -> v?.decodeToString() ?: "" }
            return DiscoveredService(address.hostAddress ?: return null, port, txt)
        }
    }
}
