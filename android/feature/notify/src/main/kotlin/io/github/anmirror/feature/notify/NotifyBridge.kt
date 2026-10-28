package io.github.anmirror.feature.notify

import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.ActionResult
import io.github.anmirror.protocol.v1.ActiveNotifications
import io.github.anmirror.protocol.v1.AppIcon
import io.github.anmirror.protocol.v1.DismissNotification
import io.github.anmirror.protocol.v1.IconRequest
import io.github.anmirror.protocol.v1.InvokeAction
import io.github.anmirror.protocol.v1.NotificationFilter
import io.github.anmirror.protocol.v1.NotificationRemoved

/**
 * Sends the phone's notifications to the Mac and carries out the Mac's replies, button presses and
 * dismissals (SPEC 10). State is in memory for this process only; nothing is stored.
 */
class NotifyBridge(
    private val ownPackage: String,
    private val invoker: ActionInvoker,
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
) {
    private val lock = Any()

    // Before any notify.filter arrives this session: enabled, nothing muted.
    private var filter: NotificationFilter = DEFAULT_FILTER

    /** Keys sent to the Mac during this process, with the title and text last sent for each. */
    private val delivered = HashMap<String, String>()

    suspend fun onPosted(n: NotificationSnapshot) {
        val f = synchronized(lock) { filter }
        if (!NotificationMapper.eligible(n, ownPackage, f)) return
        sendPosted(n)
    }

    suspend fun onRemoved(key: String) {
        val known = synchronized(lock) { delivered.remove(key) != null }
        if (known) send(MessageType.NOTIFY_REMOVED, NotificationRemoved.newBuilder().setKey(key).build())
    }

    /** The Mac (re)connected: undelivered active ones first, then the list of every active key. */
    suspend fun onConnected() {
        val f = synchronized(lock) { filter }
        val active = invoker.active().filter { NotificationMapper.eligible(it, ownPackage, f) }
        for (n in active) {
            if (synchronized(lock) { n.key !in delivered }) sendPosted(n)
        }
        send(
            MessageType.NOTIFY_SNAPSHOT,
            ActiveNotifications.newBuilder().addAllKeys(active.map { it.key }).build(),
        )
    }

    /** The filter is per connection; until the Mac sends one again, everything is allowed. */
    fun onDisconnected() {
        synchronized(lock) { filter = DEFAULT_FILTER }
    }

    suspend fun onFilter(f: NotificationFilter) {
        synchronized(lock) { filter = f }
    }

    /** Every invoke gets a result (SPEC 10): the caller sends it with `reply_to` = [envelopeId]. */
    @Suppress("UNUSED_PARAMETER")
    suspend fun onInvoke(envelopeId: Long, a: InvokeAction): ActionResult {
        val outcome = when {
            invoker.active().none { it.key == a.key } -> ActionOutcome.ACTION_OUTCOME_GONE
            else -> try {
                invoker.invoke(a.key, a.actionIndex, a.replyText.takeIf { it.isNotEmpty() })
            } catch (e: Exception) {
                ActionOutcome.ACTION_OUTCOME_FAILED
            }
        }
        return ActionResult.newBuilder().setKey(a.key).setOutcome(outcome).build()
    }

    /** Removes the notification on the phone; the listener's removal callback tells the Mac. */
    fun onDismiss(d: DismissNotification) {
        val n = invoker.active().firstOrNull { it.key == d.key } ?: return
        if (n.clearable) invoker.dismiss(n.key)
    }

    suspend fun onIconRequest(r: IconRequest) {
        val png = invoker.icon(r.`package`)?.takeIf { it.size <= MAX_ICON_BYTES } ?: return
        send(
            MessageType.NOTIFY_ICON,
            AppIcon.newBuilder().setPackage(r.`package`).setPng(ByteString.copyFrom(png)).build(),
        )
    }

    private suspend fun sendPosted(n: NotificationSnapshot) {
        val content = n.title + "\u0000" + n.text
        val alert = synchronized(lock) {
            val last = delivered[n.key]
            !(last != null && (n.onlyAlertOnce || last == content))
        }
        val image = invoker.image(n.key)?.takeIf { it.size <= MAX_IMAGE_BYTES }
        if (send(MessageType.NOTIFY_POSTED, NotificationMapper.toProto(n, image, alert))) {
            synchronized(lock) { delivered[n.key] = content }
        }
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 300 * 1024
        const val MAX_ICON_BYTES = 32 * 1024
        val DEFAULT_FILTER: NotificationFilter = NotificationFilter.newBuilder().setEnabled(true).build()
    }
}
