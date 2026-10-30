package io.github.anmirror.feature.proximity

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.github.anmirror.protocol.PairingCrypto

/** Whether the phone can advertise over Bluetooth LE right now. */
enum class AdvertiserState { READY, BLUETOOTH_OFF, UNSUPPORTED }

/** What an advertising set reports, on the main thread (or before [BleAdvertiser.start] returns). */
sealed interface AdvertiserEvent {
    /** The controller took the set: it is on the air. */
    data object Started : AdvertiserEvent

    /** The start, or new data, failed with an `AdvertisingSetCallback` code. */
    data class Failed(val code: Int) : AdvertiserEvent

    /** The system stopped the set (Bluetooth going off, say); never sent for [AdvertisingSlot.stop]. */
    data object StoppedBySystem : AdvertiserEvent
}

/** One advertising set. */
interface AdvertisingSlot {
    /** Replaces the service data in place: the controller slot is kept (ruling R30). */
    fun setData(serviceData: ByteArray)

    /** Stops the set; harmless when it never started. */
    fun stop()
}

/** Starts proximity advertising sets. */
interface BleAdvertiser {
    fun state(): AdvertiserState

    /** Starts one set with [serviceData] under the proximity service UUID; [events] tells how it goes. */
    fun start(serviceData: ByteArray, events: (AdvertiserEvent) -> Unit): AdvertisingSlot
}

/**
 * Legacy advertising sets (SPEC 22, ruling R30): legacy mode (31 bytes), not connectable, not
 * scannable, medium TX power, the high (power-saving, 1 s) interval, and only the service data:
 * no device name, no TX power level, no service-UUID list. Not connectable, Android adds no flags
 * element: 26 bytes in all. A missing BLUETOOTH_ADVERTISE (API 31+), a SecurityException or an
 * IllegalStateException (Bluetooth went off) is a [AdvertiserEvent.Failed], never a crash.
 */
class AndroidBleAdvertiser(context: Context) : BleAdvertiser {
    private val app = context.applicationContext
    private val manager = app.getSystemService(BluetoothManager::class.java)

    /**
     * READY only with the adapter fully on: `isEnabled` is false in STATE_BLE_ON (the BLE-only
     * mode some phones keep for scanning while Bluetooth is "off"), which counts as off. That is
     * the safe side: the Mac hears "unavailable" rather than a phone that may not be on the air.
     */
    override fun state(): AdvertiserState {
        if (!app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return AdvertiserState.UNSUPPORTED
        val adapter = manager?.adapter ?: return AdvertiserState.UNSUPPORTED
        if (!adapter.isEnabled) return AdvertiserState.BLUETOOTH_OFF
        // The advertiser is null while Bluetooth is off, so it is only asked for once it is on.
        if (adapter.bluetoothLeAdvertiser == null || !adapter.isMultipleAdvertisementSupported) return AdvertiserState.UNSUPPORTED
        return AdvertiserState.READY
    }

    // The permission is checked first (mayAdvertise); lint cannot follow the SDK-dependent check.
    @SuppressLint("MissingPermission")
    override fun start(serviceData: ByteArray, events: (AdvertiserEvent) -> Unit): AdvertisingSlot {
        val advertiser = manager?.adapter?.bluetoothLeAdvertiser
        if (advertiser == null || !mayAdvertise()) {
            events(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED))
            return NoSlot
        }
        val slot = Slot(advertiser, events)
        val parameters = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_HIGH)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()
        try {
            // Callbacks on the main thread; no scan response, no periodic advertising.
            advertiser.startAdvertisingSet(parameters, data(serviceData), null, null, null, slot.callback)
        } catch (e: SecurityException) {
            events(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
            return NoSlot
        } catch (e: IllegalStateException) {
            events(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
            return NoSlot
        }
        return slot
    }

    private fun data(serviceData: ByteArray): AdvertiseData = AdvertiseData.Builder()
        .setIncludeDeviceName(false)
        .setIncludeTxPowerLevel(false)
        .addServiceData(ParcelUuid.fromString(PairingCrypto.BLE_SERVICE_UUID), serviceData)
        .build()

    /** BLUETOOTH_ADVERTISE on API 31+; up to 30, BLUETOOTH_ADMIN is granted at install. */
    private fun mayAdvertise(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

    private object NoSlot : AdvertisingSlot {
        override fun setData(serviceData: ByteArray) = Unit
        override fun stop() = Unit
    }

    /** A set and its callback; data given before the controller took the set is applied once it has. */
    private inner class Slot(
        private val advertiser: BluetoothLeAdvertiser,
        private val events: (AdvertiserEvent) -> Unit,
    ) : AdvertisingSlot {
        private var set: AdvertisingSet? = null
        private var pending: ByteArray? = null
        private var stopped = false

        val callback = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(advertisingSet: AdvertisingSet?, txPower: Int, status: Int) {
                if (status != ADVERTISE_SUCCESS || advertisingSet == null) {
                    report(AdvertiserEvent.Failed(status))
                    return
                }
                val newer = synchronized(this@Slot) {
                    set = advertisingSet
                    pending.also { pending = null }
                }
                report(AdvertiserEvent.Started)
                newer?.let(::setData)
            }

            override fun onAdvertisingDataSet(advertisingSet: AdvertisingSet?, status: Int) {
                if (status != ADVERTISE_SUCCESS) report(AdvertiserEvent.Failed(status))
            }

            override fun onAdvertisingSetStopped(advertisingSet: AdvertisingSet?) {
                if (!synchronized(this@Slot) { stopped }) report(AdvertiserEvent.StoppedBySystem)
            }
        }

        private fun report(event: AdvertiserEvent) {
            if (!synchronized(this) { stopped }) events(event)
        }

        // The permission is checked first (mayAdvertise); lint cannot follow the SDK-dependent check.
        @SuppressLint("MissingPermission")
        override fun setData(serviceData: ByteArray) {
            val target = synchronized(this) {
                if (stopped) return
                set ?: run {
                    pending = serviceData
                    return
                }
            }
            if (!mayAdvertise()) {
                report(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
                return
            }
            try {
                target.setAdvertisingData(data(serviceData))
            } catch (e: SecurityException) {
                report(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
            } catch (e: IllegalStateException) {
                report(AdvertiserEvent.Failed(AdvertisingSetCallback.ADVERTISE_FAILED_INTERNAL_ERROR))
            }
        }

        // The permission is checked first (mayAdvertise); lint cannot follow the SDK-dependent check.
        @SuppressLint("MissingPermission")
        override fun stop() {
            synchronized(this) {
                if (stopped) return
                stopped = true
            }
            if (!mayAdvertise()) return // without the permission the system has stopped it
            try {
                advertiser.stopAdvertisingSet(callback)
            } catch (e: SecurityException) {
                // The permission was withdrawn: the system stops the set itself.
            } catch (e: IllegalStateException) {
                // Bluetooth is off: the set has already ended.
            }
        }
    }
}
