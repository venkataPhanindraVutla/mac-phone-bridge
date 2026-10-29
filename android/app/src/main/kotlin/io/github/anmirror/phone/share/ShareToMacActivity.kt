package io.github.anmirror.phone.share

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The "Send to Mac" share target. No UI (a translucent theme): it does its work in `onCreate` and
 * finishes. Files are opened here, while the share's URI grant is live, and queued as transfers
 * (they need files.v1). A lone http(s) URL goes as `share.link`, other text as `share.text`
 * (they need share.v1), straight from the intent: no clipboard read (R8). While not connected
 * nothing is sent or queued, and a toast says so. Never logs names, text or URLs.
 */
class ShareToMacActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) share(intent)
        finish()
    }

    private fun share(intent: Intent) {
        val streams = streams(intent)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        when (val out = ShareClassifier.classify(text, streams.size)) {
            Outgoing.Nothing -> Unit
            Outgoing.Files -> sendFiles(streams)
            is Outgoing.Link -> send(MessageType.SHARE_LINK, SharedLink.newBuilder().setUrl(out.url).build())
            is Outgoing.Text -> {
                if (out.text.toByteArray(Charsets.UTF_8).size > ShareClassifier.MAX_TEXT_BYTES) {
                    toast(getString(R.string.clipboard_too_long))
                } else {
                    send(MessageType.SHARE_TEXT, SharedText.newBuilder().setText(out.text).build())
                }
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
        if (!graph.filesShared()) return toast(getString(R.string.clipboard_not_connected))
        val ready = mutableListOf<SharedFile>()
        var unreadable: String? = null
        for (uri in uris) {
            when (val r = UriSources.open(contentResolver, uri)) {
                is SharedUri.Ready -> ready += r.file
                is SharedUri.Unreadable -> if (unreadable == null) unreadable = r.name
            }
        }
        Log.i(TAG, "share: ${ready.size} files queued, ${uris.size - ready.size} unreadable")
        if (ready.isNotEmpty()) graph.sendFiles(ready)
        unreadable?.let { toast(getString(R.string.share_file_unreadable, it)) }
    }

    private fun send(type: String, payload: MessageLite) {
        val graph = AppGraph.get(this)
        if (!graph.shareShared()) return toast(getString(R.string.clipboard_not_connected))
        // Taken before sending: the toast names the Mac it went to.
        val macName = graph.connectedMacName() ?: getString(R.string.clipboard_mac_unnamed)
        val app = applicationContext
        graph.scope.launch {
            val sent = graph.sendShare(type, payload)
            Log.i(TAG, "share: $type ${if (sent) "sent" else "not sent"}")
            val message = if (sent) app.getString(R.string.clipboard_sent, macName) else app.getString(R.string.clipboard_not_connected)
            withContext(Dispatchers.Main) { Toast.makeText(app, message, Toast.LENGTH_SHORT).show() }
        }
    }

    private fun toast(message: String) {
        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
    }
}
