package io.github.anmirror.feature.dnd

import android.app.NotificationManager.INTERRUPTION_FILTER_ALARMS
import android.app.NotificationManager.INTERRUPTION_FILTER_ALL
import android.app.NotificationManager.INTERRUPTION_FILTER_NONE
import android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY

/** What an interruption filter means for sync (SPEC 21): "on" is anything but ALL. */
object DndRules {
    /**
     * ALL is off; PRIORITY, ALARMS and NONE are on; UNKNOWN (or anything else) is null, and is
     * never a transition. So Find my phone's NONE to ALARMS swap changes nothing here.
     */
    fun isOn(filter: Int): Boolean? = when (filter) {
        INTERRUPTION_FILTER_ALL -> false
        INTERRUPTION_FILTER_PRIORITY, INTERRUPTION_FILTER_ALARMS, INTERRUPTION_FILTER_NONE -> true
        else -> null
    }
}
