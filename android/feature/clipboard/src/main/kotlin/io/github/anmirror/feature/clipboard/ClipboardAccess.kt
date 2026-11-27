package io.github.anmirror.feature.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

/** An image read from the clipboard: its bytes (at most the limit asked for plus one) and type. */
class ClipImage(val bytes: ByteArray, val mime: String)

/** The phone's clipboard: plain text, and images (clipboard-image.v1). */
interface ClipboardAccess {
    fun write(text: String)

    /** Puts the image in [file] (in the app's cache, under `clip-in/`) on the clipboard. */
    fun writeImage(file: File)

    /**
     * The clipboard's image, read up to [limit] + 1 bytes (so a larger one shows as too large);
     * null when it holds text or no readable image. Needs input focus, like [read].
     */
    fun readImage(limit: Int): ClipImage?

    /**
     * The clipboard's text; null when it is empty or not readable. Android 10+ lets only the app
     * with input focus read it, so call this from a focused activity.
     */
    fun read(): String?
}

/** [ClipboardManager] over [context]. What it writes is always the Mac's text or image. */
class AndroidClipboard(private val context: Context) : ClipboardAccess {
    private val manager = context.getSystemService(ClipboardManager::class.java)

    override fun write(text: String) {
        manager.setPrimaryClip(remote(ClipData.newPlainText(LABEL, text)))
    }

    override fun writeImage(file: File) {
        val uri = FileProvider.getUriForFile(context, context.packageName + AUTHORITY_SUFFIX, file)
        // The provider grants the pasting app read access through the clipboard.
        manager.setPrimaryClip(remote(ClipData.newUri(context.contentResolver, LABEL, uri)))
    }

    /** One read, on the main thread on purpose: it must happen while the calling activity has focus. */
    override fun read(): String? {
        val clip = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(context)?.toString()
    }

    override fun readImage(limit: Int): ClipImage? = try {
        imageOf(manager.primaryClip, limit)
    } catch (e: Exception) {
        null // a provider that refuses or vanished: no image
    }

    private fun imageOf(clip: ClipData?, limit: Int): ClipImage? {
        if (clip == null || clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        if (!item.text.isNullOrEmpty()) return null // text wins
        val uri = item.uri ?: return null
        val description = clip.description
        val mime = context.contentResolver.getType(uri)?.takeIf { it.startsWith("image/") }
            ?: (0 until description.mimeTypeCount).map(description::getMimeType).firstOrNull { it.startsWith("image/") }
            ?: return null
        val bytes = context.contentResolver.openInputStream(uri)?.use { readUpTo(it, limit + 1) } ?: return null
        return ClipImage(bytes, mime)
    }

    private fun remote(clip: ClipData): ClipData {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // From another device (API 34+): Android then skips its "copied" overlay on every Mac copy.
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_REMOTE_DEVICE, true)
            }
        }
        return clip
    }

    private companion object {
        const val LABEL = "Mac Phone Bridge"
        /** The FileProvider in the app's manifest: `${applicationId}.clipboard`. */
        const val AUTHORITY_SUFFIX = ".clipboard"
    }
}

/** At most [max] bytes of [input]. */
internal fun readUpTo(input: InputStream, max: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buf = ByteArray(64 * 1024)
    while (out.size() < max) {
        val n = input.read(buf, 0, minOf(buf.size, max - out.size()))
        if (n < 0) break
        out.write(buf, 0, n)
    }
    return out.toByteArray()
}
