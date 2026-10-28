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
import java.security.MessageDigest

/**
 * Sends the phone's notifications to the Mac and carries out the Mac's replies, button presses and
 * dismissals (SPEC 10). State is in memory for this process only; nothing is stored, and what is
 * remembered of a sent notification is a hash, never its content. Every entry point runs under
 * one mutex, so events are handled strictly in the order they were called.
 */
class NotifyBridge(
    private val ownPackage: String,
    private val invoker: ActionInvoker,
    private val log: (String, Throwable?) -> Unit = { _, _ -> },
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
) {
    /** What the Mac last got for a key: hashes of title+text (alerting) and of everything it shows (re-sending). */
    private data class Sent(val packageName: String, val textHash: String, val contentHash: String)

    private val mutex = Mutex()

    // Until the first notify.filter of this process: enabled, nothing muted. After that the last
    // filter received is kept, also across reconnects (controller ruling R7).
    private var filter: NotificationFilter = DEFAULT_FILTER

    /** The Mac [delivered] belongs to: the last one that connected. */
    private var mac: String? = null

    /** Keys sent to [mac] during this process. */
    private val delivered = HashMap<String, Sent>()

    suspend fun onPosted(n: NotificationSnapshot) = mutex.withLock {
        if (NotificationMapper.eligible(n, ownPackage, filter)) sendPosted(n)
    }

    suspend fun onRemoved(key: String) = mutex.withLock {
        if (delivered.remove(key) != null) {
            send(MessageType.NOTIFY_REMOVED, NotificationRemoved.newBuilder().setKey(key).build())
        }
    }

    /**
     * The Mac [macId] (re)connected: every active one it never got, or got in an older version,
     * first (silently), then the list of every active key. A different Mac starts from nothing.
     * When the active list cannot be read nothing is sent: an empty snapshot would wipe the Mac.
     */
    suspend fun onConnected(macId: String) = mutex.withLock {
        if (mac != null && mac != macId) delivered.clear()
        mac = macId
        val all = invoker.active()
        if (all == null) {
            log("active notifications could not be read; snapshot skipped", null)
            return@withLock
        }
        val active = all.filter { NotificationMapper.eligible(it, ownPackage, filter) }
        for (n in active) {
            if (delivered[n.key]?.contentHash == contentHash(n)) continue
            try {
                sendPosted(n, catchUp = true)
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

    /** Nothing to reset: the filter and the delivered set live for the process (the set per Mac). */
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
        val active = invoker.active()
        val outcome = when {
            // Unreadable is not gone: GONE would make the Mac drop a notification that may still be there.
            active == null -> ActionOutcome.ACTION_OUTCOME_FAILED
            active.none { it.key == a.key } -> ActionOutcome.ACTION_OUTCOME_GONE
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
        val n = invoker.active()?.firstOrNull { it.key == d.key }
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

    /**
     * Alerts only for new text, never for a catch-up, an "only alert once" update or the user's
     * own reply.
     */
    private suspend fun sendPosted(n: NotificationSnapshot, catchUp: Boolean = false) {
        val textHash = hash(n.title, n.text)
        val last = delivered[n.key]
        val alert = !catchUp && !n.lastFromUser && !(last != null && (n.onlyAlertOnce || last.textHash == textHash))
        val image = invoker.image(n.key)?.takeIf { it.size <= MAX_IMAGE_BYTES }
        if (send(MessageType.NOTIFY_POSTED, NotificationMapper.toProto(n, image, alert))) {
            delivered[n.key] = Sent(n.packageName, textHash, contentHash(n))
        }
    }

    /** What is remembered of each sent key, for tests: never the notification's content. */
    internal fun deliveredRecords(): Map<String, String> = delivered.mapValues { it.value.toString() }

    private fun contentHash(n: NotificationSnapshot): String =
        hash(n.title, n.text, *n.actions.flatMap { listOf(it.title, it.isReply.toString(), it.replyHint.orEmpty()) }.toTypedArray())

    /** SHA-256 over the parts, each length-prefixed so that ("ab", "c") and ("a", "bc") differ. */
    private fun hash(vararg parts: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        for (p in parts) {
            val bytes = p.toByteArray(Charsets.UTF_8)
            digest.update("${bytes.size}:".toByteArray(Charsets.UTF_8))
            digest.update(bytes)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 300 * 1024
        const val MAX_ICON_BYTES = 32 * 1024
        val DEFAULT_FILTER: NotificationFilter = NotificationFilter.newBuilder().setEnabled(true).build()
    }
}
