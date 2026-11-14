package io.github.anmirror.phone.share

import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import io.github.anmirror.feature.clipboard.AndroidClipboard
import io.github.anmirror.feature.clipboard.ClipboardBridge
import io.github.anmirror.feature.clipboard.ClipSendResult
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.ClipboardGate
import io.github.anmirror.phone.R
import io.github.anmirror.phone.TAG
import kotlinx.coroutines.launch

/**
 * Sends the phone's clipboard to the Mac: started by the Quick Settings tile and the persistent
 * notification's "Send clipboard" action (the share target sends its text itself). An image, when
 * the clipboard holds one and no text, goes as a clipboard image (SPEC 14). It has no UI (a translucent
 * theme). Android 10+ lets only the focused app read the clipboard, so it reads once its window
 * has focus, shows the outcome as a toast and finishes. While sharing is off or no Mac is
 * connected it says so without reading the clipboard at all.
 */
class ClipboardSendActivity : ComponentActivity() {
    private var started = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || started) return
        started = true
        val graph = AppGraph.get(this)
        when (graph.clipboardGateNow()) {
            ClipboardGate.OPEN -> Unit
            ClipboardGate.OFF -> return done(getString(R.string.clipboard_off))
            ClipboardGate.NOT_CONNECTED -> return done(getString(R.string.clipboard_not_connected))
        }
        val access = AndroidClipboard(this)
        // An image (clipboard-image.v1) when the clipboard holds no text; read now, while focused.
        val image = access.readImage(ClipboardBridge.MAX_IMAGE_BYTES)
        val text = if (image == null) access.read() else null
        // Taken before sending: a sent text names the Mac it went to.
        val macName = graph.connectedMacName() ?: graph.store.macs.value?.maxByOrNull { it.lastConnectedAt }?.name
        lifecycleScope.launch {
            val result = if (image != null) graph.clipboard.sendImage(image) else graph.clipboard.sendText(text)
            Log.i(TAG, "clipboard: send ${result.name}") // the outcome only, never the text
            done(message(result, macName, image != null))
        }
    }

    private fun done(toast: String) {
        Toast.makeText(applicationContext, toast, Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun message(result: ClipSendResult, macName: String?, isImage: Boolean): String = when (result) {
        ClipSendResult.SENT -> getString(R.string.clipboard_sent, macName ?: getString(R.string.clipboard_mac_unnamed))
        ClipSendResult.EMPTY -> getString(R.string.clipboard_empty)
        ClipSendResult.TOO_LARGE -> getString(R.string.clipboard_too_long)
        ClipSendResult.NOT_CONNECTED -> getString(R.string.clipboard_not_connected)
        ClipSendResult.ALREADY_ON_MAC ->
            getString(if (isImage) R.string.clipboard_image_already_on_mac else R.string.clipboard_already_on_mac)
        ClipSendResult.IMAGE_TOO_LARGE -> getString(R.string.clipboard_image_too_large)
        ClipSendResult.IMAGE_NOT_SUPPORTED -> getString(R.string.clipboard_image_not_supported)
    }

    companion object {
        fun intent(context: Context): Intent =
            Intent(context, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
