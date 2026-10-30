package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AdvertisedMacTest {
    private fun mac(id: String, lastConnectedAt: Long) = PairedMac(
        id = id, name = "Mac $id", fingerprintHex = "00", discoveryKey = ByteArray(32),
        lastHost = null, lastPort = null, lastConnectedAt = lastConnectedAt,
    )

    @Test fun connectedMacWinsElseMostRecent() {
        val old = mac("old", 10)
        val recent = mac("recent", 20)
        assertEquals(old, AdvertisedMac.pick(listOf(old, recent), connected = old))
        assertEquals(recent, AdvertisedMac.pick(listOf(old, recent), connected = null))
        assertEquals(recent, AdvertisedMac.pick(listOf(recent, old), connected = null))
        assertNull(AdvertisedMac.pick(emptyList(), connected = null))
    }
}
