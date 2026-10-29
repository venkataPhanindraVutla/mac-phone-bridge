package io.github.anmirror.phone.service

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.github.anmirror.phone.R
import io.github.anmirror.phone.platform.SavedFile
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.transfer.Direction
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** "Sending %1$s" / "Receiving %1$s". */
internal fun ongoingTitleRes(direction: Direction): Int = when (direction) {
    Direction.SEND -> R.string.transfer_sending
    Direction.RECEIVE -> R.string.transfer_receiving
}

/** "Couldn't send %1$s" / "Couldn't receive %1$s". */
internal fun failureTitleRes(direction: Direction): Int = when (direction) {
    Direction.SEND -> R.string.transfer_send_failed
    Direction.RECEIVE -> R.string.transfer_receive_failed
}

/** The reason line under a failure title. Space and refusals are about the receiving side. */
internal fun failureReasonRes(error: TransferError?, direction: Direction): Int {
    val sending = direction == Direction.SEND
    return when (error) {
        TransferError.TRANSFER_ERROR_NO_SPACE ->
            if (sending) R.string.transfer_reason_no_space_mac else R.string.transfer_reason_no_space_phone
        TransferError.TRANSFER_ERROR_CANCELLED -> R.string.transfer_reason_cancelled
        TransferError.TRANSFER_ERROR_HASH_MISMATCH -> R.string.transfer_reason_damaged
        TransferError.TRANSFER_ERROR_TIMED_OUT -> R.string.transfer_reason_no_answer
        TransferError.TRANSFER_ERROR_IO ->
            if (sending) R.string.transfer_reason_read_failed else R.string.transfer_reason_save_failed
        TransferError.TRANSFER_ERROR_NOT_FOUND -> R.string.transfer_reason_not_found
        TransferError.TRANSFER_ERROR_DENIED,
        TransferError.TRANSFER_ERROR_DISABLED,
        TransferError.TRANSFER_ERROR_BAD_TARGET ->
            if (sending) R.string.transfer_reason_refused else R.string.transfer_reason_refused_here
        TransferError.TRANSFER_ERROR_INTERRUPTED,
        TransferError.TRANSFER_ERROR_UNSPECIFIED,
        TransferError.UNRECOGNIZED,
        null -> R.string.transfer_reason_connection_lost
    }
}

/**
 * Shows the transfer engine's list as notifications on channel `transfers`: ongoing ones with a
 * progress bar (updated at most every [intervalMs]) and Cancel, received files as "Saved to
 * Download/Android Mirroring" (a tap opens them), failures with their reason. A finished send just
 * goes away. Each transfer has its own notification, tagged with its ID. Posts nothing while
 * POST_NOTIFICATIONS is not granted. Never logs names.
 */
class TransferNotifier(
    context: Context,
    private val transfers: StateFlow<List<TransferStatus>>,
    private val saved: (transferId: String) -> SavedFile?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val intervalMs: Long = 500,
) {
    private val app = context.applicationContext
    private val manager = NotificationManagerCompat.from(app)

    private class Shown(val state: TransferState, val at: Long)

    /** The last ongoing post per transfer, for the rate limit. */
    private val shown = HashMap<String, Shown>()

    /** Transfers whose final notification has been handled. */
    private val ended = HashSet<String>()

    fun launchIn(scope: CoroutineScope): Job {
        createChannel()
        return scope.launch { transfers.collect(::onList) }
    }

    private fun onList(list: List<TransferStatus>) {
        val now = clock()
        for (t in list) {
            when (t.state) {
                TransferState.QUEUED, TransferState.WAITING, TransferState.ACTIVE -> {
                    val last = shown[t.id]
                    if (last != null && last.state == t.state && now - last.at < intervalMs) continue
                    shown[t.id] = Shown(t.state, now)
                    post(t.id, ongoing(t))
                }
                TransferState.DONE, TransferState.FAILED, TransferState.CANCELLED -> {
                    if (!ended.add(t.id)) continue
                    shown.remove(t.id)
                    if (t.state == TransferState.DONE && t.direction == Direction.SEND) {
                        manager.cancel(t.id, NOTIFICATION_ID)
                    } else {
                        post(t.id, if (t.state == TransferState.DONE) savedNotification(t) else failed(t))
                    }
                }
            }
        }
        // The engine keeps only recent finished transfers: forget the ones it dropped.
        val ids = list.mapTo(HashSet()) { it.id }
        ended.retainAll(ids)
        shown.keys.retainAll(ids)
    }

    private fun base(t: TransferStatus) = NotificationCompat.Builder(app, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOnlyAlertOnce(true)
        .setSortKey(t.id)

    private fun ongoing(t: TransferStatus): android.app.Notification {
        val cancel = PendingIntent.getBroadcast(
            app,
            0,
            TransferActionReceiver.cancelIntent(app, t.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val percent = if (t.size > 0) (t.done.coerceIn(0, t.size) * 100 / t.size).toInt() else 0
        return base(t)
            .setContentTitle(app.getString(ongoingTitleRes(t.direction), t.name))
            .setProgress(100, percent, false)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .addAction(0, app.getString(R.string.transfer_cancel), cancel)
            .build()
    }

    private fun savedNotification(t: TransferStatus): android.app.Notification {
        val builder = base(t)
            .setContentTitle(app.getString(R.string.transfer_saved))
            .setContentText(t.savedAs ?: t.name)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
        saved(t.id)?.let { file ->
            val view = Intent(Intent.ACTION_VIEW)
                .setDataAndType(file.uri, file.mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.setContentIntent(
                PendingIntent.getActivity(app, 0, view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }
        return builder.build()
    }

    private fun failed(t: TransferStatus): android.app.Notification = base(t)
        .setContentTitle(app.getString(failureTitleRes(t.direction), t.name))
        .setContentText(app.getString(failureReasonRes(t.error, t.direction)))
        .setCategory(NotificationCompat.CATEGORY_ERROR)
        .setAutoCancel(true)
        .build()

    private fun post(tag: String, notification: android.app.Notification) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed) manager.notify(tag, NOTIFICATION_ID, notification)
    }

    private fun createChannel() {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(app.getString(R.string.channel_transfers))
            .setDescription(app.getString(R.string.channel_transfers_description))
            .setShowBadge(false)
            .build()
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "transfers"

        /** With the transfer ID as tag (ConnectionService uses 1, find uses 2). */
        private const val NOTIFICATION_ID = 3
    }
}
