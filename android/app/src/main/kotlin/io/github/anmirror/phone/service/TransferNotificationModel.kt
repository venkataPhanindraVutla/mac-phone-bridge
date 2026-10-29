package io.github.anmirror.phone.service

import io.github.anmirror.phone.isOngoing
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.transfer.Direction
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus

/** The one ongoing notification of a direction: the active transfer, and how many wait behind it. */
data class OngoingView(val direction: Direction, val id: String, val name: String, val percent: Int, val waiting: Int)

/**
 * The one results notification of a direction: what ended since the direction last started
 * after being idle. [saved] counts received files (a finished send is not news); the `last*`
 * fields are the most recent of each kind.
 */
data class ResultView(
    val direction: Direction,
    val saved: Int = 0,
    val savedId: String? = null,
    val savedName: String? = null,
    val failed: Int = 0,
    val failedName: String? = null,
    val error: TransferError? = null,
)

/** What to show now. [changed]: directions whose results gained an entry in this update (to be posted afresh). */
data class TransferViews(
    val ongoing: Map<Direction, OngoingView>,
    val results: Map<Direction, ResultView>,
    val changed: Set<Direction>,
)

/**
 * R9: folds the engine's transfer list into at most one ongoing and one results notification
 * per direction, however many transfers there are (Android caps an app's notifications and
 * drops fast updates). A transfer the user cancelled on the phone adds no result. Background
 * auto-sends (screenshots, photos) are not shown at all (R12): the user did not start them on
 * the phone. Pure and single-threaded: call [update] from one collector.
 */
class TransferNotificationModel {
    private val handled = HashSet<String>()
    private val results = HashMap<Direction, ResultView>()

    /** A direction's batch is closed once it has gone idle; its next result starts a new one. */
    private val closed = HashMap<Direction, Boolean>()

    fun update(all: List<TransferStatus>, cancelledHere: Set<String>): TransferViews {
        val list = all.filter { it.kind !in BACKGROUND_KINDS }
        val ongoing = HashMap<Direction, OngoingView>()
        val changed = HashSet<Direction>()
        for (direction in Direction.entries) {
            val mine = list.filter { it.direction == direction }
            val live = mine.filter { it.state.isOngoing() }
            if (live.isNotEmpty()) {
                // One runs at a time per direction: the one past QUEUED, else the first in line.
                val active = live.firstOrNull { it.state != TransferState.QUEUED } ?: live.first()
                ongoing[direction] = OngoingView(direction, active.id, active.name, percent(active), live.size - 1)
            }
            // Oldest first, so the "last" fields end on the newest (the engine lists the newest finished first).
            for (t in mine.filter { !it.state.isOngoing() }.asReversed()) {
                if (!handled.add(t.id)) continue
                if (t.state == TransferState.CANCELLED && t.id in cancelledHere) continue
                if (t.state == TransferState.DONE && direction == Direction.SEND) continue
                val base = if (closed[direction] != false) ResultView(direction) else results.getValue(direction)
                closed[direction] = false
                results[direction] = if (t.state == TransferState.DONE) {
                    base.copy(saved = base.saved + 1, savedId = t.id, savedName = t.savedAs ?: t.name)
                } else {
                    base.copy(failed = base.failed + 1, failedName = t.name, error = t.error)
                }
                changed += direction
            }
            if (live.isEmpty()) closed[direction] = true
        }
        // The engine keeps only recent finished transfers; IDs it dropped never come back.
        val listed = list.mapTo(HashSet()) { it.id }
        handled.retainAll(listed)
        return TransferViews(ongoing, HashMap(results), changed)
    }

    private fun percent(t: TransferStatus): Int =
        if (t.size > 0) (t.done.coerceIn(0, t.size) * 100 / t.size).toInt() else 0

    private companion object {
        val BACKGROUND_KINDS = setOf(TransferKind.TRANSFER_KIND_SCREENSHOT, TransferKind.TRANSFER_KIND_PHOTO)
    }
}
