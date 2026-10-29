package io.github.anmirror.feature.screenshots

import io.github.anmirror.transfer.OutgoingFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The MediaStore as a list the test edits. `addedSince` filters on time only (so the detector's
 * own checks are exercised) and, like the real query, returns at most [limit] rows, newest first.
 */
private class FakeImages(private val limit: Int = Int.MAX_VALUE) : ImageQuery {
    val rows = mutableListOf<ImageRow>()
    val asked = mutableListOf<Pair<Long, Long>>()

    override fun addedSince(sinceSec: Long, untilSec: Long): List<ImageRow> {
        asked += sinceSec to untilSec
        return rows.filter { it.dateAddedSec in sinceSec..untilSec }
            .sortedWith(compareByDescending<ImageRow> { it.dateAddedSec }.thenByDescending { it.id })
            .take(limit)
    }

    override fun open(id: Long): OutgoingFile? = null
}

private const val NOW_SEC = 1_800_000_000L

private fun row(
    id: Long,
    path: String? = "Pictures/Screenshots/",
    addedSec: Long = NOW_SEC - 2,
    pending: Boolean = false,
) = ImageRow(id, path, addedSec, pending, "Screenshot_$id.png", 1_000, "image/png")

class ScreenshotDetectorTest {
    private val images = FakeImages()
    private var nowMs = NOW_SEC * 1_000
    private val detector = ScreenshotDetector(images) { nowMs }

    @Test fun newScreenshotIsDetected() {
        images.rows += row(1)
        // Some phones put them in DCIM/Screenshots, and the case varies.
        images.rows += row(2, path = "DCIM/screenshots/")
        assertEquals(listOf(1L, 2L), detector.onChange().map { it.id })
        // Only the last 30 s are asked for (and a minute of clock skew ahead).
        assertEquals(NOW_SEC - 30 to NOW_SEC + 60, images.asked.last())
    }

    @Test fun pendingRowWaitsUntilPublished() {
        images.rows += row(1, pending = true)
        assertTrue(detector.onChange().isEmpty())
        images.rows[0] = row(1, pending = false)
        nowMs += 1_000
        assertEquals(listOf(1L), detector.onChange().map { it.id })
    }

    @Test fun olderThan30sIsIgnored() {
        images.rows += row(1, addedSec = NOW_SEC - 31)
        images.rows += row(2, addedSec = NOW_SEC - 30)
        assertEquals(listOf(2L), detector.onChange().map { it.id })
        // A row the query returns anyway (clock skew) is still held to 30 s.
        val stale = object : ImageQuery {
            override fun addedSince(sinceSec: Long, untilSec: Long) = listOf(row(3, addedSec = NOW_SEC - 120))
            override fun open(id: Long): OutgoingFile? = null
        }
        assertTrue(ScreenshotDetector(stale) { nowMs }.onChange().isEmpty())
    }

    @Test fun cameraPhotoIsIgnored() {
        images.rows += row(1, path = "DCIM/Camera/")
        images.rows += row(2, path = null)
        images.rows += row(3, path = "Pictures/WhatsApp/")
        assertTrue(detector.onChange().isEmpty())
    }

    @Test fun sameRowIsReturnedOnce() {
        images.rows += row(1)
        assertEquals(listOf(1L), detector.onChange().map { it.id })
        // MediaStore reports many changes per screenshot (insert, publish, thumbnails).
        assertTrue(detector.onChange().isEmpty())
        images.rows += row(2)
        assertEquals(listOf(2L), detector.onChange().map { it.id })
    }

    @Test fun keepsTheLast50ReturnedIds() {
        // More screenshots in the window than the query returns (it gives the newest 50).
        val busy = FakeImages(limit = 50)
        val detector = ScreenshotDetector(busy) { nowMs }
        repeat(60) { busy.rows += row(it + 1L, addedSec = NOW_SEC - 2) }
        assertEquals((11L..60L).toList(), detector.onChange().map { it.id })
        // Nothing is sent twice while it is still inside the window, however often MediaStore calls.
        for (later in listOf(1, 10, 25)) {
            nowMs = (NOW_SEC + later) * 1_000
            assertTrue(detector.onChange().isEmpty())
        }
        // A new one goes; the memory stays at its cap without letting an old one back in.
        busy.rows += row(61, addedSec = NOW_SEC + 25)
        assertEquals(listOf(61L), detector.onChange().map { it.id })
        assertTrue(detector.onChange().isEmpty())
        assertEquals(50, detector.rememberedIds)
    }

    @Test fun idsOutsideTheWindowAreForgotten() {
        images.rows += row(1, addedSec = NOW_SEC - 2)
        detector.onChange()
        assertEquals(1, detector.rememberedIds)
        nowMs = (NOW_SEC + 40) * 1_000
        assertTrue(detector.onChange().isEmpty())
        assertEquals(0, detector.rememberedIds)
    }

    @Test fun futureDatedRowIsIgnoredAfterReset() {
        // Clock skew, or an OEM writing DATE_ADDED in milliseconds: never inside the window.
        images.rows += row(1, addedSec = NOW_SEC + 61)
        images.rows += row(2, addedSec = NOW_SEC * 1_000)
        val bypass = object : ImageQuery {
            override fun addedSince(sinceSec: Long, untilSec: Long) = images.rows.toList()
            override fun open(id: Long): OutgoingFile? = null
        }
        val skewed = ScreenshotDetector(bypass) { nowMs }
        assertTrue(skewed.onChange().isEmpty())
        // Not resent on every reconnect either.
        repeat(3) {
            skewed.reset()
            assertTrue(skewed.onChange().isEmpty())
        }
        assertTrue(detector.onChange().isEmpty())
    }

    @Test fun singularScreenshotFolderIsDetected() {
        images.rows += row(1, path = "Pictures/Screenshot/")
        images.rows += row(2, path = "DCIM/SCREENSHOT/")
        assertEquals(listOf(1L, 2L), detector.onChange().map { it.id })
    }

    @Test fun sameSecondBurstGoesOutOldestFirst() {
        // The query hands them over newest first, and some in the same second.
        images.rows += row(7, addedSec = NOW_SEC - 1)
        images.rows += row(5, addedSec = NOW_SEC - 3)
        images.rows += row(6, addedSec = NOW_SEC - 3)
        images.rows += row(4, addedSec = NOW_SEC - 3)
        assertEquals(listOf(4L, 5L, 6L, 7L), detector.onChange().map { it.id })
    }

    @Test fun resetIgnoresWhatWasAddedBefore() {
        // Taken while the feature was closed (disconnected, say): never sent later.
        images.rows += row(1, addedSec = NOW_SEC - 5)
        detector.reset()
        assertTrue(detector.onChange().isEmpty())
        images.rows += row(2, addedSec = NOW_SEC)
        assertEquals(listOf(2L), detector.onChange().map { it.id })
    }
}
