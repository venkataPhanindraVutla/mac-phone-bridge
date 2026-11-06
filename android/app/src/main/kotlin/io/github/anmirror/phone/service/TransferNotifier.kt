package io.github.anmirror.phone.service

import android.Manifest
import android.app.DownloadManager
import android.app.Notification
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
import io.github.anmirror.transfer.TransferStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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

/** "Couldn't send %1$d files" / "Couldn't receive %1$d files" (plurals). */
internal fun failureCountRes(direction: Direction): Int = when (direction) {
    Direction.SEND -> R.plurals.transfer_send_failed_count
    Direction.RECEIVE -> R.plurals.transfer_receive_failed_count
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
 * Shows the transfer engine's list as at most two notifications per direction (R9), on channel
 * `transfers`:
 * - **Ongoing:** the active transfer, "Sending/Receiving %1$s" with a progress bar and Cancel
 *   (which cancels that transfer), plus "%1$d more waiting". Updated at most every [intervalMs]
 *   per direction, sooner when the active transfer changes, so Android's update rate limit never
 *   drops one; a skipped update is posted once the interval is up.
 * - **Results:** what ended since the direction last started: received files ("Saved to
 *   Download/Mac Phone Bridge", a tap opens the file, or the Downloads view for several) and
 *   failures with their reason. Re-posted (cancel, then notify) as results arrive.
 * Posts nothing while POST_NOTIFICATIONS is not granted. Never logs names.
 */
class TransferNotifier(
    context: Context,
    private val transfers: StateFlow<List<TransferStatus>>,
    private val saved: (transferId: String) -> SavedFile?,
    private val cancelledHere: () -> Set<String>,
    private val clock: () -> Long = System::currentTimeMillis,
    private val intervalMs: Long = 500,
) {
    private val app = context.applicationContext
    private val manager = NotificationManagerCompat.from(app)
    private val model = TransferNotificationModel()

    private class Posted(val id: String, val at: Long)

    /** The ongoing notification as last posted, per direction. Touched only by the collector. */
    private val posted = HashMap<Direction, Posted>()
    private val latest = HashMap<Direction, OngoingView>()
    private var flush: Job? = null

    /**
     * Starts following the engine. Called once per process: first removes transfer notifications
     * a killed process left behind (an ongoing one would otherwise stay forever).
     */
    fun launchIn(scope: CoroutineScope): Job {
        createChannel()
        for (id in ALL_IDS) manager.cancel(id)
        // One thread: the model, [posted] and [latest] are touched only from here.
        return scope.launch(Dispatchers.Default.limitedParallelism(1)) {
            transfers.collect { list -> show(model.update(list, cancelledHere()), this) }
        }
    }

    private fun show(views: TransferViews, scope: CoroutineScope) {
        val now = clock()
        for (direction in Direction.entries) {
            val view = views.ongoing[direction]
            if (view == null) {
                latest.remove(direction)
                if (posted.remove(direction) != null) manager.cancel(ongoingId(direction))
            } else {
                latest[direction] = view
                val last = posted[direction]
                if (last == null || last.id != view.id || now - last.at >= intervalMs) {
                    postOngoing(view, now)
                } else {
                    scheduleFlush(scope, intervalMs - (now - last.at))
                }
            }
            if (direction in views.changed) views.results[direction]?.let(::postResult)
        }
    }

    /** Posts what a rate-limited update skipped, once the interval is up. */
    private fun scheduleFlush(scope: CoroutineScope, waitMs: Long) {
        if (flush?.isActive == true) return
        flush = scope.launch {
            delay(waitMs)
            val now = clock()
            for ((direction, view) in latest) {
                val last = posted[direction] ?: continue
                if (now - last.at >= intervalMs) postOngoing(view, now)
            }
        }
    }

    private fun postOngoing(view: OngoingView, now: Long) {
        posted[view.direction] = Posted(view.id, now)
        val cancel = PendingIntent.getBroadcast(
            app,
            0,
            TransferActionReceiver.cancelIntent(app, view.id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = base()
            .setContentTitle(app.getString(ongoingTitleRes(view.direction), view.name))
            .setProgress(100, view.percent, false)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .addAction(0, app.getString(R.string.transfer_cancel), cancel)
        if (view.waiting > 0) {
            builder.setContentText(app.resources.getQuantityString(R.plurals.transfer_more_waiting, view.waiting, view.waiting))
        }
        post(ongoingId(view.direction), builder.build())
    }

    private fun postResult(r: ResultView) {
        val builder = base()
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
        val tap: Intent? = when {
            r.failed > 0 -> {
                val title = if (r.failed == 1) {
                    app.getString(failureTitleRes(r.direction), r.failedName)
                } else {
                    app.resources.getQuantityString(failureCountRes(r.direction), r.failed, r.failed)
                }
                builder.setContentTitle(title)
                    .setContentText(app.getString(failureReasonRes(r.error, r.direction)))
                    .setCategory(NotificationCompat.CATEGORY_ERROR)
                if (r.saved > 0) downloadsView() else null
            }
            r.saved == 1 -> {
                builder.setContentTitle(app.getString(R.string.transfer_saved)).setContentText(r.savedName)
                r.savedId?.let(saved)?.let { file ->
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(file.uri, file.mime)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            r.saved > 1 -> {
                builder.setContentTitle(app.resources.getQuantityString(R.plurals.transfer_saved_count, r.saved, r.saved))
                downloadsView()
            }
            else -> return
        }
        tap?.let {
            builder.setContentIntent(PendingIntent.getActivity(app, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        // A fresh post, not an update: Android may drop updates that come too fast, never new posts.
        val id = resultId(r.direction)
        manager.cancel(id)
        post(id, builder.build())
    }

    private fun downloadsView() =
        Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun base() = NotificationCompat.Builder(app, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_notification)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOnlyAlertOnce(true)

    private fun post(id: Int, notification: Notification) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed) manager.notify(id, notification)
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

        // ConnectionService uses 1, find uses 2.
        private fun ongoingId(d: Direction) = if (d == Direction.SEND) 3 else 4
        private fun resultId(d: Direction) = if (d == Direction.SEND) 5 else 6
        private val ALL_IDS = listOf(3, 4, 5, 6)
    }
}
