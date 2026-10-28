package io.github.anmirror.feature.notify

import com.google.protobuf.ByteString
import io.github.anmirror.protocol.v1.NotificationAction
import io.github.anmirror.protocol.v1.NotificationFilter
import io.github.anmirror.protocol.v1.PhoneNotification

/** One message of a `MessagingStyle` notification. */
data class MessageSnapshot(val sender: String?, val text: String)

/** Pure rules: which notifications go to the Mac and how they look on the wire (SPEC 10). */
object NotificationMapper {
    const val MAX_ACTIONS = 3
    const val MAX_TITLE_BYTES = 256
    const val MAX_TEXT_BYTES = 4096
    const val MAX_SUB_TEXT_BYTES = 256
    const val MAX_LABEL_BYTES = 256 // action title, reply hint, app name
    private const val ELLIPSIS = "…"

    fun eligible(n: NotificationSnapshot, ownPackage: String, filter: NotificationFilter): Boolean =
        filter.enabled &&
            n.packageName != ownPackage &&
            n.packageName !in filter.mutedPackagesList &&
            !n.ongoing && !n.groupSummary && !n.foregroundService && !n.mediaStyle &&
            n.category != "call"

    /**
     * Indices into [actions] in the order sent to the Mac: the reply action first, then the rest in
     * their own order, at most [MAX_ACTIONS]. `InvokeAction.action_index` indexes this list.
     */
    fun cappedOrder(actions: List<ActionSnapshot>): List<Int> {
        val reply = actions.indexOfFirst { it.isReply }
        val order = if (reply < 0) actions.indices.toList() else listOf(reply) + actions.indices.filter { it != reply }
        return order.take(MAX_ACTIONS)
    }

    fun toProto(n: NotificationSnapshot, imageJpeg: ByteArray?, alert: Boolean): PhoneNotification {
        val b = PhoneNotification.newBuilder()
            .setKey(n.key)
            .setPackage(n.packageName)
            .setAppName(truncateUtf8(n.appName, MAX_LABEL_BYTES))
            .setTitle(truncateUtf8(n.title, MAX_TITLE_BYTES))
            .setText(truncateUtf8(n.text, MAX_TEXT_BYTES))
            .setSubText(truncateUtf8(n.subText, MAX_SUB_TEXT_BYTES))
            .setPostedAtMs(n.postedAtMs)
            .setAlert(alert)
            .setClearable(n.clearable)
        cappedOrder(n.actions).forEachIndexed { i, original ->
            val a = n.actions[original]
            b.addActions(
                NotificationAction.newBuilder()
                    .setIndex(i)
                    .setTitle(truncateUtf8(a.title, MAX_LABEL_BYTES))
                    .setIsReply(a.isReply)
                    .setReplyHint(truncateUtf8(a.replyHint.orEmpty(), MAX_LABEL_BYTES)),
            )
        }
        if (imageJpeg != null) b.setImageJpeg(ByteString.copyFrom(imageJpeg))
        return b.build()
    }

    /** Cuts [s] to at most [maxBytes] UTF-8 bytes at a character boundary, ending with "…" when cut. */
    fun truncateUtf8(s: String, maxBytes: Int): String {
        if (s.toByteArray(Charsets.UTF_8).size <= maxBytes) return s
        val budget = maxBytes - ELLIPSIS.toByteArray(Charsets.UTF_8).size
        var bytes = 0
        var end = 0
        while (end < s.length) {
            val cp = s.codePointAt(end)
            val size = when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            if (bytes + size > budget) break
            bytes += size
            end += Character.charCount(cp)
        }
        return s.substring(0, end) + ELLIPSIS
    }

    /**
     * Title and text of a `MessagingStyle` notification: the conversation title, else the last
     * message's sender; and the last message. Null when there are no messages.
     */
    fun messagingContent(conversationTitle: String?, messages: List<MessageSnapshot>): Pair<String, String>? {
        val last = messages.lastOrNull() ?: return null
        val title = conversationTitle?.takeIf { it.isNotBlank() } ?: last.sender.orEmpty()
        return title to last.text
    }
}
