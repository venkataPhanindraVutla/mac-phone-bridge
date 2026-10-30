package io.github.anmirror.phone

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BackgroundStateTest {
    @Test
    fun exemptPixelShowsNothing() {
        val s = BackgroundState(exempt = true, maker = null, makerStepDone = false)
        assertFalse(s.showsPrompt)
        assertFalse(s.restricted)
    }

    @Test
    fun notExemptPromptsAndReportsRestricted() {
        val s = BackgroundState(exempt = false, maker = null, makerStepDone = false)
        assertTrue(s.showsPrompt)
        assertTrue(s.restricted)
    }

    @Test
    fun exemptVivoPromptsUntilMakerStepDone() {
        val before = BackgroundState(exempt = true, maker = Maker.VIVO, makerStepDone = false)
        val after = BackgroundState(exempt = true, maker = Maker.VIVO, makerStepDone = true)
        assertTrue(before.showsPrompt)
        assertFalse(after.showsPrompt)
        assertFalse(before.restricted)
        assertFalse(after.restricted)
    }
}
