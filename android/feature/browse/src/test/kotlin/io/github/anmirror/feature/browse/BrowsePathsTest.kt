package io.github.anmirror.feature.browse

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BrowsePathsTest {
    @Test fun dotDotIsBadPath() {
        assertNull(BrowsePaths.segments(".."))
        assertNull(BrowsePaths.segments("a/../b"))
        assertNull(BrowsePaths.segments("a/.."))
        assertNull(BrowsePaths.segments("./a"))
    }

    @Test fun absolutePathIsBadPath() {
        assertNull(BrowsePaths.segments("/"))
        assertNull(BrowsePaths.segments("/etc/passwd"))
    }

    @Test fun emptySegmentIsBadPath() {
        assertNull(BrowsePaths.segments("a//b"))
        assertNull(BrowsePaths.segments("a/"))
    }

    @Test fun nulIsBadPath() {
        assertNull(BrowsePaths.segments("a\u0000b"))
        assertNull(BrowsePaths.segments("dir/\u0000"))
    }

    @Test fun rootIsEmptyPath() {
        assertEquals(emptyList(), BrowsePaths.segments(""))
        assertEquals(listOf("DCIM", "Camera", "a b.jpg"), BrowsePaths.segments("DCIM/Camera/a b.jpg"))
        // Dots that are not a whole segment are ordinary names.
        assertEquals(listOf(".hidden", "...", "a..b"), BrowsePaths.segments(".hidden/.../a..b"))
    }

    @Test fun overlongPathIsBadPath() {
        assertEquals(1, BrowsePaths.segments("a".repeat(4_096))?.size)
        assertNull(BrowsePaths.segments("a".repeat(4_097)))
        // The cap is in UTF-8 bytes: 1,366 three-byte characters are 4,098 bytes.
        assertNull(BrowsePaths.segments("€".repeat(1_366)))
    }
}
