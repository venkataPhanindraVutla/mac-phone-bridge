package io.github.anmirror.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.anmirror.phone.AppGraph

/**
 * The proximity beacon's wall-clock alarm (ruling R29): rotates the IDs at the epoch boundary,
 * or retries a failed advertisement, and sets the next alarm. Only this app's PendingIntent
 * reaches it. In a process the alarm itself started, the beacon has nothing running and only
 * cancels the alarm; the service starts it again.
 */
class ProximityAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppGraph.get(context).proximityBeacon.onClockCheck()
    }
}
