package io.github.anmirror.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.diag.KeepAliveEvent
import kotlinx.coroutines.launch

/**
 * The [KeepAliveWatchdog] alarm: starts the service if it is gone while a Mac is paired, kicks
 * the manager if it is running but not connected, and sets the next alarm unless no Mac is
 * paired. When Android refuses the start from the background (the app is not exempt from
 * battery optimisation), it posts [ReconnectNotice] instead. The work is [WatchdogFire]. Only
 * this app's PendingIntent reaches it.
 */
class KeepAliveWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val app = context.applicationContext
        val graph = AppGraph.get(app)
        graph.scope.launch {
            try {
                val decided = WatchdogFire(
                    confirmedEmpty = graph::noMacPaired,
                    serviceRunning = { ServiceProbe.connectionServiceRunning(app) },
                    connected = { graph.manager.state.value is PhoneConnectionState.Connected },
                    startService = { ConnectionService.start(app) },
                    kick = graph.manager::kick,
                    postNotice = { ReconnectNotice.post(app) },
                    clearNotice = { ReconnectNotice.clear(app) },
                    gate = ReconnectNotice.gate(app),
                    record = { graph.keepAliveLog.record(KeepAliveEvent.WATCHDOG, it) },
                    schedule = { KeepAliveWatchdog(app).schedule() },
                ).run()
                Log.i(TAG, "watchdog: ${decided ?: "failed"}")
            } finally {
                pending.finish()
            }
        }
    }
}
