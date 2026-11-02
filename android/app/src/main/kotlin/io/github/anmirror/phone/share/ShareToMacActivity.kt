package io.github.anmirror.phone.share

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import com.google.protobuf.MessageLite
import io.github.anmirror.feature.share.Outgoing
import io.github.anmirror.feature.share.ShareClassifier
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.R
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.platform.SharedFile
import io.github.anmirror.phone.platform.SharedUri
import io.github.anmirror.phone.platform.UriSources
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.SharedLink
import io.github.anmirror.protocol.v1.SharedText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The "Send to Mac" share target. No UI (a translucent theme): it starts its work in `onCreate`
 * and finishes when done. Files are opened off the main thread while the activity (and so the
 * share's URI grant) is alive, then queued as transfers (they need files.v1). A lone http(s) URL goes as `share.link`, other text as `share.text`
 * (they need share.v1), straight from the intent: no clipboard read (R8); sent text counts as
 * what the Mac's clipboard has (R6). While not connected
 * nothing is sent or queued, and a toast says so. Never logs names, text or URLs.
 */
class ShareToMacActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return finish() // config changes are handled; a restore has nothing to do
        val streams = streams(intent)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        when (val out = ShareClassifier.classify(text, streams.size)) {
            Outgoing.Nothing -> finish()
            Outgoing.Files -> sendFiles(streams) // finishes when the files are open
            is Outgoing.Link -> {
                send(MessageType.SHARE_LINK, SharedLink.newBuilder().setUrl(out.url).build(), sentText = null)
                finish()
            }
            is Outgoing.Text -> {
                if (out.text.toByteArray(Charsets.UTF_8).size > ShareClassifier.MAX_TEXT_BYTES) {
                    toast(getString(R.string.clipboard_too_long))
                } else {
                    send(MessageType.SHARE_TEXT, SharedText.newBuilder().setText(out.text).build(), sentText = out.text)
                }
                finish()
            }
        }
    }

    private fun streams(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        Intent.ACTION_SEND_MULTIPLE ->
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty().filterNotNull()
        else -> emptyList()
    }

    private fun sendFiles(uris: List<Uri>) {
        val graph = AppGraph.get(this)
        if (!graph.filesShared()) {
            toast(getString(R.string.clipboard_not_connected))
            return finish()
        }
        val resolver = contentResolver
        lifecycleScope.launch {
            val ready = mutableListOf<SharedFile>()
            val unreadable = mutableListOf<String>()
            try {
                withContext(Dispatchers.IO) {
                    for (uri in uris) {
                        when (val r = UriSources.open(resolver, uri)) {
                            is SharedUri.Ready -> synchronized(ready) { ready += r.file }
                            is SharedUri.Unreadable -> unreadable += r.name
                        }
                    }
                }
            } catch (e: CancellationException) {
                synchronized(ready) { ready.forEach { it.close() } } // destroyed meanwhile: send nothing
                toast(getString(R.string.share_not_sent))
                throw e
            }
            Log.i(TAG, "share: ${ready.size} files queued, ${unreadable.size} unreadable")
            if (ready.isNotEmpty()) graph.sendFiles(ready)
            when (unreadable.size) {
                0 -> Unit
                1 -> toast(getString(R.string.share_file_unreadable, unreadable.first()))
                else -> toast(resources.getQuantityString(R.plurals.share_files_unreadable, unreadable.size, unreadable.size))
            }
            finish()
        }
    }

    /** [sentText]: the text of a `share.text`, which the Mac puts on its clipboard (R6). */
    private fun send(type: String, payload: MessageLite, sentText: String?) {
        val graph = AppGraph.get(this)
        if (!graph.shareShared()) return toast(getString(R.string.clipboard_not_connected))
        // Taken before sending: the toast names the Mac it went to.
        val macName = graph.connectedMacName() ?: getString(R.string.clipboard_mac_unnamed)
        val app = applicationContext
        graph.scope.launch {
            val sent = graph.sendShare(type, payload)
            if (sent && sentText != null) graph.clipboard.noteSentToMac(sentText)
            Log.i(TAG, "share: $type ${if (sent) "sent" else "not sent"}")
            val message = if (sent) app.getString(R.string.clipboard_sent, macName) else app.getString(R.string.clipboard_not_connected)
            withContext(Dispatchers.Main) { Toast.makeText(app, message, Toast.LENGTH_SHORT).show() }
        }
    }

    private fun toast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }
}
