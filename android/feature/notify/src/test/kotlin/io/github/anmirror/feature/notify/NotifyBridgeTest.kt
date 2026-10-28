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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private class FakeInvoker : ActionInvoker {
    val activeList = mutableListOf<NotificationSnapshot>()
    /** The listener could not read its active notifications. */
    var activeFails = false
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
    override fun active(): List<NotificationSnapshot>? = if (activeFails) null else activeList.toList()
    override fun image(key: String) = imageBytes
    override fun icon(packageName: String): ByteArray? { iconCalls++; return iconBytes }
}

class NotifyBridgeTest {
    private val invoker = FakeInvoker()
    private val sent = mutableListOf<Pair<String, MessageLite>>()
    private val logged = mutableListOf<String>()

    /** False while the Mac can't hear: sends fail. */
    private var reachable = true
    private val bridge = NotifyBridge("io.github.anmirror.phone", invoker, { m, _ -> logged += m }) { t, p ->
        if (reachable) sent += t to p
        reachable
    }

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
        bridge.onConnected("mac1")
        assertEquals(listOf("b"), posted().map { it.key })
        val last = sent.last()
        assertEquals(MessageType.NOTIFY_SNAPSHOT, last.first)
        assertEquals(listOf("a", "b"), (last.second as ActiveNotifications).keysList)
    }

    @Test
    fun changedWhileDisconnectedIsResentOnReconnect() = runTest {
        invoker.activeList += snap(key = "a", text = "one")
        invoker.activeList += snap(key = "b", text = "same")
        bridge.onConnected("mac1")
        // The Mac can't hear while "a" changes on the phone.
        reachable = false
        invoker.activeList[0] = snap(key = "a", text = "two")
        bridge.onPosted(invoker.activeList[0])
        reachable = true
        sent.clear()
        bridge.onConnected("mac1")
        val p = posted().single()
        assertEquals("a", p.key)
        assertEquals("two", p.text)
        assertFalse(p.alert) // a catch-up does not ding
        assertEquals(MessageType.NOTIFY_SNAPSHOT, sent.last().first)
    }

    @Test
    fun changedActionsAreResentOnReconnect() = runTest {
        invoker.activeList += snap(key = "a")
        bridge.onConnected("mac1")
        invoker.activeList[0] = snap(key = "a", actions = listOf(ActionSnapshot("Reply", true, null)))
        sent.clear()
        bridge.onConnected("mac1")
        assertEquals(listOf("Reply"), posted().single().actionsList.map { it.title })
    }

    @Test
    fun secondMacGetsActiveNotifications() = runTest {
        invoker.activeList += snap(key = "a")
        bridge.onConnected("macA")
        assertEquals(listOf("a"), posted().map { it.key })
        sent.clear()
        bridge.onConnected("macB")
        val p = posted().single()
        assertEquals("a", p.key)
        assertFalse(p.alert)
        sent.clear()
        bridge.onConnected("macB") // the same Mac again: it has everything
        assertTrue(posted().isEmpty())
    }

    @Test
    fun deliveredHoldsNoContent() = runTest {
        bridge.onPosted(snap(key = "a", title = "Alice Smith", text = "the secret plan"))
        val stored = bridge.deliveredRecords()
        assertEquals(setOf("a"), stored.keys)
        val value = stored.getValue("a")
        assertFalse(value.contains("the secret plan"))
        assertFalse(value.contains("Alice Smith"))
    }

    @Test
    fun ownReplyDoesNotAlert() = runTest {
        bridge.onPosted(snap(key = "a", text = "hey"))
        bridge.onPosted(snap(key = "a", text = "on my way", lastFromUser = true))
        bridge.onPosted(snap(key = "b", text = "first and mine", lastFromUser = true))
        assertEquals(listOf(true, false, false), posted().map { it.alert })
    }

    @Test
    fun failedActiveReadSkipsSnapshot() = runTest {
        bridge.onPosted(snap(key = "a"))
        sent.clear()
        invoker.activeFails = true
        bridge.onConnected("mac1")
        assertTrue(sent.isEmpty()) // an empty snapshot would wipe the Mac's list
        assertEquals(1, logged.size)
    }

    @Test
    fun invokeWhenActiveUnreadableFails() = runTest {
        invoker.activeFails = true
        val r = bridge.onInvoke(1, InvokeAction.newBuilder().setKey("a").build())
        assertEquals(ActionOutcome.ACTION_OUTCOME_FAILED, r.outcome) // not GONE: the Mac would drop it
        assertTrue(invoker.invoked.isEmpty())
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
    fun dismissIgnoresNonClearable() = runTest {
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
    fun filterSurvivesReconnect() = runTest {
        bridge.onFilter(filter(true, "com.noisy"))
        bridge.onDisconnected()
        bridge.onPosted(snap(pkg = "com.noisy"))
        assertTrue(sent.isEmpty())
    }

    @Test
    fun newlyMutedPackageIsRetracted() = runTest {
        bridge.onPosted(snap(key = "a", pkg = "com.noisy"))
        bridge.onPosted(snap(key = "b", pkg = "com.chat"))
        sent.clear()
        bridge.onFilter(filter(true, "com.noisy"))
        assertEquals(listOf("a"), sent.map { (it.second as NotificationRemoved).key })
        sent.clear()
        bridge.onFilter(filter(enabled = false))
        assertEquals(listOf("b"), sent.map { (it.second as NotificationRemoved).key })
    }

    @Test
    fun removalQueuedBehindInFlightPostStillRemoves() = runTest {
        val gate = CompletableDeferred<Unit>()
        var first = true
        val b = NotifyBridge("x", invoker) { t, p ->
            if (first) { first = false; gate.await() }
            sent += t to p
            true
        }
        launch { b.onPosted(snap(key = "a")) }
        launch { b.onRemoved("a") }
        advanceUntilIdle()
        assertTrue(sent.isEmpty())
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf(MessageType.NOTIFY_POSTED, MessageType.NOTIFY_REMOVED), sent.map { it.first })
    }

    @Test
    fun postsToSameKeyAreSentInArrivalOrder() = runTest {
        val gate = CompletableDeferred<Unit>()
        var first = true
        val b = NotifyBridge("x", invoker) { t, p ->
            if (first) { first = false; gate.await() }
            sent += t to p
            true
        }
        launch { b.onPosted(snap(text = "one")) }
        launch { b.onPosted(snap(text = "two")) }
        advanceUntilIdle()
        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("one", "two"), posted().map { it.text })
        assertEquals(listOf(true, true), posted().map { it.alert })
    }

    @Test
    fun failingSendForOneKeyStillSendsSnapshot() = runTest {
        invoker.activeList += snap(key = "bad")
        invoker.activeList += snap(key = "good")
        val logged = mutableListOf<String>()
        val b = NotifyBridge("x", invoker, { m, _ -> logged += m }) { t, p ->
            if (t == MessageType.NOTIFY_POSTED && (p as PhoneNotification).key == "bad") error("too big")
            sent += t to p
            true
        }
        b.onConnected("mac1")
        assertEquals(listOf("good"), posted().map { it.key })
        assertEquals(MessageType.NOTIFY_SNAPSHOT, sent.last().first)
        assertEquals(1, logged.size)
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
