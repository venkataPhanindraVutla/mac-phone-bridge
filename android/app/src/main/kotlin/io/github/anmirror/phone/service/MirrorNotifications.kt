package io.github.anmirror.phone.service

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MIRROR_TAG
import io.github.anmirror.phone.MainActivity
import io.github.anmirror.phone.R

/**
 * The ongoing "Your screen is shown on <Mac>" notification while a mirror session runs (low
 * importance, its own channel), with Stop. Posted when the session is RUNNING, removed at its end.
 */
object MirrorNotifications {
    private const val CHANNEL_ID = "mirroring"
    private const val TAG_MIRROR = "mirror"
    private const val NOTIFICATION_ID = 5

    fun post(context: Context, macName: String) {
        val app = context.applicationContext
        // Spelled out so lint sees the check.
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!allowed) return
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(app.getString(R.string.channel_mirroring))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(app).createNotificationChannel(channel)
        val stop = PendingIntent.getBroadcast(
            app,
            NOTIFICATION_ID,
            Intent(app, MirrorStopReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = PendingIntent.getActivity(
            app,
            NOTIFICATION_ID,
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(app.getString(R.string.mirror_notification_title, macName))
            .setContentIntent(open)
            .addAction(0, app.getString(R.string.mirror_notification_stop), stop)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        NotificationManagerCompat.from(app).notify(TAG_MIRROR, NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context.applicationContext).cancel(TAG_MIRROR, NOTIFICATION_ID)
    }
}

/** The mirroring notification's Stop: tells the Mac (`mirror.stop{USER}`) and ends the session. */
class MirrorStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(MIRROR_TAG, "notification: stop")
        AppGraph.get(context.applicationContext).mirrorController.stopFromPhone()
    }
}
