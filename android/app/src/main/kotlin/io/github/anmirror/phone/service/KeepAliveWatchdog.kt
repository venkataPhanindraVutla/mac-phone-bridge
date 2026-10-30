package io.github.anmirror.phone.service

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import kotlinx.coroutines.CancellationException

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
 * One watchdog fire, kept free of Android so it can be tested: decide, act, record, re-arm.
 * - START_SERVICE that Android refuses (not exempt) posts "Tap to reconnect", unless the user
 *   dismissed it in this disconnected episode ([gate], ruling K6).
 * - CANCEL (no Mac paired) clears that notice and does not re-arm.
 * - A throw is recorded as `failed,<Class>`; the watchdog re-arms anyway, so it never ends by accident.
 * [record] gets the event-log detail of each `watchdog` line.
 */
class WatchdogFire(
    private val confirmedEmpty: suspend () -> Boolean,
    private val serviceRunning: () -> Boolean,
    private val connected: () -> Boolean,
    /** False when Android refused the start from the background. */
    private val startService: () -> Boolean,
    private val kick: () -> Unit,
    private val postNotice: () -> Unit,
    private val clearNotice: () -> Unit,
    private val gate: ReconnectNoticeGate,
    private val record: (String) -> Unit,
    private val schedule: () -> Unit,
) {
    /** What was decided, or null when it failed before deciding. */
    suspend fun run(): WatchdogAction? {
        var action: WatchdogAction? = null
        try {
            val paired = WatchdogDecision.pairedForWatchdog(confirmedEmpty = confirmedEmpty())
            val decided = WatchdogDecision.decide(paired, serviceRunning(), connected())
            action = decided
            record(decided.name)
            when (decided) {
                WatchdogAction.START_SERVICE -> if (!startService()) {
                    if (gate.mayPost()) {
                        record("start-refused")
                        postNotice()
                    } else {
                        record("start-refused,notice-suppressed")
                    }
                }
                WatchdogAction.KICK -> kick()
                WatchdogAction.CANCEL -> clearNotice()
                WatchdogAction.NOTHING -> Unit
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            record("failed,${e.javaClass.simpleName.ifEmpty { "Unknown" }}")
        } finally {
            if (action != WatchdogAction.CANCEL) {
                runCatching(schedule).onFailure { record("schedule-failed,${it.javaClass.simpleName.ifEmpty { "Unknown" }}") }
            }
        }
        return action
    }
}

/**
 * Whether "Tap to reconnect" may be posted (ruling K6): once the user dismisses it, not again
 * until the phone has connected. Re-posting one that is still showing only updates it (silent).
 * [Flag] persists across processes (the watchdog often runs in a fresh one).
 */
class ReconnectNoticeGate(private val dismissed: Flag) {
    interface Flag {
        fun get(): Boolean
        fun set(value: Boolean)
    }

    fun mayPost(): Boolean = !dismissed.get()

    /** The notice's deleteIntent: swiped away or cleared. */
    fun onDismissed() = dismissed.set(true)

    /** A session reached Connected: the next disconnected episode may post again. */
    fun onConnected() {
        if (dismissed.get()) dismissed.set(false)
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
