package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac
import kotlin.test.Test
import kotlin.test.assertEquals

class AdvertisedMacsTest {
    private fun mac(id: String, lastConnectedAt: Long) = PairedMac(
        id = id, name = "Mac $id", fingerprintHex = "00", discoveryKey = ByteArray(32),
        lastHost = null, lastPort = null, lastConnectedAt = lastConnectedAt,
    )

    private fun ids(macs: List<PairedMac>) = macs.map { it.id }

    @Test fun connectedMacWinsElseMostRecent() {
        val old = mac("old", 10)
        val recent = mac("recent", 20)
        assertEquals(listOf("old", "recent"), ids(AdvertisedMacs.pick(listOf(old, recent), connected = old)))
        assertEquals(listOf("recent", "old"), ids(AdvertisedMacs.pick(listOf(old, recent), connected = null)))
        assertEquals(emptyList(), AdvertisedMacs.pick(emptyList(), connected = null))
    }

    @Test fun capsAtThreeKeepingTheConnectedOne() {
        val macs = listOf(mac("a", 1), mac("b", 4), mac("c", 3), mac("d", 2))
        assertEquals(listOf("b", "c", "d"), ids(AdvertisedMacs.pick(macs, connected = null)))
        // The least recent Mac is advertised when it is the connected one; the rest follow by recency.
        assertEquals(listOf("a", "b", "c"), ids(AdvertisedMacs.pick(macs, connected = macs[0])))
    }

    @Test fun connectedMacIsListedOnce() {
        val a = mac("a", 1)
        // The connected copy may carry a newer connect time than the stored one.
        assertEquals(listOf("a"), ids(AdvertisedMacs.pick(listOf(a), connected = a.copy(lastConnectedAt = 99))))
    }
}
