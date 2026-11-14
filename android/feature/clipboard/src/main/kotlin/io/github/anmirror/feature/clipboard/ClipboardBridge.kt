package io.github.anmirror.feature.clipboard

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ClipboardText
import java.security.MessageDigest

/** How an explicit "send the clipboard to the Mac" ended; each has its own toast. */
enum class ClipSendResult {
    SENT, EMPTY, TOO_LARGE, NOT_CONNECTED, ALREADY_ON_MAC,
    /** An image over [ClipboardBridge.MAX_IMAGE_BYTES]. */
    IMAGE_TOO_LARGE,
    /** An image, and the Mac does not share clipboard-image.v1 (an older Mac app). */
    IMAGE_NOT_SUPPORTED,
}

/**
 * Clipboard sync with the Mac (SPEC 14). The Mac's text is written to the clipboard. The bridge
 * remembers the SHA-256 of the text the Mac has now, whether it came from the Mac or was sent to
 * it, so that text is never sent to it again. Sending is always explicit (the tile, the
 * notification action, the share target). Gating (shared capability, the user's switch) is the
 * caller's: [send] returns false when the message did not go.
 *
 * Images (clipboard-image.v1, SPEC 14) follow the same rules by their SHA-256: an image from the
 * Mac lands through [ClipImageInbox]; the phone's goes on an explicit trigger through [sendImage],
 * the caller's transfer. [imagesShared] says whether the Mac takes them.
 *
 * Clipboard text and images are never logged, nor their size or hash.
 */
class ClipboardBridge(
    private val access: ClipboardAccess,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val maxBytes: Int = 262_144,
    private val sendImage: suspend (ClipImage) -> Boolean = { false },
    private val imagesShared: () -> Boolean = { false },
) {
    /** SHA-256 of the text the Mac has now, as far as this connection knows; null after a disconnect. */
    @Volatile private var macHas: ByteArray? = null

    /** The same for the Mac's image. */
    @Volatile private var macHasImage: ByteArray? = null

    /** `clipboard.text` from the Mac. */
    fun onMacText(t: ClipboardText) = acceptFromMac(t.text)

    /** Puts the Mac's text on the clipboard (also for `share.text`); remembered once written. */
    fun acceptFromMac(text: String) {
        access.write(text)
        macHas = sha256(text)
    }

    /** [text] went to the Mac another way (`share.text`, which the Mac puts on its clipboard): it has it now. */
    fun noteSentToMac(text: String) {
        macHas = sha256(text)
    }

    /** Sends [text] (the clipboard's, read by the caller) as `clipboard.text`. */
    suspend fun sendText(text: String?): ClipSendResult {
        if (text.isNullOrEmpty()) return ClipSendResult.EMPTY
        if (text.toByteArray(Charsets.UTF_8).size > maxBytes) return ClipSendResult.TOO_LARGE
        val digest = sha256(text)
        if (macHas?.contentEquals(digest) == true) return ClipSendResult.ALREADY_ON_MAC
        val message = ClipboardText.newBuilder().setText(text).build()
        if (!send(MessageType.CLIPBOARD_TEXT, message)) return ClipSendResult.NOT_CONNECTED
        macHas = digest
        return ClipSendResult.SENT
    }

    /** An image from the Mac, received whole into [file] with SHA-256 [sha256]: onto the clipboard. */
    fun acceptImageFromMac(file: java.io.File, sha256: ByteArray) {
        access.writeImage(file)
        macHasImage = sha256
    }

    /** Sends the clipboard's [image] (read by the caller, up to [MAX_IMAGE_BYTES] + 1 bytes). */
    suspend fun sendImage(image: ClipImage?): ClipSendResult {
        if (image == null || image.bytes.isEmpty()) return ClipSendResult.EMPTY
        if (!imagesShared()) return ClipSendResult.IMAGE_NOT_SUPPORTED
        if (image.bytes.size > MAX_IMAGE_BYTES) return ClipSendResult.IMAGE_TOO_LARGE
        val digest = MessageDigest.getInstance("SHA-256").digest(image.bytes)
        if (macHasImage?.contentEquals(digest) == true) return ClipSendResult.ALREADY_ON_MAC
        if (!sendImage.invoke(image)) return ClipSendResult.NOT_CONNECTED
        macHasImage = digest
        return ClipSendResult.SENT
    }

    /** The connection ended: the Mac's clipboard may change while apart, and the next Mac may be another one. */
    fun onDisconnected() {
        macHas = null
        macHasImage = null
    }

    companion object {
        /** The most a clipboard image may be (SPEC 14). */
        const val MAX_IMAGE_BYTES = 20_971_520
        const val IMAGE_CAPABILITY = "clipboard-image.v1"
    }

    private fun sha256(text: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
}
