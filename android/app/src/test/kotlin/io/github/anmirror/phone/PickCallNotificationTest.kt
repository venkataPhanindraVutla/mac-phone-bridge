package io.github.anmirror.phone

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PickCallNotificationTest {
    private val rank = { s: String -> if (s.startsWith("controls")) 2 else if (s.startsWith("ongoing")) 1 else 0 }

    @Test fun prefersTheOneWithCallControls() {
        assertEquals("controls-b", pickCallNotification(listOf("missed", "ongoing", "controls-b", "controls-c"), rank))
    }

    @Test fun thenOngoing() {
        assertEquals("ongoing-x", pickCallNotification(listOf("missed", "ongoing-x"), rank))
    }

    @Test fun elseTheFirst() {
        assertEquals("a", pickCallNotification(listOf("a", "b"), rank))
        assertNull(pickCallNotification(emptyList<String>(), rank))
    }
}
