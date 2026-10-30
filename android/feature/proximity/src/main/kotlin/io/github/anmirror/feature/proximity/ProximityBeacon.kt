package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.protocol.PairingCrypto
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One Mac's advertisement. */
sealed interface BeaconState {
    data object Starting : BeaconState
    data object On : BeaconState
    data class Failed(val code: Int) : BeaconState
}

/**
 * The phone's Bluetooth LE beacon for auto-lock (F-15, SPEC 22, rulings R29–R31): one legacy
 * advertising set per Mac given to [update] (up to [AdvertisedMacs.MAX], in priority order), each
 * carrying that Mac's BLE ID for this phone and the current epoch.
 *
 * - **Rotation:** a wall-clock [WakeAlarm] 1 s past each boundary calls [onClockCheck], which
 *   recomputes the epoch from [clock] and gives every started set its new ID in place (a set still
 *   starting starts again with it). A late alarm, a clock change or the screen coming on just
 *   calls [onClockCheck] again.
 * - **Failures:** a failed start, refused new data, new data the stack does not confirm within
 *   [DATA_CONFIRM_MS], or a set the system stopped is [BeaconState.Failed] and retried after
 *   [RetryBackoff]; the sets that did start are kept.
 * - **Adapter blips:** after [markAdapterNotReady] (Bluetooth left the on state, if only for a
 *   moment) no set is trusted: the next [update] or [refresh] starts them all again, since the
 *   stack may have dropped them without a word.
 * - **[faulted]:** the Macs whose last confirmed state is a failure. A retry in progress keeps the
 *   fault (no flicker); only a successful start clears it. The availability sent to a connected
 *   Mac reads it.
 *
 * Not active, no Mac, or an adapter that is not ready stops every set and the alarm. It does not
 * depend on the LAN connection. Thread-safe; logs only error codes, never an ID.
 */
class ProximityBeacon(
    private val advertiser: BleAdvertiser,
    private val alarm: WakeAlarm,
    private val phoneFp: () -> ByteArray,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private class Slot(val mac: PairedMac) {
        /** Identifies the current set: events of an earlier one are dropped. */
        var token = Any()
        var handle: AdvertisingSlot? = null
        var state: BeaconState = BeaconState.Starting
        var epoch = 0L
        var faulted = false
        var failures = 0
        var retryAt: Long? = null

        /** New data awaits the stack's confirmation until then. */
        var confirmBy: Long? = null
    }

    private val lock = Any()

    /** By Mac id, in the order started; guarded by [lock]. */
    private val slots = LinkedHashMap<String, Slot>()

    /** The last [update]'s inputs, for [refresh]; guarded by [lock]. */
    private var lastActive = false
    private var lastMacs: List<PairedMac> = emptyList()

    /** The adapter was not ready at some point since the last [update]; guarded by [lock]. */
    private var adapterDropped = false

    private val _states = MutableStateFlow<Map<String, BeaconState>>(emptyMap())

    /** Each advertised Mac's state, by Mac id; empty while the beacon is stopped. Diagnostic only (tests); availability reads [faulted]. */
    val states: StateFlow<Map<String, BeaconState>> = _states.asStateFlow()

    private val _faulted = MutableStateFlow<Set<String>>(emptySet())

    /** The ids of the Macs whose advertisement last failed and has not started since. */
    val faulted: StateFlow<Set<String>> = _faulted.asStateFlow()

    /**
     * [active]: the switch is on and the permission granted. [macs]: the ones to advertise for,
     * in priority order ([AdvertisedMacs.pick]). Sets of Macs no longer listed (forgotten, or
     * pushed out) stop; new ones start; the others carry on untouched.
     */
    fun update(active: Boolean, macs: List<PairedMac>) = synchronized(lock) {
        lastActive = active
        lastMacs = macs
        if (adapterDropped) {
            adapterDropped = false
            for (slot in slots.values) stopSlot(slot)
            slots.clear()
        }
        val wanted = if (active && advertiser.state() == AdvertiserState.READY) macs.take(AdvertisedMacs.MAX) else emptyList()
        for (slot in slots.values.toList()) {
            val keep = wanted.firstOrNull { it.id == slot.mac.id }
            if (keep == null || !keep.discoveryKey.contentEquals(slot.mac.discoveryKey)) {
                stopSlot(slot)
                slots.remove(slot.mac.id)
            }
        }
        val now = clock()
        for (mac in wanted) {
            if (mac.id in slots) continue
            val slot = Slot(mac)
            slots[mac.id] = slot
            startSlot(slot, now)
        }
        publishAndArm(now)
    }

    /**
     * Bluetooth left the on state (off, turning off, BLE-only): every set is to be started again
     * by the next [update] or [refresh]. Called by the adapter's state receiver directly, so a
     * quick off and on that the adapter state never shows still counts.
     */
    fun markAdapterNotReady() = synchronized(lock) {
        adapterDropped = true
    }

    /** [update] again with the last inputs (the adapter came back on). */
    fun refresh() = synchronized(lock) {
        update(lastActive, lastMacs)
    }

    /** Stops everything (the service is going away). */
    fun stop() = update(active = false, macs = emptyList())

    /**
     * The alarm fired, the clock or time zone changed, the screen came on, or Doze changed: rotate
     * every set whose epoch is no longer the current one, retry the failed ones that are due, and
     * set the next alarm.
     */
    fun onClockCheck() = synchronized(lock) {
        if (slots.isEmpty()) {
            alarm.cancel()
            return@synchronized
        }
        val now = clock()
        val epoch = RotationSchedule.epochAt(now)
        for (slot in slots.values.toList()) {
            val confirmBy = slot.confirmBy
            when {
                slot.state is BeaconState.Failed -> {
                    val due = slot.retryAt ?: now
                    // A retry further off than the longest wait means the clock went back: due now.
                    if (due <= now || due - now > RetryBackoff.MAX_MS) startSlot(slot, now)
                }
                // The same for a deadline further off than the confirmation wait.
                confirmBy != null && (confirmBy <= now || confirmBy - now > DATA_CONFIRM_MS) ->
                    fail(slot, CODE_DATA_TIMEOUT, now)
                slot.epoch == epoch -> Unit
                slot.state == BeaconState.On -> {
                    slot.epoch = epoch
                    slot.confirmBy = now + DATA_CONFIRM_MS
                    slot.handle?.setData(bleId(slot.mac, epoch))
                }
                // Still starting: nothing is on the air to keep, so start again with the new ID.
                else -> {
                    stopSlot(slot)
                    startSlot(slot, now)
                }
            }
        }
        publishAndArm(clock())
    }

    private fun bleId(mac: PairedMac, epoch: Long): ByteArray = PairingCrypto.bleId(mac.discoveryKey, phoneFp(), epoch)

    private fun startSlot(slot: Slot, now: Long) {
        val token = Any()
        slot.token = token
        slot.state = BeaconState.Starting
        slot.retryAt = null
        slot.confirmBy = null
        slot.epoch = RotationSchedule.epochAt(now)
        val handle = advertiser.start(bleId(slot.mac, slot.epoch)) { event -> onEvent(slot, token, event) }
        // A failure reported before start returned has already moved on: the set is not kept.
        if (slot.token === token && slot.state !is BeaconState.Failed) slot.handle = handle else handle.stop()
    }

    private fun stopSlot(slot: Slot) {
        slot.token = Any()
        slot.handle?.stop()
        slot.handle = null
    }

    private fun onEvent(slot: Slot, token: Any, event: AdvertiserEvent) = synchronized(lock) {
        if (slots[slot.mac.id] !== slot || slot.token !== token) return@synchronized
        val now = clock()
        when (event) {
            AdvertiserEvent.Started -> {
                slot.state = BeaconState.On
                slot.faulted = false
                slot.failures = 0
            }
            AdvertiserEvent.DataSet -> slot.confirmBy = null
            is AdvertiserEvent.Failed -> fail(slot, event.code, now)
            AdvertiserEvent.StoppedBySystem -> fail(slot, CODE_STOPPED_BY_SYSTEM, now)
        }
        publishAndArm(now)
    }

    private fun fail(slot: Slot, code: Int, now: Long) {
        log("proximity: advertise failed ($code)")
        stopSlot(slot)
        slot.state = BeaconState.Failed(code)
        slot.faulted = true
        slot.confirmBy = null
        slot.retryAt = now + RetryBackoff.delayMs(slot.failures)
        slot.failures++
    }

    private fun publishAndArm(now: Long) {
        _states.value = slots.mapValues { it.value.state }
        _faulted.value = slots.values.filter { it.faulted }.map { it.mac.id }.toSet()
        if (slots.isEmpty()) {
            alarm.cancel()
        } else {
            alarm.set(RotationSchedule.nextWake(now, slots.values.flatMap { listOfNotNull(it.retryAt, it.confirmBy) }))
        }
    }

    companion object {
        /** [BeaconState.Failed]'s code when the system stopped a set ([AdvertiserEvent.StoppedBySystem]). */
        const val CODE_STOPPED_BY_SYSTEM = -1

        /** [BeaconState.Failed]'s code when new data was not confirmed within [DATA_CONFIRM_MS]. */
        const val CODE_DATA_TIMEOUT = -2

        /** How long new data may wait for `onAdvertisingDataSet`. */
        const val DATA_CONFIRM_MS = 5_000L
    }
}
