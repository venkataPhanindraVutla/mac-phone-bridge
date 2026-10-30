package io.github.anmirror.phone.service

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.anmirror.phone.MainActivity
import io.github.anmirror.phone.R

/**
 * "Android Mirroring stopped / Tap to reconnect": posted by the watchdog when Android refuses to
 * start the service from the background. Tapping opens the app, whose resume starts the
 * service; the service clears this notice when it is created. Silent, on the `connection`
 * channel. Tagged so its id cannot clash with the transfer notifications' ids.
 */
object ReconnectNotice {
    private const val TAG_RECONNECT = "reconnect"
    private const val NOTIFICATION_ID = 3

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
        val notification = NotificationCompat.Builder(app, ConnectionService.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(app.getString(R.string.reconnect_title))
            .setContentText(app.getString(R.string.reconnect_text))
            .setContentIntent(open)
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
