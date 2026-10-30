package io.github.anmirror.phone.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import io.github.anmirror.phone.TAG
import java.util.concurrent.ConcurrentHashMap

/**
 * Calls [onChange] when a Wi-Fi or Ethernet network comes up, goes away, or changes its
 * addresses: the moments the Mac may have become reachable at a new address. The app wires it
 * to `ConnectionManager.kick()`, which retries at once (or pings, if connected). [onChange]
 * hears which: `available`, `lost` or `changed`.
 */
class NetworkWatcher(context: Context, private val onChange: (kind: String) -> Unit) {
    private val connectivity: ConnectivityManager =
        checkNotNull(context.applicationContext.getSystemService(ConnectivityManager::class.java))
    private val addresses = ConcurrentHashMap<Network, Set<String>>()
    @Volatile private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.d(TAG, "network: available")
            onChange("available")
        }

        override fun onLost(network: Network) {
            addresses.remove(network)
            Log.d(TAG, "network: lost")
            onChange("lost")
        }

        override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) {
            val now = link.linkAddresses.map { it.address.hostAddress.orEmpty() }.toSet()
            val before = addresses.put(network, now)
            if (before != null && before != now) {
                Log.d(TAG, "network: addresses changed")
                onChange("changed")
            }
        }
    }

    fun start() {
        if (registered) return
        // A LAN without internet access still counts: the Mac is on the LAN.
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.registerNetworkCallback(request, callback)
        registered = true
    }

    fun stop() {
        if (!registered) return
        registered = false
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        addresses.clear()
    }
}
