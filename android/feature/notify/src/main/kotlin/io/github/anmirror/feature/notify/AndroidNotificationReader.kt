package io.github.anmirror.feature.notify

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.os.Build
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.toBitmap
import androidx.core.os.BundleCompat
import kotlin.coroutines.cancellation.CancellationException
import java.io.ByteArrayOutputStream

/** `StatusBarNotification` to [NotificationSnapshot], plus picture and app-icon extraction. */
class AndroidNotificationReader(context: Context) {
    private val app = context.applicationContext

    fun snapshot(sbn: StatusBarNotification): NotificationSnapshot {
        val n = sbn.notification
        val extras = n.extras
        var title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        var text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty()
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)?.let { style ->
            val messages = style.messages.map { MessageSnapshot(it.person?.name?.toString(), it.text?.toString().orEmpty()) }
            NotificationMapper.messagingContent(style.conversationTitle?.toString(), messages)?.let {
                title = it.first
                text = it.second
            }
        }
        val template = extras.getString(Notification.EXTRA_TEMPLATE).orEmpty()
        return NotificationSnapshot(
            key = sbn.key,
            packageName = sbn.packageName,
            appName = appName(sbn.packageName),
            title = title,
            text = text,
            subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty(),
            postedAtMs = sbn.postTime,
            actions = n.actions.orEmpty().map { actionSnapshot(it) },
            ongoing = n.flags and Notification.FLAG_ONGOING_EVENT != 0,
            groupSummary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            foregroundService = n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0,
            mediaStyle = template.contains("MediaStyle"),
            category = n.category,
            onlyAlertOnce = n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0,
            clearable = sbn.isClearable,
        )
    }

    /** The big picture (`EXTRA_PICTURE` or `EXTRA_PICTURE_ICON`), scaled, or null. */
    fun image(sbn: StatusBarNotification): ByteArray? = nullOnFailure {
        val extras = sbn.notification.extras
        val bitmap: Bitmap? = BundleCompat.getParcelable(extras, Notification.EXTRA_PICTURE, Bitmap::class.java)
            ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                BundleCompat.getParcelable(extras, Notification.EXTRA_PICTURE_ICON, Icon::class.java)
                    ?.loadDrawable(app)?.toBitmap()
            } else {
                null
            }
        bitmap?.let { ImageScaler.toJpeg(it) }
    }

    /** The app's launcher icon as a 96x96 PNG, or null. */
    fun icon(packageName: String): ByteArray? = nullOnFailure {
        val bitmap = app.packageManager.getApplicationIcon(packageName).toBitmap(ICON_PX, ICON_PX)
        ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /** Extraction can throw (including OutOfMemoryError); a bad picture must not cost the notification. */
    private inline fun nullOnFailure(block: () -> ByteArray?): ByteArray? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        null
    }

    private fun appName(packageName: String): String = try {
        val pm = app.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: Exception) {
        packageName
    }

    fun actionSnapshot(a: Notification.Action): ActionSnapshot {
        val reply = a.remoteInputs?.firstOrNull { it.allowFreeFormInput }
        return ActionSnapshot(a.title?.toString().orEmpty(), reply != null, reply?.label?.toString())
    }

    private companion object {
        const val ICON_PX = 96
    }
}
