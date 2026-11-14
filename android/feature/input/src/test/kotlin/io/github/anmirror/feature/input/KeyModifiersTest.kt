package io.github.anmirror.feature.input

import io.github.anmirror.feature.input.KeyModifiers.Companion.COMMAND
import io.github.anmirror.feature.input.KeyModifiers.Companion.OPTION
import io.github.anmirror.feature.input.KeyModifiers.Companion.SHIFT
import io.github.anmirror.feature.input.KeyModifiers.State
import kotlin.test.Test
import kotlin.test.assertEquals

class KeyModifiersTest {
    private var now = 0L
    private val m = KeyModifiers(clock = { now })

    private fun tap(bit: Int, at: Long) { now = at; m.down(bit); m.up(bit) }

    @Test fun tapAppliesToTheNextKeyOnly() {
        tap(COMMAND, 0)
        assertEquals(State.LATCHED, m.state(COMMAND))
        assertEquals(COMMAND, m.press(isLetter = true))
        assertEquals(0, m.press(isLetter = true))
        assertEquals(State.OFF, m.state(COMMAND))
    }

    @Test fun doubleTapLocksUntilTappedAgain() {
        tap(SHIFT, 0); tap(SHIFT, 200)
        assertEquals(State.LOCKED, m.state(SHIFT))
        assertEquals(SHIFT, m.press(false)); assertEquals(SHIFT, m.press(false))
        tap(SHIFT, 2_000)
        assertEquals(State.OFF, m.state(SHIFT))
    }

    @Test fun slowSecondTapTurnsItOff() {
        tap(OPTION, 0); tap(OPTION, 1_000)
        assertEquals(State.OFF, m.state(OPTION))
    }

    @Test fun heldWhileTypingAppliesAndDoesNotLatch() {
        m.down(COMMAND)
        assertEquals(COMMAND, m.press(true))
        assertEquals(COMMAND or SHIFT, run { m.down(SHIFT); m.press(true) })
        m.up(SHIFT); m.up(COMMAND)
        assertEquals(State.OFF, m.state(COMMAND))
        assertEquals(0, m.press(true))
    }

    @Test fun capsLockShiftsLettersOnly() {
        m.toggleCapsLock()
        assertEquals(SHIFT, m.press(isLetter = true))
        assertEquals(0, m.press(isLetter = false))
    }

    @Test fun bothShiftKeysHeldThenOneLifted() {
        m.down(SHIFT); m.down(SHIFT); m.up(SHIFT)
        assertEquals(SHIFT, m.press(true))
    }
}
