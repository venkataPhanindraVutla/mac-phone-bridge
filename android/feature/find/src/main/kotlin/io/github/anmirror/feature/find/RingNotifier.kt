package io.github.anmirror.feature.find

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** The "your Mac is ringing this phone" notification. */
interface RingNotifier {
    fun show()
    fun cancel()
}

/**
 * High-importance notification with a Stop action; tapping the notification stops too. Both use
 * [stopIntent]. No full-screen intent (USE_FULL_SCREEN_INTENT is restricted).
 */
class AndroidRingNotifier(
    context: Context,
    private val stopIntent: PendingIntent,
) : RingNotifier {
    private val app = context.applicationContext

    override fun show() {
        val nm = NotificationManagerCompat.from(app)
        nm.createNotificationChannel(
            NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
                .setName(app.getString(R.string.channel_find))
                .setDescription(app.getString(R.string.channel_find_description))
                .setSound(null, null) // the alarm plays through AlarmAudio, not the channel
                .setVibrationEnabled(false)
                .build(),
        )
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!allowed) return // the ring goes on without a notification
        val n = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(app.getString(R.string.find_ringing_title))
            .setContentText(app.getString(R.string.find_ringing_text))
            .setContentIntent(stopIntent)
            .addAction(0, app.getString(R.string.find_stop), stopIntent)
            .setOngoing(true)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        @Suppress("MissingPermission") // checked above
        nm.notify(NOTIFICATION_ID, n)
    }

    override fun cancel() {
        NotificationManagerCompat.from(app).cancel(NOTIFICATION_ID)
    }

    companion object {
        const val CHANNEL_ID = "find"
        private const val NOTIFICATION_ID = 2
    }
}
