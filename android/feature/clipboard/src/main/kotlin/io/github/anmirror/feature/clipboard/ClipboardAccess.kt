package io.github.anmirror.feature.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle

/** The phone's clipboard, as plain text. */
interface ClipboardAccess {
    fun write(text: String)

    /**
     * The clipboard's text; null when it is empty or not readable. Android 10+ lets only the app
     * with input focus read it, so call this from a focused activity.
     */
    fun read(): String?
}

/** [ClipboardManager] over [context]. What it writes is always the Mac's text. */
class AndroidClipboard(private val context: Context) : ClipboardAccess {
    private val manager = context.getSystemService(ClipboardManager::class.java)

    override fun write(text: String) {
        val clip = ClipData.newPlainText(LABEL, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // From another device (API 34+): Android then skips its "copied" overlay on every Mac copy.
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_REMOTE_DEVICE, true)
            }
        }
        manager.setPrimaryClip(clip)
    }

    /** One read, on the main thread on purpose: it must happen while the calling activity has focus. */
    override fun read(): String? {
        val clip = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(context)?.toString()
    }

    private companion object {
        const val LABEL = "Android Mirroring"
    }
}
