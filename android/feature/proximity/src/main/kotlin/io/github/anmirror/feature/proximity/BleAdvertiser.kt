package io.github.anmirror.feature.proximity

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.github.anmirror.protocol.PairingCrypto

/** Whether the phone can advertise over Bluetooth LE right now. */
enum class AdvertiserState { READY, BLUETOOTH_OFF, UNSUPPORTED }

/** Starts and stops the one proximity advertisement. */
interface BleAdvertiser {
    fun state(): AdvertiserState

    /** Advertises [serviceData] under the proximity service UUID; [onFailure] gets the error code. Replaces nothing: stop first. */
    fun start(serviceData: ByteArray, onFailure: (Int) -> Unit)

    /** Stops the advertisement; harmless when none runs. */
    fun stop()
}

/**
 * The legacy (31-byte) advertisement of SPEC 22: low power, medium TX power, not connectable, no
 * timeout, and only the service data (no device name, no TX power level, no service-UUID list).
 * Not connectable, Android adds no flags element: 26 bytes in all. The caller starts it only with
 * BLUETOOTH_ADVERTISE granted (API 31+); a refusal still arrives as a failure, never a crash.
 */
class AndroidBleAdvertiser(context: Context) : BleAdvertiser {
    private val app = context.applicationContext
    private val manager = app.getSystemService(BluetoothManager::class.java)

    /** The advertiser and callback of the running advertisement; stop needs the same pair. */
    private var running: Pair<BluetoothLeAdvertiser, AdvertiseCallback>? = null

    override fun state(): AdvertiserState {
        if (!app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return AdvertiserState.UNSUPPORTED
        val adapter = manager?.adapter ?: return AdvertiserState.UNSUPPORTED
        if (!adapter.isEnabled) return AdvertiserState.BLUETOOTH_OFF
        // The advertiser is null while Bluetooth is off, so it is only asked for once it is on.
        if (adapter.bluetoothLeAdvertiser == null || !adapter.isMultipleAdvertisementSupported) return AdvertiserState.UNSUPPORTED
        return AdvertiserState.READY
    }

    // The permission is checked just above the call; lint cannot follow the SDK-dependent check.
    @SuppressLint("MissingPermission")
    @Synchronized
    override fun start(serviceData: ByteArray, onFailure: (Int) -> Unit) {
        val advertiser = manager?.adapter?.bluetoothLeAdvertiser
        if (advertiser == null || !mayAdvertise()) {
            onFailure(AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED)
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(ParcelUuid.fromString(PairingCrypto.BLE_SERVICE_UUID), serviceData)
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) = onFailure(errorCode)
        }
        try {
            advertiser.startAdvertising(settings, data, callback)
            running = advertiser to callback
        } catch (e: SecurityException) {
            onFailure(AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR)
        } catch (e: IllegalStateException) {
            // Bluetooth went off between the state check and the start.
            onFailure(AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR)
        }
    }

    // The permission is checked just above the call; lint cannot follow the SDK-dependent check.
    @SuppressLint("MissingPermission")
    @Synchronized
    override fun stop() {
        val (advertiser, callback) = running ?: return
        running = null
        if (!mayAdvertise()) return
        try {
            advertiser.stopAdvertising(callback)
        } catch (e: SecurityException) {
            // The permission was withdrawn: the system stops the advertisement itself.
        } catch (e: IllegalStateException) {
            // Bluetooth is off: the advertisement has already ended.
        }
    }

    /** BLUETOOTH_ADVERTISE on API 31+; up to 30, BLUETOOTH_ADMIN is granted at install. */
    private fun mayAdvertise(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
}
