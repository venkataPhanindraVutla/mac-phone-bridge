package io.github.anmirror.feature.screenshots

import kotlin.test.Test
import kotlin.test.assertEquals

class ChangeDebounceTest {
    private var now = 10_000L
    private val debounce = ChangeDebounce(quietMs = 500, maxWaitMs = 1_500) { now }

    @Test fun quietChangeWaits500ms() {
        assertEquals(500, debounce.onChange())
        now += 500
        debounce.fired()
        // The next burst starts afresh.
        now += 5_000
        assertEquals(500, debounce.onChange())
    }

    @Test fun busyMediaStoreStillLooksEvery1500ms() {
        // A syncing app changes MediaStore every 200 ms: the look still comes 1.5 s after the first change.
        val waits = (0 until 8).map { i ->
            if (i > 0) now += 200
            debounce.onChange()
        }
        assertEquals(listOf(500L, 500L, 500L, 500L, 500L, 500L, 300L, 100L), waits)
        now += 100
        debounce.fired()
        assertEquals(500, debounce.onChange())
        // Past the deadline already (a late timer): look at once.
        now += 2_000
        assertEquals(0, debounce.onChange())
    }
}
