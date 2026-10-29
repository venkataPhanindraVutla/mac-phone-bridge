package io.github.anmirror.feature.screenshots

import kotlin.test.Test
import kotlin.test.assertEquals

class ImageQuerySelectionTest {
    @Test fun nonScreenshotsCannotCrowdOutAScreenshot() {
        // The folder and the time window are in SQL, so the query's LIMIT counts only candidates:
        // a burst of camera or messaging images can't push a screenshot out of the newest 50.
        val (selection, args) = screenshotSelection(sinceSec = 100, untilSec = 190)
        assertEquals("date_added>=? AND date_added<=? AND relative_path LIKE ?", selection)
        assertEquals(listOf("100", "190", "%screenshot%"), args.toList())
        // Newest first, ties by ID, so the LIMIT drops the oldest.
        assertEquals("date_added DESC, _id DESC", SCREENSHOT_SORT)
    }
}
