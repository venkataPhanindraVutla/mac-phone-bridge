package io.github.anmirror.feature.dnd

import android.app.NotificationManager.INTERRUPTION_FILTER_ALARMS
import android.app.NotificationManager.INTERRUPTION_FILTER_ALL
import android.app.NotificationManager.INTERRUPTION_FILTER_NONE
import android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY
import android.app.NotificationManager.INTERRUPTION_FILTER_UNKNOWN
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DndRulesTest {
    @Test fun filterMapping() {
        assertEquals(false, DndRules.isOn(INTERRUPTION_FILTER_ALL))
        assertEquals(true, DndRules.isOn(INTERRUPTION_FILTER_PRIORITY))
        assertEquals(true, DndRules.isOn(INTERRUPTION_FILTER_ALARMS))
        assertEquals(true, DndRules.isOn(INTERRUPTION_FILTER_NONE))
        assertNull(DndRules.isOn(INTERRUPTION_FILTER_UNKNOWN))
    }

    @Test fun anUnlistedFilterIsUnknown() {
        assertNull(DndRules.isOn(42))
    }
}
