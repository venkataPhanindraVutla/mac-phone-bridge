package io.github.anmirror.phone.mirror

import kotlin.test.Test
import kotlin.test.assertEquals

/** R56: the delay test screen's marker, four white corner squares each 8% of the short side. */
class DelayTestMarkerTest {
    @Test
    fun cornerSquaresAreEightPercentOfTheShortSide() {
        assertEquals(
            listOf(
                listOf(0, 0, 86, 86),
                listOf(994, 0, 1080, 86),
                listOf(0, 2314, 86, 2400),
                listOf(994, 2314, 1080, 2400),
            ),
            DelayTestMarker.squares(1080, 2400).map { it.toList() },
        )
    }

    @Test
    fun landscapeUsesTheShortSideToo() {
        val squares = DelayTestMarker.squares(2400, 1080)
        assertEquals(listOf(0, 0, 86, 86), squares[0].toList())
        assertEquals(listOf(2314, 994, 2400, 1080), squares[3].toList())
    }

    @Test
    fun emptyViewHasNoSquares() {
        assertEquals(emptyList(), DelayTestMarker.squares(0, 2400))
    }
}
