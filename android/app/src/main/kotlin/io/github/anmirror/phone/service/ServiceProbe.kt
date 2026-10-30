package io.github.anmirror.phone.service

import android.app.ActivityManager
import android.content.Context

/** What the system thinks, as opposed to [ConnectionService.running], which a killed service leaves stale. */
object ServiceProbe {
    @Suppress("DEPRECATION") // still returns the caller's own services
    fun connectionServiceRunning(context: Context): Boolean = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        am.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == ConnectionService::class.java.name && it.foreground
        }
    } catch (_: Exception) {
        false
    }
}
