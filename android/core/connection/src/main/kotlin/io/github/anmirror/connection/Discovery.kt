package io.github.anmirror.connection

import io.github.anmirror.protocol.PairingCrypto
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow

/** One `_anmirror._tcp` service seen on the network, with its TXT record (keys `v`, `r`). */
data class DiscoveredService(val host: String, val port: Int, val txt: Map<String, String>)

/** Bonjour/NSD browsing. The app implements it with NsdManager (Task 9). */
fun interface MacDiscovery {
    fun services(): Flow<DiscoveredService>
}

/** A fixed list of services, emitted once per collection (tests and tools). */
class StaticDiscovery(private val list: List<DiscoveredService>) : MacDiscovery {
    override fun services(): Flow<DiscoveredService> = list.asFlow()
}

/** True if [service]'s TXT `r` is [mac]'s rotating ID for the epoch before, of or after now (SPEC 6). */
fun matchesMac(service: DiscoveredService, mac: PairedMac, unixSeconds: Long): Boolean {
    val r = service.txt["r"] ?: return false
    return PairingCrypto.matchesRotatingId(r, mac.discoveryKey, unixSeconds)
}
