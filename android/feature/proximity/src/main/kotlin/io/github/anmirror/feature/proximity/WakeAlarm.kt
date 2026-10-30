package io.github.anmirror.feature.proximity

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.os.PowerManager

/** One pending wall-clock wake-up; setting it again replaces it. */
interface WakeAlarm {
    fun set(wake: Wake)
    fun cancel()
}

/**
 * Inexact `RTC_WAKEUP` alarms (ruling R29): wall-clock time keeps running while the CPU sleeps,
 * unlike a coroutine delay. No exact-alarm permission.
 *
 * - [WakeKind.ROTATION]: `setWindow` with a 10-minute window, the platform's minimum from API 31
 *   (a shorter one is raised to it). The rotation 1 s past the boundary then lands by boundary +
 *   601 s at the latest, inside the 899 s the Mac's epoch ±1 allows. While the device is idle
 *   (Doze defers windowed alarms) it is `setAndAllowWhileIdle` instead.
 * - [WakeKind.PROMPT] (a retry, a deadline for new data): `setAndAllowWhileIdle`, whose heuristic
 *   window is a fraction of the delay, so seconds for a target seconds away.
 *
 * [operation] is a broadcast to the app's receiver, which calls [ProximityBeacon.onClockCheck].
 */
class AndroidWakeAlarm(context: Context, private val operation: PendingIntent) : WakeAlarm {
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)

    override fun set(wake: Wake) {
        if (wake.kind == WakeKind.PROMPT || power?.isDeviceIdleMode == true) {
            alarms?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, wake.atMs, operation)
        } else {
            alarms?.setWindow(AlarmManager.RTC_WAKEUP, wake.atMs, WINDOW_MS, operation)
        }
    }

    override fun cancel() {
        alarms?.cancel(operation)
    }

    private companion object {
        /** AlarmManager's minimum window from API 31. */
        const val WINDOW_MS = 10 * 60_000L
    }
}
