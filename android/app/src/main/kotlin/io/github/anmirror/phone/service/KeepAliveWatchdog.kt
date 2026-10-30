package io.github.anmirror.phone.service

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/** What a watchdog fire does. */
enum class WatchdogAction { CANCEL, START_SERVICE, KICK, NOTHING }

/** The watchdog's decision, kept free of Android so it can be tested. */
object WatchdogDecision {
    /** The same start decision as boot and app open: an unreadable store counts as paired. */
    fun pairedForWatchdog(confirmedEmpty: Boolean): Boolean = BootDecision.shouldStart(confirmedEmpty)

    fun decide(paired: Boolean, serviceRunning: Boolean, connected: Boolean): WatchdogAction = when {
        !paired -> WatchdogAction.CANCEL
        !serviceRunning -> WatchdogAction.START_SERVICE
        !connected -> WatchdogAction.KICK
        else -> WatchdogAction.NOTHING
    }
}

/**
 * An inexact wake-up every [INTERVAL_MS] that brings [ConnectionService] back when it is gone
 * while a Mac is paired ([KeepAliveWatchdogReceiver]). `setAndAllowWhileIdle` on the
 * `ELAPSED_REALTIME_WAKEUP` clock: it fires in Doze too, needs no exact-alarm permission, and
 * setting it again replaces the pending one. The receiver re-arms it on every fire.
 */
class KeepAliveWatchdog(context: Context) {
    private val app = context.applicationContext
    private val alarms = app.getSystemService(AlarmManager::class.java)
    private val operation = PendingIntent.getBroadcast(
        app, 0, Intent(app, KeepAliveWatchdogReceiver::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun schedule() {
        alarms?.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + INTERVAL_MS, operation)
    }

    fun cancel() {
        alarms?.cancel(operation)
    }

    private companion object {
        const val INTERVAL_MS = 15 * 60_000L
    }
}
