package io.github.anmirror.feature.clipboard

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ClipboardText
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private class FakeClipboard : ClipboardAccess {
    val writes = mutableListOf<String>()
    var current: String? = null
    var fails = false
    override fun write(text: String) {
        if (fails) throw SecurityException("refused")
        writes += text
        current = text
    }
    override fun read(): String? = current
}

private fun macText(text: String) = ClipboardText.newBuilder().setText(text).build()

class ClipboardBridgeTest {
    private val clipboard = FakeClipboard()
    private val sent = mutableListOf<String>()
    private var connected = true
    private val send: suspend (String, MessageLite) -> Boolean = { type, m ->
        assertEquals(MessageType.CLIPBOARD_TEXT, type)
        if (connected) sent += (m as ClipboardText).text
        connected
    }

    @Test fun macTextIsWritten() {
        ClipboardBridge(clipboard, send).onMacText(macText("from the Mac"))
        assertEquals(listOf("from the Mac"), clipboard.writes)
    }

    @Test fun macTextIsNotSentBack() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        bridge.onMacText(macText("from the Mac"))
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendText(clipboard.read()))
        assertTrue(sent.isEmpty())
        // Shared text (Task 6) counts the same.
        bridge.acceptFromMac("shared")
        assertEquals(listOf("from the Mac", "shared"), clipboard.writes)
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendText("shared"))
        assertTrue(sent.isEmpty())
        // Other text goes.
        assertEquals(ClipSendResult.SENT, bridge.sendText("mine"))
        assertEquals(listOf("mine"), sent)
    }

    @Test fun emptyIsEmpty() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        assertEquals(ClipSendResult.EMPTY, bridge.sendText(null))
        assertEquals(ClipSendResult.EMPTY, bridge.sendText(""))
        assertTrue(sent.isEmpty())
    }

    @Test fun oversizedIsTooLarge() = runTest {
        val bridge = ClipboardBridge(clipboard, send, maxBytes = 8)
        // Four two-byte characters fit; one more ASCII byte does not.
        assertEquals(ClipSendResult.TOO_LARGE, bridge.sendText("éééé!"))
        assertTrue(sent.isEmpty())
        assertEquals(ClipSendResult.SENT, bridge.sendText("éééé"))
        // The default cap is 262,144 bytes.
        val default = ClipboardBridge(clipboard, send)
        assertEquals(ClipSendResult.TOO_LARGE, default.sendText("a".repeat(262_145)))
        assertEquals(ClipSendResult.SENT, default.sendText("a".repeat(262_144)))
    }

    @Test fun notConnectedWhenSendFails() = runTest {
        connected = false
        assertEquals(ClipSendResult.NOT_CONNECTED, ClipboardBridge(clipboard, send).sendText("hello"))
        assertTrue(sent.isEmpty())
    }

    @Test fun resendAfterSentIsNotRefused() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        bridge.onMacText(macText("X"))
        assertEquals(ClipSendResult.SENT, bridge.sendText("Y"))
        // The Mac has Y now, so X goes again; Y does not.
        assertEquals(ClipSendResult.SENT, bridge.sendText("X"))
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendText("X"))
        assertEquals(listOf("Y", "X"), sent)
    }

    @Test fun disconnectForgetsWhatTheMacHas() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        bridge.onMacText(macText("X"))
        bridge.onDisconnected()
        assertEquals(ClipSendResult.SENT, bridge.sendText("X"))
    }

    @Test fun failedWriteIsNotRemembered() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        clipboard.fails = true
        assertFailsWith<SecurityException> { bridge.onMacText(macText("X")) }
        assertEquals(ClipSendResult.SENT, bridge.sendText("X"))
    }

    @Test fun failedSendIsNotRemembered() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        connected = false
        assertEquals(ClipSendResult.NOT_CONNECTED, bridge.sendText("X"))
        connected = true
        assertEquals(ClipSendResult.SENT, bridge.sendText("X"))
    }

    @Test fun switchOffClearsDigest() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        bridge.onMacText(macText("X"))
        // Switched off: the app clears the digest (Mac text is dropped meanwhile, so it would go stale).
        bridge.onDisconnected()
        // Switched on again: the phone's X goes, even though the Mac once sent X.
        assertEquals(ClipSendResult.SENT, bridge.sendText("X"))
        assertEquals(listOf("X"), sent)
    }
}
