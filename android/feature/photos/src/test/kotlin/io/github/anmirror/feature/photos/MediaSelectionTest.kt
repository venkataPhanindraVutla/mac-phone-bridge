package io.github.anmirror.feature.photos

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class MediaSelectionTest {
    @Test
    fun selectsImagesAndVideosOnly() {
        val (selection, args) = recentSelection(0)
        assertEquals("media_type IN (1,3)", selection)
        assertEquals(0, args.size)
    }

    @Test
    fun beforeMsPagesByDateAdded() {
        val (selection, args) = recentSelection(1_700_000_123_456)
        assertEquals("media_type IN (1,3) AND date_added<?", selection)
        assertContentEquals(arrayOf("1700000123"), args)
    }

    @Test
    fun everySortColumnIsDescending() {
        assertEquals("date_added DESC, _id DESC", RECENT_SORT)
    }

    @Test
    fun dateTakenFallsBackToDateAdded() {
        assertEquals(1_600_000_000_123, dateTakenMs(1_600_000_000_123, 1_700_000_000))
        assertEquals(1_700_000_000_000, dateTakenMs(null, 1_700_000_000))
        assertEquals(1_700_000_000_000, dateTakenMs(0, 1_700_000_000))
    }
}
