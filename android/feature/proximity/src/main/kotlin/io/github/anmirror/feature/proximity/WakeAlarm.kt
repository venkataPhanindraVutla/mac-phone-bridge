package io.github.anmirror.feature.proximity

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.os.PowerManager

/** One pending wall-clock wake-up; setting it again replaces it. */
interface WakeAlarm {
    fun set(atWallMs: Long)
    fun cancel()
}

/**
 * An inexact `RTC_WAKEUP` alarm (ruling R29): wall-clock time keeps running while the CPU sleeps,
 * unlike a coroutine delay. A window of 5 minutes normally; while the device is idle (Doze, which
 * defers windowed alarms) `setAndAllowWhileIdle`. No exact-alarm permission: the Mac accepts the
 * epoch before and after, so the rotation has about 15 minutes of slack. [operation] is a
 * broadcast to the app's receiver, which calls [ProximityBeacon.onClockCheck].
 */
class AndroidWakeAlarm(context: Context, private val operation: PendingIntent) : WakeAlarm {
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)

    override fun set(atWallMs: Long) {
        if (power?.isDeviceIdleMode == true) {
            alarms?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atWallMs, operation)
        } else {
            alarms?.setWindow(AlarmManager.RTC_WAKEUP, atWallMs, WINDOW_MS, operation)
        }
    }

    override fun cancel() {
        alarms?.cancel(operation)
    }

    private companion object {
        const val WINDOW_MS = 5 * 60_000L
    }
}
