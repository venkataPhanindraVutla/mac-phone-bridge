package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.ActionResult

/**
 * One connection's notification handshake. The Mac's first `notify.filter` starts the session
 * (R7); the resync ([resync] = `bridge.onConnected()`, which ends in a `notify.snapshot`) must
 * run only while the notification listener is bound, since an unbound listener has no active
 * list and an empty snapshot would make the Mac drop everything it shows. Called only from the
 * ordered event queue.
 */
class NotifySession(private val resync: suspend () -> Unit) {
    private var filterApplied = false

    fun reset() {
        filterApplied = false
    }

    /** A `notify.filter` was applied. */
    suspend fun filterApplied(listenerBound: Boolean) {
        if (filterApplied) return
        filterApplied = true
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
