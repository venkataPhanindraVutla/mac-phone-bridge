package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.ActionResult

/**
 * One connection's notification handshake. The Mac's first `notify.filter` starts the session
 * (R7); the resync ([resync] = `bridge.onConnected(macId)`, which ends in a `notify.snapshot`) must
 * run only while the notification listener is bound, since an unbound listener has no active
 * list and an empty snapshot would make the Mac drop everything it shows. Called only from the
 * ordered event queue.
 */
class NotifySession(private val resync: suspend () -> Unit) {
    private var filterApplied = false
    private var appliedOn: Any? = null

    /**
     * Clears the latch. With a [connection] (the one that just connected) it is a no-op when that
     * same connection's filter was already applied: this reset is posted from another thread and
     * can land after the Mac's first filter was handled. A disconnect passes none and always clears.
     */
    fun reset(connection: Any? = null) {
        if (connection != null && filterApplied && appliedOn === connection) return
        filterApplied = false
        appliedOn = null
    }

    /** A `notify.filter` was applied on [connection] (a different one than last time starts afresh). */
    suspend fun filterApplied(listenerBound: Boolean, connection: Any? = null) {
        if (filterApplied && (connection == null || appliedOn === connection)) return
        filterApplied = true
        appliedOn = connection
        if (listenerBound) resync()
    }

    /** The listener bound mid-session: catch the Mac up if the session has started. */
    suspend fun listenerBound() {
        if (filterApplied) resync()
    }

    /** The switch was turned on, or access granted, mid-session. */
    suspend fun enabled(listenerBound: Boolean) {
        if (filterApplied && listenerBound) resync()
    }
}

/**
 * The answer to a `notify.invoke` (every invoke gets exactly one). Null when the Mac does not
 * share notify.v1 (nothing is sent at all). While the feature is not [open] (switch off, no
 * access, listener unbound) the answer is a content-free FAILED, never GONE.
 */
suspend fun answerInvoke(key: String, sharedNotify: Boolean, open: Boolean, viaBridge: suspend () -> ActionResult): ActionResult? =
    when {
        !sharedNotify -> null
        !open -> ActionResult.newBuilder().setKey(key).setOutcome(ActionOutcome.ACTION_OUTCOME_FAILED).build()
        else -> viaBridge()
    }
