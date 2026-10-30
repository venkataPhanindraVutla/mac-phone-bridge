package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.phone.platform.StoreRead
import io.github.anmirror.phone.service.watchNotPaired
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotPairedWatchTest {
    private val mac = PairedMac("a", "n", "ab", byteArrayOf(1), null, null, 1L)

    @Test
    fun unreadableThreeTimesThenReadableConnectsAndStops() = runBlocking<Unit> {
        var reads = 0
        var kicks = 0
        var connected = false
        var stopped = false
        var unreadableLogs = 0
        watchNotPaired(
            intervalMs = 1,
            read = { if (++reads <= 3) StoreRead.Unreadable("ProviderException") else StoreRead.Macs(listOf(mac)) },
            pairingUnderWay = { false },
            stillNotPaired = { !connected },
            // The manager connects once its own read works, which is the fourth.
            kick = { kicks++; if (reads >= 4) connected = true },
            onUnreadable = { unreadableLogs++ },
            onSelfStop = { stopped = true },
        )
        assertFalse(stopped)
        assertEquals(3, unreadableLogs)
        assertTrue(kicks >= 3)
        assertTrue(connected)
        assertEquals(reads, 4) // no read after the state left NotPaired
    }

    @Test
    fun confirmedEmptyStopsAtOnce() = runBlocking<Unit> {
        var stopped = false
        watchNotPaired(1, { StoreRead.Macs(emptyList()) }, { false }, { true }, { error("no kick") }, {}, { stopped = true })
        assertTrue(stopped)
    }

    @Test
    fun pairingUnderWayNeverStops() = runBlocking<Unit> {
        var n = 0
        var stopped = false
        watchNotPaired(1, { StoreRead.Macs(emptyList()) }, { true }, { n++ < 2 }, {}, {}, { stopped = true })
        assertFalse(stopped)
    }

    @Test
    fun unexpectedReadExceptionIsLoggedAndLoopContinues() = runBlocking<Unit> {
        var reads = 0
        var logs = 0
        var stopped = false
        watchNotPaired(
            intervalMs = 1,
            read = { if (++reads < 3) throw IllegalStateException("boom") else StoreRead.Macs(listOf(mac)) },
            pairingUnderWay = { false },
            stillNotPaired = { reads < 3 },
            kick = {},
            onUnreadable = { logs++ },
            onSelfStop = { stopped = true },
        )
        assertFalse(stopped)
        assertEquals(2, logs)
        assertEquals(3, reads)
    }
}
