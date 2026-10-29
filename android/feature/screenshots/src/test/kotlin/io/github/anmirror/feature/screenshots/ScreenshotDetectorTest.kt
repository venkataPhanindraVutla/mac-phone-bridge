package io.github.anmirror.feature.screenshots

import io.github.anmirror.transfer.OutgoingFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The MediaStore as a list the test edits; `addedSince` filters like the real query. */
private class FakeImages : ImageQuery {
    val rows = mutableListOf<ImageRow>()
    val asked = mutableListOf<Long>()

    override fun addedSince(sinceSec: Long): List<ImageRow> {
        asked += sinceSec
        return rows.filter { it.dateAddedSec >= sinceSec }
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
        // Only the last 30 s are asked for.
        assertEquals(NOW_SEC - 30, images.asked.last())
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
            override fun addedSince(sinceSec: Long) = listOf(row(3, addedSec = NOW_SEC - 120))
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
        repeat(51) { images.rows += row(it.toLong()) }
        assertEquals(51, detector.onChange().size)
        // The oldest of 51 fell out of memory; the other 50 are still known.
        assertEquals(listOf(0L), detector.onChange().map { it.id })
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
