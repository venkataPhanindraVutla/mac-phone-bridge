package io.github.anmirror.feature.input

import io.github.anmirror.feature.input.SideSwipe.Result
import kotlin.test.Test
import kotlin.test.assertEquals

class SideSwipeTest {
    @Test fun twoFingersUpFiresOnce() {
        val s = SideSwipe()
        s.down(1, 200f); s.down(2, 210f)
        assertEquals(Result.NONE, s.move(1, 150f)) // the other finger hasn't moved enough yet
        assertEquals(Result.UP, s.move(2, 160f))
        assertEquals(Result.NONE, s.move(1, 100f))
    }

    @Test fun oneFingerNeverFires() {
        val s = SideSwipe()
        s.down(1, 200f)
        assertEquals(Result.NONE, s.move(1, 0f))
    }

    @Test fun downCloses() {
        val s = SideSwipe()
        s.down(1, 100f); s.down(2, 100f)
        s.move(1, 150f)
        assertEquals(Result.DOWN, s.move(2, 150f))
    }

    @Test fun firesAgainAfterAllFingersLift() {
        val s = SideSwipe()
        s.down(1, 200f); s.down(2, 200f); s.move(1, 100f); s.move(2, 100f)
        s.up(1); s.up(2)
        s.down(3, 100f); s.down(4, 100f); s.move(3, 160f)
        assertEquals(Result.DOWN, s.move(4, 160f))
    }

    @Test fun opposingFingersDoNothing() {
        val s = SideSwipe()
        s.down(1, 200f); s.down(2, 200f)
        s.move(1, 100f)
        assertEquals(Result.NONE, s.move(2, 300f))
    }
}
