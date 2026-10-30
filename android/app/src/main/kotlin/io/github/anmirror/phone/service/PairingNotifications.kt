package io.github.anmirror.phone.service

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import io.github.anmirror.feature.mirror.PairingError
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MIRROR_TAG
import io.github.anmirror.phone.R
import io.github.anmirror.phone.pairingErrorRes
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The pairing notification of the Full mode setup: the code shown under "Pair device with
 * pairing code" is typed into it (Settings must stay on that screen, so the app can't be opened).
 * High importance, so it shows over Settings; posted again with the error line after a failure,
 * removed once pairing succeeded.
 */
object PairingNotifications {
    private const val CHANNEL_ID = "full_mode_setup"
    private const val TAG_PAIRING = "pairing"
    private const val NOTIFICATION_ID = 4
    internal const val KEY_REPLY = "reply"

    fun post(context: Context, portKnown: Boolean, error: PairingError?) {
        val app = context.applicationContext
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!allowed) return
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
            .setName(app.getString(R.string.channel_full_mode))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(app).createNotificationChannel(channel)
        val prompt = app.getString(if (portKnown) R.string.pairing_notification_text_code else R.string.pairing_notification_text_port_and_code)
        val text = error?.let { app.getString(pairingErrorRes(it)) + " " + prompt } ?: prompt
        val input = RemoteInput.Builder(KEY_REPLY)
            .setLabel(app.getString(if (portKnown) R.string.pairing_notification_input_code else R.string.pairing_notification_input_port_and_code))
            .build()
        // Mutable: the system adds the typed reply to the intent. Explicit, to this app's own receiver.
        val reply = PendingIntent.getBroadcast(
            app,
            NOTIFICATION_ID,
            Intent(app, PairingReplyReceiver::class.java),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val action = NotificationCompat.Action.Builder(0, app.getString(R.string.pairing_notification_action), reply)
            .addRemoteInput(input)
            .setAllowGeneratedReplies(false)
            .build()
        val notification = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(app.getString(R.string.pairing_notification_title))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .addAction(action)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(false)
            .build()
        NotificationManagerCompat.from(app).notify(TAG_PAIRING, NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context.applicationContext).cancel(TAG_PAIRING, NOTIFICATION_ID)
    }
}

/**
 * The pairing notification's "Enter code": hands the typed reply to the Full mode setup. Pairing
 * and connecting can outlast a receiver's time, so the work runs on the app scope; the broadcast
 * is held for at most [HOLD_MS]. The reply is never logged.
 */
class PairingReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(PairingNotifications.KEY_REPLY)?.toString() ?: return
        val graph = AppGraph.get(context.applicationContext)
        val pending = goAsync()
        val work = graph.scope.launch {
            val error = graph.fullModeSetup.submitReply(text)
            Log.i(MIRROR_TAG, "setup: reply handled (${error ?: "paired"})")
        }
        graph.scope.launch {
            try {
                withTimeoutOrNull(HOLD_MS) { work.join() }
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        /** Below the 60 s a background broadcast may take. */
        const val HOLD_MS = 50_000L
    }
}
