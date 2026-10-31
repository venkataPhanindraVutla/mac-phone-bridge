package io.github.anmirror.feature.mirror

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals

@OptIn(ExperimentalCoroutinesApi::class)
class AdbIdleCloseTest {
    private val tenMinutes = 10 * 60 * 1000L

    @Test
    fun linkOpenedBySetupClosesAfterTenMinutes() = runTest {
        var closes = 0
        val idle = AdbIdleClose(backgroundScope, close = { closes++ })
        idle.connected()
        advanceTimeBy(tenMinutes - 1)
        assertEquals(0, closes)
        advanceTimeBy(2)
        assertEquals(1, closes)
    }

    @Test
    fun aSessionHoldsTheLinkAndItsEndStartsTheWait() = runTest {
        var closes = 0
        val idle = AdbIdleClose(backgroundScope, close = { closes++ })
        idle.connected()
        advanceTimeBy(5 * 60 * 1000L)
        idle.busy(true)
        advanceTimeBy(tenMinutes * 3)
        assertEquals(0, closes)
        idle.busy(false)
        advanceTimeBy(tenMinutes - 1)
        assertEquals(0, closes)
        advanceTimeBy(2)
        assertEquals(1, closes)
    }

    @Test
    fun disconnectClosesNowOrWhenTheSessionEnds() = runTest {
        var closes = 0
        val idle = AdbIdleClose(backgroundScope, close = { closes++ })
        idle.disconnected()
        assertEquals(1, closes)
        idle.busy(true)
        idle.disconnected()
        assertEquals(1, closes)
        idle.busy(false)
        assertEquals(2, closes)
        advanceTimeBy(tenMinutes * 2)
        assertEquals(2, closes, "nothing left to time out")
    }
}
