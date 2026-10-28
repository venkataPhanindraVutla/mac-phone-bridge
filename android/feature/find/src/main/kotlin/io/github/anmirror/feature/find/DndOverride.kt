package io.github.anmirror.feature.find

import android.app.NotificationManager
import android.content.Context

/** Do Not Disturb state. Changing it needs the user to grant notification-policy access. */
interface DndOverride {
    fun hasAccess(): Boolean
    fun currentFilter(): Int
    fun setFilter(f: Int)
}

class AndroidDndOverride(context: Context) : DndOverride {
    private val nm = context.getSystemService(NotificationManager::class.java)

    override fun hasAccess() = nm.isNotificationPolicyAccessGranted
    override fun currentFilter() = nm.currentInterruptionFilter

    override fun setFilter(f: Int) {
        if (!hasAccess()) return
        try {
            nm.setInterruptionFilter(f)
        } catch (_: SecurityException) {
            // access revoked between the check and the call
        }
    }
}
