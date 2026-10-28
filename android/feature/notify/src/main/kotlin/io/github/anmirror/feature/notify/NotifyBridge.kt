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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Sends the phone's notifications to the Mac and carries out the Mac's replies, button presses and
 * dismissals (SPEC 10). State is in memory for this process only; nothing is stored. Every entry
 * point runs under one mutex, so events are handled strictly in the order they were called.
 */
class NotifyBridge(
    private val ownPackage: String,
    private val invoker: ActionInvoker,
    private val log: (String, Throwable) -> Unit = { _, _ -> },
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
) {
    private class Sent(val packageName: String, val content: String)

    private val mutex = Mutex()

    // Until the first notify.filter of this process: enabled, nothing muted. After that the last
    // filter received is kept, also across reconnects (controller ruling R7).
    private var filter: NotificationFilter = DEFAULT_FILTER

    /** Keys sent to the Mac during this process. */
    private val delivered = HashMap<String, Sent>()

    suspend fun onPosted(n: NotificationSnapshot) = mutex.withLock {
        if (NotificationMapper.eligible(n, ownPackage, filter)) sendPosted(n)
    }

    suspend fun onRemoved(key: String) = mutex.withLock {
        if (delivered.remove(key) != null) {
            send(MessageType.NOTIFY_REMOVED, NotificationRemoved.newBuilder().setKey(key).build())
        }
    }

    /** The Mac (re)connected: undelivered active ones first, then the list of every active key. */
    suspend fun onConnected() = mutex.withLock {
        val active = invoker.active().filter { NotificationMapper.eligible(it, ownPackage, filter) }
        for (n in active) {
            if (n.key in delivered) continue
            try {
                sendPosted(n)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("skipping notification that could not be sent", e)
            }
        }
        send(
            MessageType.NOTIFY_SNAPSHOT,
            ActiveNotifications.newBuilder().addAllKeys(active.map { it.key }).build(),
        )
        Unit
    }

    /** Nothing to reset: the filter and the delivered set live for the process. */
    fun onDisconnected() = Unit

    /** Stores the filter and retracts what it now excludes from the Mac. */
    suspend fun onFilter(f: NotificationFilter) = mutex.withLock {
        filter = f
        val muted = f.mutedPackagesList.toSet()
        val excluded = delivered.filterValues { !f.enabled || it.packageName in muted }.keys.toList()
        for (key in excluded) {
            delivered.remove(key)
            send(MessageType.NOTIFY_REMOVED, NotificationRemoved.newBuilder().setKey(key).build())
        }
    }

    /** Every invoke gets a result (SPEC 10): the caller sends it with `reply_to` = [envelopeId]. */
    @Suppress("UNUSED_PARAMETER")
    suspend fun onInvoke(envelopeId: Long, a: InvokeAction): ActionResult = mutex.withLock {
        val outcome = when {
            invoker.active().none { it.key == a.key } -> ActionOutcome.ACTION_OUTCOME_GONE
            else -> try {
                invoker.invoke(a.key, a.actionIndex, a.replyText.takeIf { it.isNotEmpty() })
            } catch (e: Exception) {
                ActionOutcome.ACTION_OUTCOME_FAILED
            }
        }
        ActionResult.newBuilder().setKey(a.key).setOutcome(outcome).build()
    }

    /** Removes the notification on the phone; the listener's removal callback tells the Mac. */
    suspend fun onDismiss(d: DismissNotification) = mutex.withLock {
        val n = invoker.active().firstOrNull { it.key == d.key }
        if (n != null && n.clearable) invoker.dismiss(n.key)
    }

    suspend fun onIconRequest(r: IconRequest) = mutex.withLock {
        val png = invoker.icon(r.`package`)?.takeIf { it.size <= MAX_ICON_BYTES }
        if (png != null) {
            send(
                MessageType.NOTIFY_ICON,
                AppIcon.newBuilder().setPackage(r.`package`).setPng(ByteString.copyFrom(png)).build(),
            )
        }
        Unit
    }

    private suspend fun sendPosted(n: NotificationSnapshot) {
        val content = n.title + "\u0000" + n.text
        val last = delivered[n.key]
        val alert = !(last != null && (n.onlyAlertOnce || last.content == content))
        val image = invoker.image(n.key)?.takeIf { it.size <= MAX_IMAGE_BYTES }
        if (send(MessageType.NOTIFY_POSTED, NotificationMapper.toProto(n, image, alert))) {
            delivered[n.key] = Sent(n.packageName, content)
        }
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 300 * 1024
        const val MAX_ICON_BYTES = 32 * 1024
        val DEFAULT_FILTER: NotificationFilter = NotificationFilter.newBuilder().setEnabled(true).build()
    }
}
