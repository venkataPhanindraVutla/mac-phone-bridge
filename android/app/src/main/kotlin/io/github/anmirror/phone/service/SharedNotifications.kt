package io.github.anmirror.phone.service

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.net.toUri
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.anmirror.feature.share.SharedNotifier
import io.github.anmirror.phone.R
import java.util.concurrent.atomic.AtomicInteger

/**
 * What the Mac shared, as notifications on channel `shared`: "Open link from <Mac>" opens the
 * link on a tap; "Copied from <Mac>" shows the start of the text. Each share gets its own
 * notification. Posts nothing while POST_NOTIFICATIONS is not granted. Never logs content.
 */
class SharedNotifications(context: Context) : SharedNotifier {
    private val app = context.applicationContext
    private val manager = NotificationManagerCompat.from(app)
    private val next = AtomicInteger(0)

    init {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_DEFAULT)
            .setName(app.getString(R.string.channel_shared))
            .setDescription(app.getString(R.string.channel_shared_description))
            .build()
        manager.createNotificationChannel(channel)
    }

    override fun linkFromMac(url: String, macName: String) {
        val id = next.incrementAndGet()
        val open = PendingIntent.getActivity(
            app,
            id,
            Intent(Intent.ACTION_VIEW, url.toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        post(id, builder().setContentTitle(app.getString(R.string.shared_link_from, macName)).setContentText(url).setContentIntent(open).build())
    }

    override fun textFromMac(preview: String, macName: String) {
        post(next.incrementAndGet(), builder().setContentTitle(app.getString(R.string.shared_text_from, macName)).setContentText(preview).build())
    }

    private fun builder() = NotificationCompat.Builder(app, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setAutoCancel(true)
        .setCategory(NotificationCompat.CATEGORY_MESSAGE)

    private fun post(id: Int, notification: Notification) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed) manager.notify(TAG_SHARED, id, notification)
    }

    private companion object {
        const val CHANNEL_ID = "shared"
        const val TAG_SHARED = "shared"
    }
}
