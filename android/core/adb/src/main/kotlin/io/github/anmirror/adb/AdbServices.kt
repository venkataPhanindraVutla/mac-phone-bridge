package io.github.anmirror.adb

import android.content.Context
import io.github.muntashirakon.adb.android.AdbMdns
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/** The two Wireless debugging services the phone advertises over NSD. */
enum class AdbService(internal val nsdType: String) {
    /** `_adb-tls-pairing._tcp`: up only while "Pair device with pairing code" is open. */
    PAIRING(AdbMdns.SERVICE_TYPE_TLS_PAIRING),

    /** `_adb-tls-connect._tcp`: up while Wireless debugging is on. */
    CONNECT(AdbMdns.SERVICE_TYPE_TLS_CONNECT),
}

/** Where a service listens: the phone's own address and port. */
data class AdbEndpoint(val host: String, val port: Int)

interface AdbServiceFinder {
    /** The phone's own endpoint for [service], or null when none is found within [timeoutMs]. */
    suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint?
}

/**
 * [AdbServiceFinder] over libadb's [AdbMdns], which keeps only records whose host is one of this
 * phone's own addresses. Some phones never advertise (the typed port is the fallback).
 */
class LibAdbServices(context: Context) : AdbServiceFinder {
    private val app = context.applicationContext

    override suspend fun find(service: AdbService, timeoutMs: Long): AdbEndpoint? {
        var mdns: AdbMdns? = null
        try {
            return withTimeoutOrNull(timeoutMs) {
                suspendCancellableCoroutine { cont ->
                    val answered = AtomicBoolean(false)
                    fun answer(endpoint: AdbEndpoint?) {
                        if (answered.compareAndSet(false, true)) cont.resume(endpoint)
                    }
                    // A lost service is reported as port -1.
                    val m = AdbMdns(app, service.nsdType) { host, port ->
                        val address = host?.hostAddress
                        if (address != null && port in 1..MAX_PORT) answer(AdbEndpoint(address, port))
                    }
                    mdns = m
                    try {
                        m.start()
                    } catch (e: RuntimeException) { // NsdManager refused the discovery
                        answer(null)
                    }
                }
            }
        } finally {
            mdns?.let { runCatching { it.stop() } }
        }
    }

    private companion object {
        const val MAX_PORT = 65_535
    }
}
