package io.github.anmirror.phone

import io.github.anmirror.connection.InMemoryPairedMacStore
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.phone.platform.StoreRead
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** M3: while the store cannot be read, the UI shows no list (a blank frame), not onboarding. */
class ObservablePairedMacStoreTest {
    private val mac = PairedMac("a", "Mac", "a", ByteArray(32), null, null, 1)

    @Test
    fun unreadableStoreKeepsTheListUnknown() = runTest {
        var read: StoreRead = StoreRead.Unreadable("ProviderException")
        val store = ObservablePairedMacStore(InMemoryPairedMacStore(listOf(mac))) { read }
        assertEquals(emptyList(), store.all(), "the manager still reads none (0.1 meaning)")
        assertNull(store.macs.value, "but the UI does not show onboarding")

        read = StoreRead.Macs(listOf(mac))
        assertEquals(listOf(mac), store.all())
        assertEquals(listOf(mac), store.macs.value)
    }

    @Test
    fun permanentlyUnreadableStoreReadsAsNone() = runTest {
        val store = ObservablePairedMacStore(InMemoryPairedMacStore()) { StoreRead.Unreadable("AEADBadTagException", permanent = true) }
        assertEquals(emptyList(), store.all())
        assertEquals(emptyList(), store.macs.value, "lost for good: offer pairing again")
    }
}
