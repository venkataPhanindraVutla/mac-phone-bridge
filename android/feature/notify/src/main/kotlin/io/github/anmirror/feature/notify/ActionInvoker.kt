package io.github.anmirror.feature.notify

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.StatusBarNotification
import io.github.anmirror.protocol.v1.ActionOutcome

/** The phone's notifications, as the bridge needs them. The Android implementation is [AndroidActionInvoker]. */
interface ActionInvoker {
    /** [actionIndex] indexes the capped list sent to the Mac ([NotificationMapper.cappedOrder]). */
    fun invoke(key: String, actionIndex: Int, replyText: String?): ActionOutcome
    fun dismiss(key: String)
    fun active(): List<NotificationSnapshot>

    /** Already scaled by [ImageScaler], or null. */
    fun image(key: String): ByteArray?

    /** 96x96 PNG, or null. */
    fun icon(packageName: String): ByteArray?
}

/**
 * The real thing: [active] reads the listener's current notifications and [cancel] is
 * `NotificationListenerService.cancelNotification`. Both are only valid while the listener is connected.
 */
class AndroidActionInvoker(
    context: Context,
    private val reader: AndroidNotificationReader,
    private val activeNotifications: () -> Array<StatusBarNotification>?,
    private val cancel: (String) -> Unit,
) : ActionInvoker {
    private val app = context.applicationContext

    private fun sbn(key: String) = activeNotifications()?.firstOrNull { it.key == key }

    override fun invoke(key: String, actionIndex: Int, replyText: String?): ActionOutcome {
        val sbn = sbn(key) ?: return ActionOutcome.ACTION_OUTCOME_GONE
        val actions = sbn.notification.actions.orEmpty()
        val order = NotificationMapper.cappedOrder(actions.map { reader.actionSnapshot(it) })
        val action = order.getOrNull(actionIndex)?.let { actions[it] } ?: return ActionOutcome.ACTION_OUTCOME_FAILED
        val intent = action.actionIntent ?: return ActionOutcome.ACTION_OUTCOME_FAILED
        return try {
            val fill = Intent()
            val remote = action.remoteInputs?.firstOrNull { it.allowFreeFormInput }
            if (remote != null && replyText != null) {
                RemoteInput.addResultsToIntent(arrayOf(remote), fill, Bundle().apply { putCharSequence(remote.resultKey, replyText) })
            } else if (remote != null) {
                return ActionOutcome.ACTION_OUTCOME_FAILED // a reply without text
            }
            intent.send(app, 0, fill)
            ActionOutcome.ACTION_OUTCOME_OK
        } catch (e: PendingIntent.CanceledException) {
            ActionOutcome.ACTION_OUTCOME_GONE
        } catch (e: Exception) {
            ActionOutcome.ACTION_OUTCOME_FAILED
        }
    }

    override fun dismiss(key: String) = cancel(key)

    override fun active(): List<NotificationSnapshot> =
        activeNotifications().orEmpty().map { reader.snapshot(it) }

    override fun image(key: String): ByteArray? = sbn(key)?.let { reader.image(it) }

    override fun icon(packageName: String): ByteArray? = reader.icon(packageName)
}
