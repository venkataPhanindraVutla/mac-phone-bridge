package io.github.anmirror.feature.media

import kotlin.test.Test
import kotlin.test.assertEquals

class ArtworkSlotTest {
    private var encodes = 0
    private fun encodeAs(b: Byte): () -> ByteArray? = {
        encodes++
        byteArrayOf(b)
    }

    @Test fun encodesOncePerMetadataChange() {
        val slot = ArtworkSlot()
        assertEquals(listOf<Byte>(1), slot.get(slot.ticket(), encodeAs(1))?.toList())
        assertEquals(listOf<Byte>(1), slot.get(slot.ticket(), encodeAs(2))?.toList())
        assertEquals(1, encodes)
        slot.invalidate()
        assertEquals(listOf<Byte>(3), slot.get(slot.ticket(), encodeAs(3))?.toList())
        assertEquals(2, encodes)
    }

    @Test fun changeDuringAReadIsNotLost() {
        val slot = ArtworkSlot()
        val ticket = slot.ticket() // taken before the metadata is read
        slot.invalidate() // the metadata changes while the old one is encoded
        slot.get(ticket, encodeAs(1))
        // The next look encodes the new metadata instead of reusing the old picture.
        assertEquals(listOf<Byte>(2), slot.get(slot.ticket(), encodeAs(2))?.toList())
        assertEquals(2, encodes)
    }
}
