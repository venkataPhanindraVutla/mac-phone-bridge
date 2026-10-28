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
        var lastFromUser = false
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)?.let { style ->
            val user = style.user
            val messages = style.messages.map { m ->
                val person = m.person
                // A message without a sender, or sent as the style's user, is the user's own.
                val fromUser = person == null ||
                    (person.key != null && person.key == user.key) ||
                    (person.name != null && person.name.toString() == user.name?.toString())
                MessageSnapshot(person?.name?.toString(), m.text?.toString().orEmpty(), fromUser)
            }
            NotificationMapper.messagingContent(style.conversationTitle?.toString(), messages, fallbackTitle = title)?.let {
                title = it.title
                text = it.text
                lastFromUser = it.lastFromUser
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
            lastFromUser = lastFromUser,
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
