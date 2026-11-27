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
    val images = mutableListOf<java.io.File>()
    override fun writeImage(file: java.io.File) {
        images += file
    }
    override fun readImage(limit: Int): ClipImage? = null
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

    @Test fun sharedTextCountsAsMacHas() = runTest {
        val bridge = ClipboardBridge(clipboard, send)
        // The phone sent "S" as share.text; the Mac puts it on its clipboard (R6, outgoing side).
        bridge.noteSentToMac("S")
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendText("S"))
        assertTrue(sent.isEmpty())
        assertEquals(ClipSendResult.SENT, bridge.sendText("T"))
    }

    // ---- images (clipboard-image.v1) ----

    private val imagesSent = mutableListOf<ByteArray>()
    private var imagesShared = true

    private fun imageBridge() = ClipboardBridge(
        clipboard, send,
        sendImage = { if (connected) imagesSent += it.bytes; connected },
        imagesShared = { imagesShared },
    )

    private fun sha(b: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(b)

    @Test fun imageIsSentOnceAndNotWhenTheMacHasIt() = runTest {
        val bridge = imageBridge()
        val png = byteArrayOf(1, 2, 3)
        assertEquals(ClipSendResult.SENT, bridge.sendImage(ClipImage(png, "image/png")))
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendImage(ClipImage(png, "image/png")))
        val mac = byteArrayOf(9)
        bridge.acceptImageFromMac(java.io.File("x.png"), sha(mac))
        assertEquals(listOf(java.io.File("x.png")), clipboard.images)
        assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendImage(ClipImage(mac, "image/png")))
        assertEquals(1, imagesSent.size)
        // After a disconnect the Mac may have anything.
        bridge.onDisconnected()
        assertEquals(ClipSendResult.SENT, bridge.sendImage(ClipImage(mac, "image/png")))
    }

    @Test fun imageLimitsAndAnOlderMac() = runTest {
        val bridge = imageBridge()
        assertEquals(ClipSendResult.EMPTY, bridge.sendImage(null))
        assertEquals(
            ClipSendResult.IMAGE_TOO_LARGE,
            bridge.sendImage(ClipImage(ByteArray(ClipboardBridge.MAX_IMAGE_BYTES + 1), "image/png")),
        )
        assertEquals(
            ClipSendResult.SENT,
            bridge.sendImage(ClipImage(ByteArray(ClipboardBridge.MAX_IMAGE_BYTES), "image/png")),
        )
        imagesShared = false
        assertEquals(ClipSendResult.IMAGE_NOT_SUPPORTED, bridge.sendImage(ClipImage(byteArrayOf(5), "image/png")))
        imagesShared = true
        connected = false
        assertEquals(ClipSendResult.NOT_CONNECTED, bridge.sendImage(ClipImage(byteArrayOf(5), "image/png")))
    }

    @Test fun inboxKeepsTheNewestImageAndPutsItOnTheClipboard() = runTest {
        val dir = kotlin.io.path.createTempDirectory("clip").toFile()
        try {
            val bridge = imageBridge()
            val inbox = ClipImageInbox(dir, bridge)
            fun receive(id: String, bytes: ByteArray, name: String = "clipboard.png"): String {
                val offer = io.github.anmirror.protocol.v1.TransferOffer.newBuilder()
                    .setTransferId(id).setName(name).setSize(bytes.size.toLong()).build()
                val sink = (inbox.open(offer) as io.github.anmirror.transfer.SinkResult.Ready).file
                sink.output.write(bytes)
                return sink.commit()
            }
            val first = receive("a", byteArrayOf(1))
            val second = receive("b", byteArrayOf(2), name = "photo.JPG")
            assertTrue(second.endsWith(".jpg"))
            assertEquals(listOf(second), dir.list()!!.toList())
            assertEquals(listOf(first, second), clipboard.images.map { it.name })
            // The Mac's image is not sent back.
            assertEquals(ClipSendResult.ALREADY_ON_MAC, bridge.sendImage(ClipImage(byteArrayOf(2), "image/jpeg")))

            // An aborted one leaves nothing; an oversized one is refused.
            val offer = io.github.anmirror.protocol.v1.TransferOffer.newBuilder().setTransferId("c").setName("x.png").setSize(1).build()
            val sink = (inbox.open(offer) as io.github.anmirror.transfer.SinkResult.Ready).file
            sink.output.write(1)
            sink.abort()
            assertEquals(listOf(second), dir.list()!!.toList())
            val big = offer.toBuilder().setSize(ClipboardBridge.MAX_IMAGE_BYTES + 1L).build()
            assertEquals(
                io.github.anmirror.transfer.SinkResult.Refused(io.github.anmirror.protocol.v1.TransferError.TRANSFER_ERROR_DENIED),
                inbox.open(big),
            )
            assertEquals("png", inbox.extension("weird.name with space"))
        } finally {
            dir.deleteRecursively()
        }
    }
}
