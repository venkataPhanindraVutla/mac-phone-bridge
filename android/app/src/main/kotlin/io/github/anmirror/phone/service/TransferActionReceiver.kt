package io.github.anmirror.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.github.anmirror.phone.AppGraph

/** The transfer notification's Cancel: cancels that transfer (not exported; only our PendingIntent reaches it). */
class TransferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL) return
        val id = intent.data?.schemeSpecificPart ?: return
        AppGraph.get(context).cancelTransfer(id)
    }

    companion object {
        private const val ACTION_CANCEL = "io.github.anmirror.phone.CANCEL_TRANSFER"

        /** The transfer ID is the data URI, so each transfer's PendingIntent is distinct. */
        fun cancelIntent(context: Context, transferId: String): Intent =
            Intent(context, TransferActionReceiver::class.java)
                .setAction(ACTION_CANCEL)
                .setData(Uri.fromParts("anmirror-transfer", transferId, null))
    }
}
