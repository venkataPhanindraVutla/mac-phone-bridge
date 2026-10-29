package io.github.anmirror.feature.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context

/** The phone's clipboard, as plain text. */
interface ClipboardAccess {
    fun write(text: String)

    /**
     * The clipboard's text; null when it is empty or not readable. Android 10+ lets only the app
     * with input focus read it, so call this from a focused activity.
     */
    fun read(): String?
}

/** [ClipboardManager] over [context]. */
class AndroidClipboard(private val context: Context) : ClipboardAccess {
    private val manager = context.getSystemService(ClipboardManager::class.java)

    override fun write(text: String) {
        manager.setPrimaryClip(ClipData.newPlainText(LABEL, text))
    }

    override fun read(): String? {
        val clip = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(context)?.toString()
    }

    private companion object {
        const val LABEL = "Android Mirroring"
    }
}
