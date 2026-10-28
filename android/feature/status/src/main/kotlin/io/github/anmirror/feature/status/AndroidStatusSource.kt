package io.github.anmirror.feature.status

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Looper
import android.telephony.PhoneStateListener
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.github.anmirror.protocol.v1.NetworkKind
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Live phone status from system callbacks; registered while collected. No permission beyond
 * ACCESS_NETWORK_STATE: signal strength needs no READ_PHONE_STATE. On API 29-30 the signal
 * listener binds to the collecting thread, so collect on a Looper thread (the main thread).
 */
fun AndroidStatusSource(context: Context): Flow<PhoneStatus> = StatusSources(context.applicationContext).flow()

private class StatusSources(private val app: Context) {
    fun flow(): Flow<PhoneStatus> =
        combine(battery(), signal(), network()) { (percent, charging), level, kind ->
            PhoneStatus(percent, charging, level, kind)
        }.distinctUntilChanged()

    private fun battery(): Flow<Pair<Int, Boolean>> = callbackFlow {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                trySend(parseBattery(intent))
            }
        }
        // Sticky: registering returns the current state at once.
        val sticky = ContextCompat.registerReceiver(
            app, receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        sticky?.let { trySend(parseBattery(it)) }
        awaitClose { app.unregisterReceiver(receiver) }
    }

    private fun parseBattery(intent: Intent): Pair<Int, Boolean> {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val percent = if (level >= 0 && scale > 0) (level * 100 / scale).coerceIn(0, 100) else 0
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return percent to charging
    }

    private fun view(s: SignalStrength) = SignalStrengthView(
        level = s.level,
        cells = s.cellSignalStrengths.map {
            CellView(valid = it.dbm != Int.MAX_VALUE) // CellSignalStrength.isValid is not public API
        },
    )

    private fun signal(): Flow<Int> = callbackFlow {
        val tm = app.getSystemService(TelephonyManager::class.java)
        if (tm == null) {
            trySend(-1)
            awaitClose { }
            return@callbackFlow
        }
        fun airplane() = Settings.Global.getInt(app.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0
        fun simReady() = tm.simState == TelephonyManager.SIM_STATE_READY
        fun level(s: SignalStrength?): Int = signalLevel(simReady(), airplane(), s?.let(::view))

        // Known without a callback: no SIM / airplane. Otherwise the first callback supplies the
        // value (sending -1 for "not known yet" would flash "No service" at connect).
        val initial = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) tm.signalStrength else null
        var sent = false
        if (initial != null || !simReady() || airplane()) {
            trySend(level(initial))
            sent = true
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && Looper.myLooper() == null) {
            if (!sent) trySend(-1) // API 29-30 listeners need a Looper thread: no callback will come
            awaitClose { }
            return@callbackFlow
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val callback = object : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener {
                override fun onSignalStrengthsChanged(signalStrength: SignalStrength) {
                    trySend(level(signalStrength))
                }
            }
            tm.registerTelephonyCallback(ContextCompat.getMainExecutor(app), callback)
            awaitClose { tm.unregisterTelephonyCallback(callback) }
        } else {
            @Suppress("DEPRECATION")
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onSignalStrengthsChanged(signalStrength: SignalStrength?) {
                    trySend(level(signalStrength))
                }
            }
            @Suppress("DEPRECATION")
            tm.listen(listener, PhoneStateListener.LISTEN_SIGNAL_STRENGTHS)
            @Suppress("DEPRECATION")
            awaitClose { tm.listen(listener, PhoneStateListener.LISTEN_NONE) }
        }
    }

    private fun network(): Flow<NetworkKind> = callbackFlow {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        if (cm == null) {
            trySend(NetworkKind.NETWORK_KIND_NONE)
            awaitClose { }
            return@callbackFlow
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                trySend(kindOf(caps))
            }

            override fun onLost(network: Network) {
                trySend(NetworkKind.NETWORK_KIND_NONE)
            }
        }
        trySend(
            cm.getNetworkCapabilities(cm.activeNetwork)?.let(::kindOf) ?: NetworkKind.NETWORK_KIND_NONE,
        )
        cm.registerDefaultNetworkCallback(callback)
        awaitClose { cm.unregisterNetworkCallback(callback) }
    }

    private fun kindOf(caps: NetworkCapabilities): NetworkKind = when {
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkKind.NETWORK_KIND_WIFI
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkKind.NETWORK_KIND_CELLULAR
        else -> NetworkKind.NETWORK_KIND_OTHER
    }
}
