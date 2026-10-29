package io.github.anmirror.feature.share

import com.google.protobuf.MessageLite
import io.github.anmirror.feature.clipboard.ClipSendResult
import io.github.anmirror.feature.clipboard.ClipboardAccess
import io.github.anmirror.feature.clipboard.ClipboardBridge
import io.github.anmirror.protocol.v1.SharedLink
import io.github.anmirror.protocol.v1.SharedText
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private class FakeClipboard : ClipboardAccess {
    val writes = mutableListOf<String>()
    override fun write(text: String) {
        writes += text
    }
    override fun read(): String? = writes.lastOrNull()
}

private class FakeNotifier : SharedNotifier {
    val links = mutableListOf<Pair<String, String>>()
    val texts = mutableListOf<Pair<String, String>>()
    override fun linkFromMac(url: String, macName: String) {
        links += url to macName
    }
    override fun textFromMac(preview: String, macName: String) {
        texts += preview to macName
    }
}

private fun link(url: String) = SharedLink.newBuilder().setUrl(url).build()
private fun text(text: String) = SharedText.newBuilder().setText(text).build()

class ShareReceiverTest {
    private val clipboard = FakeClipboard()
    private val sent = mutableListOf<MessageLite>()
    private val bridge = ClipboardBridge(clipboard, { _, m -> sent += m; true })
    private val notifier = FakeNotifier()
    private val receiver = ShareReceiver(bridge, notifier) { "Studio Mac" }

    @Test fun linkNotifiesWithMacName() {
        receiver.onLink(link("https://example.com/page"))
        assertEquals(listOf("https://example.com/page" to "Studio Mac"), notifier.links)
        // A link is opened on a tap, never put on the clipboard.
        assertTrue(clipboard.writes.isEmpty())
        assertTrue(notifier.texts.isEmpty())
    }

    @Test fun invalidLinkFallsBackToText() {
        receiver.onLink(link("javascript:alert(1)"))
        assertTrue(notifier.links.isEmpty())
        assertEquals(listOf("javascript:alert(1)"), clipboard.writes)
        assertEquals(listOf("javascript:alert(1)" to "Studio Mac"), notifier.texts)
    }

    @Test fun textGoesToClipboardAndNotifies() {
        receiver.onText(text("hello from the Mac"))
        assertEquals(listOf("hello from the Mac"), clipboard.writes)
        assertEquals(listOf("hello from the Mac" to "Studio Mac"), notifier.texts)

        // The preview is cut to 120 characters, never inside a surrogate pair; the clipboard gets it all.
        val long = "a".repeat(119) + "😀" + "b".repeat(200)
        receiver.onText(text(long))
        assertEquals(long, clipboard.writes.last())
        assertEquals("a".repeat(119), notifier.texts.last().first)
        val plain = "c".repeat(300)
        receiver.onText(text(plain))
        assertEquals("c".repeat(120), notifier.texts.last().first)
    }

    @Test fun textIsRememberedSoItIsNotSentBack() = runTest {
        receiver.onText(text("shared from the Mac"))
        // R6: the bridge now knows the Mac has this text, so an explicit send of it does not go back.
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendText(clipboard.read()))
        assertTrue(sent.isEmpty())
    }
}
