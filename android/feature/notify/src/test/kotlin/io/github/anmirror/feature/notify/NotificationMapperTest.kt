package io.github.anmirror.feature.notify

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotificationMapperTest {
    private val own = "io.github.anmirror.phone"
    private fun eligible(n: NotificationSnapshot, f: io.github.anmirror.protocol.v1.NotificationFilter = filter()) =
        NotificationMapper.eligible(n, own, f)

    @Test
    fun excludesOngoingMediaFgsSummaryCallAndOwn() {
        assertTrue(eligible(snap()))
        assertFalse(eligible(snap(ongoing = true)))
        assertFalse(eligible(snap(mediaStyle = true)))
        assertFalse(eligible(snap(foregroundService = true)))
        assertFalse(eligible(snap(groupSummary = true)))
        assertFalse(eligible(snap(category = "call")))
        assertFalse(eligible(snap(pkg = own)))
        assertTrue(eligible(snap(category = "msg")))
    }

    @Test
    fun respectsFilterAndMuted() {
        assertFalse(eligible(snap(), filter(enabled = false)))
        assertFalse(eligible(snap(pkg = "com.noisy"), filter(true, "com.noisy")))
        assertTrue(eligible(snap(pkg = "com.chat"), filter(true, "com.noisy")))
    }

    @Test
    fun truncatesAtUtf8Boundary() {
        val cut = NotificationMapper.truncateUtf8("👋".repeat(1250), 4096) // 5,000 bytes
        assertTrue(cut.toByteArray().size <= 4096)
        assertTrue(cut.endsWith("…"))
        val body = cut.removeSuffix("…")
        assertEquals(body, String(body.toByteArray(Charsets.UTF_8), Charsets.UTF_8)) // no broken sequences
        assertTrue(body.all { it != '�' })
        assertEquals("short", NotificationMapper.truncateUtf8("short", 256))
    }

    @Test
    fun capsActionsKeepingReply() {
        val actions = (1..8).map { i ->
            if (i == 6) ActionSnapshot("Reply", true, "Message") else ActionSnapshot("a$i", false, null)
        }
        val proto = NotificationMapper.toProto(snap(actions = actions), null, true)
        assertEquals(listOf("Reply", "a1", "a2"), proto.actionsList.map { it.title })
        assertEquals(listOf(0, 1, 2), proto.actionsList.map { it.index })
        assertTrue(proto.actionsList[0].isReply)
        assertEquals("Message", proto.actionsList[0].replyHint)
        assertEquals(listOf(5, 0, 1), NotificationMapper.cappedOrder(actions))
    }

    @Test
    fun messagingStyleUsesLastMessage() {
        val msgs = listOf(MessageSnapshot("Bob", "first"), MessageSnapshot("Carol", "last"))
        assertEquals(MessagingContent("Group", "last", false), NotificationMapper.messagingContent("Group", msgs, "t"))
        assertEquals(MessagingContent("Carol", "last", false), NotificationMapper.messagingContent(null, msgs, "t"))
        assertEquals(MessagingContent("Carol", "last", false), NotificationMapper.messagingContent("", msgs, "t"))
        assertEquals(null, NotificationMapper.messagingContent("Group", emptyList(), "t"))
    }

    @Test
    fun ownReplyKeepsConversationTitle() {
        // A 1:1 chat after an inline reply: the newest message is the user's own.
        val chat = listOf(MessageSnapshot("Bob", "are you coming?"), MessageSnapshot(null, "on my way", fromUser = true))
        val c = NotificationMapper.messagingContent(null, chat, fallbackTitle = "Bob")!!
        assertEquals("Bob", c.title)
        assertEquals("on my way", c.text)
        assertTrue(c.lastFromUser)
        // A group keeps its own title.
        assertEquals("Family", NotificationMapper.messagingContent("Family", chat, "x")!!.title)
        // Only the user's own messages: the notification's title.
        val mine = listOf(MessageSnapshot("Me", "hello?", fromUser = true))
        assertEquals("Bob", NotificationMapper.messagingContent(null, mine, fallbackTitle = "Bob")!!.title)
        // The sender is the last one that is not the user, not the first.
        val two = listOf(MessageSnapshot("Ann", "a"), MessageSnapshot("Carol", "b"), MessageSnapshot(null, "c", fromUser = true))
        assertEquals("Carol", NotificationMapper.messagingContent(null, two, "x")!!.title)
    }

    @Test
    fun toProtoCarriesFieldsAndAlert() {
        val p = NotificationMapper.toProto(snap(clearable = false), byteArrayOf(1, 2), false)
        assertEquals("k1", p.key)
        assertEquals("com.chat", p.`package`)
        assertEquals("Chat", p.appName)
        assertEquals(2, p.imageJpeg.size())
        assertFalse(p.alert)
        assertFalse(p.clearable)
    }

    @Test
    fun capsLongActionTitlesHintsAndAppName() {
        val long = "x".repeat(1000)
        val n = snap(actions = listOf(ActionSnapshot(long, true, long))).copy(appName = long)
        val p = NotificationMapper.toProto(n, null, true)
        assertTrue(p.appName.toByteArray().size <= 256)
        assertTrue(p.actionsList[0].title.toByteArray().size <= 256)
        assertTrue(p.actionsList[0].replyHint.toByteArray().size <= 256)
    }
}
