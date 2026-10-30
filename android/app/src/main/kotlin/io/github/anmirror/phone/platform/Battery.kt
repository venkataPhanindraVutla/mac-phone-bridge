package io.github.anmirror.phone.platform

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import androidx.core.net.toUri

/** Android's battery-optimisation exemption for this app, and the two Settings pages that change it. */
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
}
