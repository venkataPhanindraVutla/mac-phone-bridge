package io.github.anmirror.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.TAG
import kotlinx.coroutines.launch

/** Whether to bring the connection service up at boot (or after an app update). */
object BootDecision {
    /**
     * Boot, app update and app open all use this: start unless the store confirms no Mac. An
     * unreadable store starts the service. Whether it is already running is not an input.
     */
    fun shouldStart(confirmedEmpty: Boolean): Boolean = !confirmedEmpty

    /**
     * Stop the service on `NotPaired` only when the store confirms no Mac. An unreadable store
     * (Keystore busy or reset while locked) is not "no Mac".
     */
    fun shouldSelfStop(pairingUnderWay: Boolean, confirmedEmpty: Boolean): Boolean =
        !pairingUnderWay && confirmedEmpty
}

/**
 * Starts [ConnectionService] after a reboot or an app update, but only if a Mac is paired, so
 * the phone reconnects with no user action. Both broadcasts may start a `connectedDevice`
 * foreground service from the background.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val pending = goAsync()
        val graph = AppGraph.get(context)
        graph.scope.launch {
            try {
                val start = BootDecision.shouldStart(confirmedEmpty = graph.noMacPaired())
                Log.i(TAG, "boot: ${intent.action}, start=$start")
                if (start) {
                    ConnectionService.start(context.applicationContext)
                    KeepAliveWatchdog(context).schedule()
                }
            } catch (e: Exception) {
                Log.e(TAG, "boot: cannot start the service", e)
            } finally {
                pending.finish()
            }
        }
    }
}
