package io.github.anmirror.phone.platform

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import androidx.core.net.toUri

/** Android's battery-optimisation exemption for this app, and the Settings pages that change it. */
object Battery {
    fun isExempt(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) ?: false

    /**
     * The system's "Allow in the background?" dialog for this app. Opened only from the
     * keep-connected screen and the home row, never at launch.
     */
    @SuppressLint("BatteryLife") // F-Droid build; see the manifest's note on Google Play
    fun requestExemptionIntent(context: Context): Intent =
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, "package:${context.packageName}".toUri())

    /** App info for this app, where the makers' own battery settings usually start. */
    fun appSettingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri())

    /**
     * The exemption dialog; a build without it gets the battery-optimisation list, then App info.
     * False when none of them opens.
     */
    fun openExemption(context: Context): Boolean = startFirst(
        listOf(requestExemptionIntent(context), Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), appSettingsIntent(context)),
        context::startActivity,
    )

    /** App info for this app, else the Settings app. False when neither opens. */
    fun openAppSettings(context: Context): Boolean =
        startFirst(listOf(appSettingsIntent(context), Intent(Settings.ACTION_SETTINGS)), context::startActivity)
}

/**
 * Starts the first of [candidates] that opens. A Settings page can be missing (TV, Wear, custom
 * ROMs: ActivityNotFoundException) or not exported to other apps (some OEM builds:
 * SecurityException); either moves on to the next. False when none opened; never throws for those.
 */
fun <T> startFirst(candidates: List<T>, start: (T) -> Unit): Boolean {
    for (candidate in candidates) {
        try {
            start(candidate)
            return true
        } catch (_: ActivityNotFoundException) {
        } catch (_: SecurityException) {
        }
    }
    return false
}
