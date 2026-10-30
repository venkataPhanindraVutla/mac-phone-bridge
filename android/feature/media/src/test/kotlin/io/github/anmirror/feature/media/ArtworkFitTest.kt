package io.github.anmirror.feature.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ArtworkFitTest {
    @Test fun artworkIsReencodedOrDropped() {
        val sizesKb = mapOf(85 to 150, 70 to 120, 55 to 100, 40 to 90)
        val tried = mutableListOf<Int>()
        val fitted = ArtworkEncoder.fit { q ->
            tried += q
            ByteArray(sizesKb.getValue(q) * 1024)
        }
        assertEquals(90 * 1024, fitted?.size)
        assertEquals(listOf(85, 70, 55, 40), tried)

        assertNull(ArtworkEncoder.fit { ByteArray(ArtworkEncoder.MAX_BYTES + 1) })
        assertEquals(ArtworkEncoder.MAX_BYTES, ArtworkEncoder.fit { ByteArray(ArtworkEncoder.MAX_BYTES) }?.size)
    }
}
