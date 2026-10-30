package io.github.anmirror.feature.input

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PointerCancelTest {
    private fun p(pressed: Boolean, previousPressed: Boolean, consumed: Boolean) = PointerSnapshot(pressed, previousPressed, consumed)

    @Test fun cancelIsEveryPointerUpWithAJustLiftedOneConsumed() {
        // ACTION_CANCEL: Compose lifts every pointer and hands the changes over already consumed.
        assertTrue(isPointerCancel(release = true, listOf(p(pressed = false, previousPressed = true, consumed = true))))
        assertTrue(
            isPointerCancel(
                release = true,
                listOf(p(pressed = false, previousPressed = true, consumed = true), p(pressed = false, previousPressed = true, consumed = true)),
            ),
        )
    }

    @Test fun plainLiftIsNotACancel() {
        assertFalse(isPointerCancel(release = true, listOf(p(pressed = false, previousPressed = true, consumed = false))))
        // Two fingers lifting together.
        assertFalse(
            isPointerCancel(
                release = true,
                listOf(p(pressed = false, previousPressed = true, consumed = false), p(pressed = false, previousPressed = true, consumed = false)),
            ),
        )
        // One finger up, the other still down: a lift.
        assertFalse(
            isPointerCancel(
                release = true,
                listOf(p(pressed = false, previousPressed = true, consumed = true), p(pressed = true, previousPressed = true, consumed = false)),
            ),
        )
        // Only a pointer that was already up (consumed by this surface last frame): nothing was cancelled.
        assertFalse(isPointerCancel(release = true, listOf(p(pressed = false, previousPressed = false, consumed = true))))
        // Not a release, or no changes.
        assertFalse(isPointerCancel(release = false, listOf(p(pressed = false, previousPressed = true, consumed = true))))
        assertFalse(isPointerCancel(release = true, emptyList()))
    }
}
