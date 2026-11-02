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
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MIRROR_TAG
import io.github.anmirror.phone.R
import io.github.anmirror.phone.pairingErrorRes
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
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

    /** POST_NOTIFICATIONS is granted (API 33+). */
    fun permitted(context: Context): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /**
     * The pairing notification would show: permitted, the app's notifications on, and this channel
     * not turned off. Without it the code can't be typed in, so the Full mode screen says so.
     */
    fun canPost(context: Context): Boolean = permitted(context) && appNotificationsOn(context) && channelOn(context)

    /** The user hasn't turned off all of this app's notifications. */
    fun appNotificationsOn(context: Context): Boolean = NotificationManagerCompat.from(context.applicationContext).areNotificationsEnabled()

    /** The user hasn't turned off the "Full mode setup" channel. */
    fun channelOn(context: Context): Boolean {
        val app = context.applicationContext
        createChannel(app)
        return NotificationManagerCompat.from(app).getNotificationChannelCompat(CHANNEL_ID)?.importance != NotificationManagerCompat.IMPORTANCE_NONE
    }

    private fun createChannel(app: Context) {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
            .setName(app.getString(R.string.channel_full_mode))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(app).createNotificationChannel(channel)
    }

    fun post(context: Context, portKnown: Boolean, error: PairingError?) {
        val app = context.applicationContext
        // Spelled out (not permitted()) so lint sees the check.
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!allowed) return
        createChannel(app)
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

/** POST_NOTIFICATIONS as the Full mode screen sees it: granted, still to ask for, or refused. */
enum class NotificationPermission { GRANTED, ASKABLE, DENIED }

/** Where the pairing code is typed. */
enum class PairingInput {
    /** The RemoteInput notification, over Settings' pairing screen. */
    NOTIFICATION,

    /** "Start pairing" asks for POST_NOTIFICATIONS first. */
    ASK_PERMISSION,

    /** The notification can't show: the Full mode screen's own port and code fields (ruling R50). */
    IN_APP,
}

/**
 * The notification while it can show; the in-app fields when the permission was refused, or the
 * app's notifications or the "Full mode setup" channel are turned off; otherwise ask first.
 */
fun pairingInput(permission: NotificationPermission, appNotificationsOn: Boolean, channelOn: Boolean): PairingInput = when (permission) {
    NotificationPermission.ASKABLE -> PairingInput.ASK_PERMISSION
    NotificationPermission.DENIED -> PairingInput.IN_APP
    NotificationPermission.GRANTED -> if (appNotificationsOn && channelOn) PairingInput.NOTIFICATION else PairingInput.IN_APP
}

/** The pairing has done its job once the setup connects (or gives up connecting): the notification goes. */
fun closesPairingNotification(state: SetupState): Boolean =
    state == SetupState.Connecting || state == SetupState.Ready || state == SetupState.ConnectFailed

/**
 * Holds the reply broadcast while [work] pairs: until it ends, the setup starts connecting, or
 * [holdMs] pass. Android delivers one broadcast at a time to the app, and connecting waits for the
 * ADB proof's own broadcast (ruling R58), so the reply must be let go before then.
 */
suspend fun holdReplyBroadcast(work: Job, state: StateFlow<SetupState>, holdMs: Long) {
    withTimeoutOrNull(holdMs) {
        select {
            work.onJoin {}
            async { state.first(::closesPairingNotification) }.onAwait {}
        }
        coroutineContext.cancelChildren()
    }
}

/**
 * The pairing notification's "Enter code": hands the typed reply to the Full mode setup. Pairing
 * and connecting can outlast a receiver's time, so the work runs on the app scope; the broadcast
 * is held while pairing, for at most [HOLD_MS] (see [holdReplyBroadcast]). The reply is never logged.
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
                holdReplyBroadcast(work, graph.fullModeSetup.state, HOLD_MS)
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
