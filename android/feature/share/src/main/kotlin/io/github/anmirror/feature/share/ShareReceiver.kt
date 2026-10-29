package io.github.anmirror.feature.share

import io.github.anmirror.feature.clipboard.ClipboardBridge
import io.github.anmirror.protocol.v1.SharedLink
import io.github.anmirror.protocol.v1.SharedText

/** Shows what the Mac shared. Implementations must not log the URL or the text. */
interface SharedNotifier {
    /** "Open link from <Mac>"; a tap opens [url]. */
    fun linkFromMac(url: String, macName: String)

    /** "Copied from <Mac>", with [preview] as its text. */
    fun textFromMac(preview: String, macName: String)
}

/**
 * The phone's side of `share.*` from the Mac (SPEC 15). A link is offered as a notification (it
 * is opened only on a tap); text goes on the clipboard through [clipboard], which remembers it so
 * that it is not sent back (R6). Gating (share.v1 shared) is the caller's.
 */
class ShareReceiver(
    private val clipboard: ClipboardBridge,
    private val notifier: SharedNotifier,
    private val macName: () -> String,
) {
    /** A valid link is offered; anything else is treated as text, as SPEC 15 says the sender should have. */
    fun onLink(l: SharedLink) {
        val url = ShareClassifier.linkOrNull(l.url)
        if (url == null) {
            onText(SharedText.newBuilder().setText(l.url).build())
            return
        }
        notifier.linkFromMac(url, macName())
    }

    fun onText(t: SharedText) {
        if (t.text.isEmpty()) return
        clipboard.acceptFromMac(t.text)
        notifier.textFromMac(preview(t.text), macName())
    }

    private fun preview(text: String): String {
        if (text.length <= PREVIEW_CHARS) return text
        // Never end on the first half of a surrogate pair.
        val end = if (Character.isHighSurrogate(text[PREVIEW_CHARS - 1])) PREVIEW_CHARS - 1 else PREVIEW_CHARS
        return text.substring(0, end)
    }

    private companion object {
        const val PREVIEW_CHARS = 120
    }
}
