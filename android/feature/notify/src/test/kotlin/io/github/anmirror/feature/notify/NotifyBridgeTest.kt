package io.github.anmirror.feature.notify

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.ActiveNotifications
import io.github.anmirror.protocol.v1.AppIcon
import io.github.anmirror.protocol.v1.DismissNotification
import io.github.anmirror.protocol.v1.IconRequest
import io.github.anmirror.protocol.v1.InvokeAction
import io.github.anmirror.protocol.v1.NotificationRemoved
import io.github.anmirror.protocol.v1.PhoneNotification
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private class FakeInvoker : ActionInvoker {
    val activeList = mutableListOf<NotificationSnapshot>()
    var invokeResult = ActionOutcome.ACTION_OUTCOME_OK
    val invoked = mutableListOf<Triple<String, Int, String?>>()
    val dismissed = mutableListOf<String>()
    var imageBytes: ByteArray? = null
    var iconBytes: ByteArray? = byteArrayOf(9, 9)
    var iconCalls = 0

    override fun invoke(key: String, actionIndex: Int, replyText: String?): ActionOutcome {
        invoked += Triple(key, actionIndex, replyText)
        return invokeResult
    }
    override fun dismiss(key: String) { dismissed += key }
    override fun active() = activeList.toList()
    override fun image(key: String) = imageBytes
    override fun icon(packageName: String): ByteArray? { iconCalls++; return iconBytes }
}

class NotifyBridgeTest {
    private val invoker = FakeInvoker()
    private val sent = mutableListOf<Pair<String, MessageLite>>()
    private val bridge = NotifyBridge("io.github.anmirror.phone", invoker) { t, p -> sent += t to p; true }

    private fun posted() = sent.filter { it.first == MessageType.NOTIFY_POSTED }.map { it.second as PhoneNotification }

    @Test
    fun postSendsNotifyPosted() = runTest {
        bridge.onPosted(snap(title = "Alice", text = "hi"))
        val p = posted().single()
        assertEquals("k1", p.key)
        assertEquals("hi", p.text)
        assertTrue(p.alert)
    }

    @Test
    fun repostWithSameContentDoesNotAlert() = runTest {
        bridge.onPosted(snap())
        bridge.onPosted(snap())
        assertEquals(listOf(true, false), posted().map { it.alert })
    }

    @Test
    fun repostWithNewTextAlerts() = runTest {
        bridge.onPosted(snap(text = "one"))
        bridge.onPosted(snap(text = "two"))
        assertEquals(listOf(true, true), posted().map { it.alert })
    }

    @Test
    fun onlyAlertOnceIsHonoured() = runTest {
        bridge.onPosted(snap(text = "one", onlyAlertOnce = true))
        bridge.onPosted(snap(text = "two", onlyAlertOnce = true))
        assertEquals(listOf(true, false), posted().map { it.alert })
    }

    @Test
    fun connectSendsUndeliveredThenSnapshot() = runTest {
        invoker.activeList += snap(key = "a")
        invoker.activeList += snap(key = "b")
        invoker.activeList += snap(key = "c", ongoing = true)
        bridge.onPosted(snap(key = "a"))
        sent.clear()
        bridge.onConnected()
        assertEquals(listOf("b"), posted().map { it.key })
        val last = sent.last()
        assertEquals(MessageType.NOTIFY_SNAPSHOT, last.first)
        assertEquals(listOf("a", "b"), (last.second as ActiveNotifications).keysList)
    }

    @Test
    fun mutedPackageIsNotSent() = runTest {
        bridge.onFilter(filter(true, "com.noisy"))
        bridge.onPosted(snap(pkg = "com.noisy"))
        assertTrue(sent.isEmpty())
        bridge.onFilter(filter(enabled = false))
        bridge.onPosted(snap())
        assertTrue(sent.isEmpty())
    }

    @Test
    fun invokeOnMissingKeyReturnsGone() = runTest {
        val r = bridge.onInvoke(7, InvokeAction.newBuilder().setKey("nope").build())
        assertEquals(ActionOutcome.ACTION_OUTCOME_GONE, r.outcome)
        assertEquals("nope", r.key)
        assertTrue(invoker.invoked.isEmpty())
    }

    @Test
    fun invokeOkPassesIndexAndReplyText() = runTest {
        invoker.activeList += snap(key = "a")
        val r = bridge.onInvoke(1, InvokeAction.newBuilder().setKey("a").setActionIndex(1).setReplyText("yo").build())
        assertEquals(ActionOutcome.ACTION_OUTCOME_OK, r.outcome)
        assertEquals(Triple("a", 1, "yo"), invoker.invoked.single())
    }

    @Test
    fun cancelledPendingIntentReturnsGone() = runTest {
        invoker.activeList += snap(key = "a")
        invoker.invokeResult = ActionOutcome.ACTION_OUTCOME_GONE // the Android adapter maps CanceledException to this
        val r = bridge.onInvoke(1, InvokeAction.newBuilder().setKey("a").build())
        assertEquals(ActionOutcome.ACTION_OUTCOME_GONE, r.outcome)
    }

    @Test
    fun throwingInvokerReturnsFailed() = runTest {
        val b = NotifyBridge("x", object : ActionInvoker by invoker {
            override fun invoke(key: String, actionIndex: Int, replyText: String?): ActionOutcome = error("boom")
        }) { t, p -> sent += t to p; true }
        invoker.activeList += snap(key = "a")
        assertEquals(ActionOutcome.ACTION_OUTCOME_FAILED, b.onInvoke(1, InvokeAction.newBuilder().setKey("a").build()).outcome)
    }

    @Test
    fun dismissIgnoresNonClearable() {
        invoker.activeList += snap(key = "a", clearable = false)
        invoker.activeList += snap(key = "b")
        bridge.onDismiss(DismissNotification.newBuilder().setKey("a").build())
        assertTrue(invoker.dismissed.isEmpty())
        bridge.onDismiss(DismissNotification.newBuilder().setKey("b").build())
        assertEquals(listOf("b"), invoker.dismissed)
    }

    @Test
    fun iconRequestSendsIconOnce() = runTest {
        bridge.onIconRequest(IconRequest.newBuilder().setPackage("com.chat").build())
        val icons = sent.filter { it.first == MessageType.NOTIFY_ICON }
        assertEquals(1, icons.size)
        val icon = icons.single().second as AppIcon
        assertEquals("com.chat", icon.`package`)
        assertEquals(2, icon.png.size())
    }

    @Test
    fun dropsOversizedImage() = runTest {
        invoker.imageBytes = ByteArray(400 * 1024)
        bridge.onPosted(snap())
        assertTrue(posted().single().imageJpeg.isEmpty)
        invoker.imageBytes = ByteArray(1024)
        bridge.onPosted(snap(key = "k2"))
        assertEquals(1024, posted().last().imageJpeg.size())
    }

    @Test
    fun removedIsSentOnlyForDeliveredKeys() = runTest {
        bridge.onPosted(snap(key = "a"))
        sent.clear()
        bridge.onRemoved("a")
        bridge.onRemoved("never")
        assertEquals(listOf("a"), sent.map { (it.second as NotificationRemoved).key })
    }
}
