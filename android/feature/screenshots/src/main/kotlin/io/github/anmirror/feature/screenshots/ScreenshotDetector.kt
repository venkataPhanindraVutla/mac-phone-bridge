package io.github.anmirror.feature.screenshots

/**
 * Picks new screenshots out of MediaStore image changes (F-12). A row is one when its
 * `RELATIVE_PATH` contains "screenshot" (any case, so "Screenshots" and OEM "Screenshot" folders
 * both match), it was added at most [WINDOW_SEC] ago and at most [SKEW_SEC] ahead of now, it is
 * published (not pending), and it was not returned before.
 *
 * Returned IDs are remembered while they are inside the window (MediaStore reports several
 * changes per screenshot), at most [KEEP_IDS] of them.
 *
 * [clock] is in milliseconds. Thread-safe; the query runs outside the lock, so [reset] never
 * waits on MediaStore.
 */
class ScreenshotDetector(private val query: ImageQuery, private val clock: () -> Long) {
    /** Returned IDs and when they were added, in the order returned. */
    private val returned = LinkedHashMap<Long, Long>()

    /** Rows added before this second are never returned (see [reset]). */
    private var floorSec = Long.MIN_VALUE

    internal val rememberedIds: Int get() = synchronized(this) { returned.size }

    /** The new screenshots since the last call, oldest first (ties by ID). */
    fun onChange(): List<ImageRow> {
        val nowSec = clock() / 1_000
        val windowStart = nowSec - WINDOW_SEC
        val untilSec = nowSec + SKEW_SEC
        val rows = query.addedSince(maxOf(windowStart, synchronized(this) { floorSec }), untilSec)
        synchronized(this) {
            val since = maxOf(windowStart, floorSec) // a reset meanwhile raised the floor
            returned.values.removeIf { it < windowStart }
            val found = rows
                .filter { row ->
                    row.dateAddedSec in since..untilSec &&
                        !row.pending &&
                        row.relativePath?.contains(FOLDER, ignoreCase = true) == true &&
                        row.id !in returned
                }
                .sortedWith(compareBy<ImageRow> { it.dateAddedSec }.thenBy { it.id })
            for (row in found) {
                returned[row.id] = row.dateAddedSec
                if (returned.size > KEEP_IDS) returned.remove(returned.keys.first())
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

        /** How far ahead of the phone's clock a DATE_ADDED may be and still count. */
        const val SKEW_SEC = 60L
        const val KEEP_IDS = 50

        /** Matched case-insensitively, as a substring of RELATIVE_PATH (also in [screenshotSelection]). */
        internal const val FOLDER = "screenshot"
    }
}
