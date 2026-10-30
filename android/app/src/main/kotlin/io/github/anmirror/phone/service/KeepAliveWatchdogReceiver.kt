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
 * battery optimisation), it posts [ReconnectNotice] instead. Only this app's PendingIntent
 * reaches it.
 */
class KeepAliveWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val app = context.applicationContext
        val graph = AppGraph.get(app)
        graph.scope.launch {
            var action: WatchdogAction? = null
            try {
                val paired = WatchdogDecision.pairedForWatchdog(confirmedEmpty = graph.noMacPaired())
                val running = ServiceProbe.connectionServiceRunning(app)
                val connected = graph.manager.state.value is PhoneConnectionState.Connected
                val decided = WatchdogDecision.decide(paired, running, connected)
                action = decided
                graph.keepAliveLog.record(KeepAliveEvent.WATCHDOG, decided.name)
                Log.i(TAG, "watchdog: $decided")
                when (decided) {
                    WatchdogAction.START_SERVICE -> if (!ConnectionService.start(app)) {
                        graph.keepAliveLog.record(KeepAliveEvent.WATCHDOG, "start-refused")
                        ReconnectNotice.post(app)
                    }
                    WatchdogAction.KICK -> graph.manager.kick()
                    WatchdogAction.CANCEL, WatchdogAction.NOTHING -> Unit
                }
            } catch (e: Exception) {
                Log.e(TAG, "watchdog: failed (${e.javaClass.simpleName})")
            } finally {
                // A failure before the decision re-arms too: the watchdog never ends by accident.
                try {
                    if (action != WatchdogAction.CANCEL) KeepAliveWatchdog(app).schedule()
                } finally {
                    pending.finish()
                }
            }
        }
    }
}
