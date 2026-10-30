package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.protocol.PairingCrypto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

private const val EPOCH_MS = 900_000L

/** Milliseconds from [nowMs] (Unix time) to the start of the next 15-minute epoch (SPEC 6); never 0. */
fun msUntilNextEpoch(nowMs: Long): Long = EPOCH_MS - Math.floorMod(nowMs, EPOCH_MS)

/**
 * The phone's Bluetooth LE beacon for auto-lock (F-15, SPEC 22). While [update] says it is active,
 * a Mac is given and the adapter is ready, it advertises that Mac's BLE ID for this phone and the
 * current epoch, and restarts with the next epoch's ID 1 s after each boundary. Each [update]
 * stops what runs and starts afresh; not active, no Mac, or an adapter that is not ready, stops.
 * It does not depend on the LAN connection. Logs only error codes, never the ID.
 */
class ProximityBeacon(
    private val advertiser: BleAdvertiser,
    private val phoneFp: ByteArray,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val _advertising = MutableStateFlow(false)

    /** True from a start until its stop or failure. */
    val advertising: StateFlow<Boolean> = _advertising.asStateFlow()

    private val lock = Any()

    /** Bumped by each [update]: a timer or a failure of an earlier one does nothing. Guarded by [lock]. */
    private var generation = 0L
    private var timer: Job? = null
    private var started = false

    /** [active]: the switch is on and the permission granted. [mac]: the one to advertise for ([AdvertisedMac]). */
    fun update(active: Boolean, mac: PairedMac?) {
        synchronized(lock) {
            generation++
            timer?.cancel()
            timer = null
            stopLocked()
            if (!active || mac == null || advertiser.state() != AdvertiserState.READY) return
            val gen = generation
            timer = scope.launch {
                while (true) {
                    val now = clock()
                    synchronized(lock) {
                        if (gen != generation) return@launch
                        stopLocked()
                        startLocked(gen, mac, now)
                    }
                    delay(msUntilNextEpoch(now) + RESTART_AFTER_BOUNDARY_MS)
                }
            }
        }
    }

    private fun startLocked(gen: Long, mac: PairedMac, nowMs: Long) {
        val id = PairingCrypto.bleId(mac.discoveryKey, phoneFp, PairingCrypto.epochOf(Math.floorDiv(nowMs, 1000L)))
        started = true
        _advertising.value = true
        advertiser.start(id) { code ->
            synchronized(lock) {
                if (gen == generation) _advertising.value = false
            }
            log("proximity: advertise failed ($code)")
        }
    }

    private fun stopLocked() {
        if (!started) return
        started = false
        advertiser.stop()
        _advertising.value = false
    }

    private companion object {
        /** The restart waits this long past the boundary, so the new epoch is surely under way. */
        const val RESTART_AFTER_BOUNDARY_MS = 1_000L
    }
}
