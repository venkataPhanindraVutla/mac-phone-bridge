package io.github.anmirror.feature.clipboard

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ClipboardText
import java.security.MessageDigest

/** How an explicit "send the clipboard to the Mac" ended; each has its own toast. */
enum class ClipSendResult { SENT, EMPTY, TOO_LARGE, NOT_CONNECTED, ALREADY_ON_MAC }

/**
 * Clipboard sync with the Mac (SPEC 14). The Mac's text is written to the clipboard and
 * remembered by its SHA-256, so the phone never sends it back. Sending is always explicit (the
 * tile, the notification action, the share target). Gating (shared capability, the user's switch)
 * is the caller's: [send] returns false when the message did not go.
 *
 * Clipboard text is never logged, nor its size or hash.
 */
class ClipboardBridge(
    private val access: ClipboardAccess,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val maxBytes: Int = 262_144,
) {
    @Volatile private var lastReceived: ByteArray? = null

    /** `clipboard.text` from the Mac. */
    fun onMacText(t: ClipboardText) = acceptFromMac(t.text)

    /** Puts the Mac's text on the clipboard (also for `share.text`) and remembers it. */
    fun acceptFromMac(text: String) {
        lastReceived = sha256(text)
        access.write(text)
    }

    /** Sends [text] (the clipboard's, read by the caller) as `clipboard.text`. */
    suspend fun sendText(text: String?): ClipSendResult {
        if (text.isNullOrEmpty()) return ClipSendResult.EMPTY
        if (text.toByteArray(Charsets.UTF_8).size > maxBytes) return ClipSendResult.TOO_LARGE
        if (lastReceived?.contentEquals(sha256(text)) == true) return ClipSendResult.ALREADY_ON_MAC
        val message = ClipboardText.newBuilder().setText(text).build()
        return if (send(MessageType.CLIPBOARD_TEXT, message)) ClipSendResult.SENT else ClipSendResult.NOT_CONNECTED
    }

    private fun sha256(text: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
}
