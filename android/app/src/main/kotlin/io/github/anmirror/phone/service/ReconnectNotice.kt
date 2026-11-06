package io.github.anmirror.phone.service

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MainActivity
import io.github.anmirror.phone.R
import io.github.anmirror.phone.diag.KeepAliveEvent

/**
 * "Mac Phone Bridge stopped / Tap to reconnect": posted by the watchdog when Android refuses to
 * start the service from the background. Tapping opens the app, whose resume starts the
 * service; the service clears this notice when it is created. Silent, on the `connection`
 * channel. Tagged so its id cannot clash with the transfer notifications' ids.
 *
 * Dismissing it (its deleteIntent, [ReconnectNoticeDismissReceiver]) stops the watchdog from
 * posting it again until the phone has connected ([gate], ruling K6).
 */
object ReconnectNotice {
    private const val TAG_RECONNECT = "reconnect"
    private const val NOTIFICATION_ID = 3
    private const val PREFS = "keepalive"
    private const val KEY_DISMISSED = "reconnect_dismissed"

    /** The dismissed flag, kept in shared preferences so a fresh process sees it. */
    fun gate(context: Context): ReconnectNoticeGate {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return ReconnectNoticeGate(
            object : ReconnectNoticeGate.Flag {
                override fun get(): Boolean = prefs.getBoolean(KEY_DISMISSED, false)
                override fun set(value: Boolean) = prefs.edit { putBoolean(KEY_DISMISSED, value) }
            },
        )
    }

    fun post(context: Context) {
        val app = context.applicationContext
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!allowed) return
        ConnectionService.createChannel(app)
        val open = PendingIntent.getActivity(
            app,
            NOTIFICATION_ID,
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val dismissed = PendingIntent.getBroadcast(
            app,
            NOTIFICATION_ID,
            Intent(app, ReconnectNoticeDismissReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(app, ConnectionService.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(app.getString(R.string.reconnect_title))
            .setContentText(app.getString(R.string.reconnect_text))
            .setContentIntent(open)
            .setDeleteIntent(dismissed)
            .setAutoCancel(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        NotificationManagerCompat.from(app).notify(TAG_RECONNECT, NOTIFICATION_ID, notification)
    }

    fun clear(context: Context) {
        NotificationManagerCompat.from(context.applicationContext).cancel(TAG_RECONNECT, NOTIFICATION_ID)
    }
}

/** The user swiped "Tap to reconnect" away: do not post it again until the phone has connected. */
class ReconnectNoticeDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReconnectNotice.gate(context).onDismissed()
        AppGraph.get(context.applicationContext).keepAliveLog.record(KeepAliveEvent.WATCHDOG, "notice-dismissed")
    }
}
