package io.github.anmirror.feature.share

import java.net.URI
import java.net.URISyntaxException

/** What a share to the Mac sends (SPEC 15, 16). */
sealed interface Outgoing {
    /** `share.link`: a lone http(s) URL with a host, at most [ShareClassifier.MAX_LINK_BYTES]. */
    data class Link(val url: String) : Outgoing

    /** `share.text`: any other non-blank text, as shared. */
    data class Text(val text: String) : Outgoing

    /** One or more `EXTRA_STREAM`s: file transfers. */
    data object Files : Outgoing

    /** Nothing that can be sent. */
    data object Nothing : Outgoing
}

/** Sorts what was shared into a link, text or files. Pure: no Android types. */
object ShareClassifier {
    /** SPEC 15: a `share.link` URL is at most 8,192 bytes of UTF-8. */
    const val MAX_LINK_BYTES = 8_192

    /** `share.text` (like `clipboard.text`) is at most 262,144 bytes of UTF-8; larger text is not sent. */
    const val MAX_TEXT_BYTES = 262_144

    /** Streams win; else a lone http(s) URL is a [Outgoing.Link]; else non-blank text is [Outgoing.Text]. */
    fun classify(text: String?, streamCount: Int): Outgoing = when {
        streamCount > 0 -> Outgoing.Files
        text.isNullOrBlank() -> Outgoing.Nothing
        else -> linkOrNull(text)?.let { Outgoing.Link(it) } ?: Outgoing.Text(text)
    }

    /** [text] trimmed when it is exactly one `http` or `https` URL with a host, within the cap; else null. */
    fun linkOrNull(text: String): String? {
        val url = text.trim()
        if (url.isEmpty() || url.any { it.isWhitespace() }) return null
        if (url.toByteArray(Charsets.UTF_8).size > MAX_LINK_BYTES) return null
        val uri = try {
            URI(url)
        } catch (e: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        if (uri.host.isNullOrEmpty()) return null
        return url
    }
}
