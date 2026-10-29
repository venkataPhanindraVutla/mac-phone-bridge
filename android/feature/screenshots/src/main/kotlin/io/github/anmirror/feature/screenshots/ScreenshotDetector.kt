package io.github.anmirror.feature.screenshots

/**
 * Picks new screenshots out of MediaStore image changes (F-12). A row is one when its
 * `RELATIVE_PATH` contains "Screenshots" (any case), it was added at most [WINDOW_SEC] ago, it is
 * published (not pending), and it was not returned before. The last [KEEP_IDS] returned IDs are
 * remembered, since MediaStore reports several changes per screenshot.
 *
 * [clock] is in milliseconds. Thread-safe; the query runs outside the lock, so [reset] never
 * waits on MediaStore.
 */
class ScreenshotDetector(private val query: ImageQuery, private val clock: () -> Long) {
    /** Returned IDs, oldest first. */
    private val returned = LinkedHashSet<Long>()

    /** Rows added before this second are never returned (see [reset]). */
    private var floorSec = Long.MIN_VALUE

    /** The new screenshots since the last call, oldest first. */
    fun onChange(): List<ImageRow> {
        val windowStart = clock() / 1_000 - WINDOW_SEC
        val rows = query.addedSince(maxOf(windowStart, synchronized(this) { floorSec }))
        synchronized(this) {
            val since = maxOf(windowStart, floorSec) // a reset meanwhile raised the floor
            val found = rows
                .filter { row ->
                    row.dateAddedSec >= since &&
                        !row.pending &&
                        row.relativePath?.contains(FOLDER, ignoreCase = true) == true &&
                        row.id !in returned
                }
                .sortedBy { it.dateAddedSec }
            for (row in found) {
                returned += row.id
                if (returned.size > KEEP_IDS) returned.remove(returned.first())
            }
            return found
        }
    }

    /**
     * The feature (re)opened: forgets what was returned and ignores everything added before now,
     * so screenshots taken while it was closed (disconnected, switched off) are never sent later.
     */
    @Synchronized
    fun reset() {
        returned.clear()
        floorSec = clock() / 1_000
    }

    companion object {
        const val WINDOW_SEC = 30L
        const val KEEP_IDS = 50
        private const val FOLDER = "Screenshots"
    }
}
