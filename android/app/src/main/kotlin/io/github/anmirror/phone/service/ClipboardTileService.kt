package io.github.anmirror.phone.service

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.R
import io.github.anmirror.phone.share.ClipboardSendActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Quick Settings tile "Send clipboard to Mac". Active only while connected, the Mac shares
 * clipboard.v1 and "Share clipboard with your Mac" is on (followed live while the tile is
 * shown); a tap opens [ClipboardSendActivity], which reads the clipboard (it needs focus) and
 * sends it.
 */
class ClipboardTileService : TileService() {
    private var watching: Job? = null

    override fun onStartListening() {
        super.onStartListening()
        val graph = AppGraph.get(this)
        watching?.cancel()
        watching = graph.scope.launch(Dispatchers.Main) {
            graph.clipboardReady.collect { ready -> show(ready) }
        }
    }

    override fun onStopListening() {
        watching?.cancel()
        watching = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    private fun show(ready: Boolean) {
        val tile = qsTile ?: return
        tile.label = getString(R.string.tile_send_clipboard)
        tile.state = if (ready) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun open() {
        val intent = ClipboardSendActivity.intent(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
