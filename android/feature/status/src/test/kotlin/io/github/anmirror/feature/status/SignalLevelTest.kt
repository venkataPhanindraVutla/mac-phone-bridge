package io.github.anmirror.feature.status

import kotlin.test.Test
import kotlin.test.assertEquals

class SignalLevelTest {
    private val ok: CellView = CellView(valid = true)
    private val bad: CellView = CellView(valid = false)

    @Test fun noSim() = assertEquals(-1, signalLevel(false, false, SignalStrengthView(3, listOf(ok))))
    @Test fun airplane() = assertEquals(-1, signalLevel(true, true, SignalStrengthView(3, listOf(ok))))
    @Test fun noStrength() = assertEquals(-1, signalLevel(true, false, null))
    @Test fun emptyCellList() = assertEquals(-1, signalLevel(true, false, SignalStrengthView(0, emptyList())))
    @Test fun allInvalid() = assertEquals(-1, signalLevel(true, false, SignalStrengthView(0, listOf(bad, bad))))
    @Test fun realZero() = assertEquals(0, signalLevel(true, false, SignalStrengthView(0, listOf(ok))))
    @Test fun realThree() = assertEquals(3, signalLevel(true, false, SignalStrengthView(3, listOf(bad, ok))))
}
