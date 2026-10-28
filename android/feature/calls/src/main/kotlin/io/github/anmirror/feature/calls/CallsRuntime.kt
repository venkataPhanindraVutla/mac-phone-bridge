package io.github.anmirror.feature.calls

/**
 * Owns the [CallController] for as long as the feature is on and READ_PHONE_STATE is granted. A
 * reconnect, or any other change that is not those two, never rebuilds it, so a call in progress
 * keeps its call_id. Call from one thread (the service's main scope).
 */
class CallsRuntime(private val create: () -> CallController) {
    @Volatile var controller: CallController? = null
        private set

    /** Applies the switch and the permission; returns true when a new controller was just started. */
    fun update(on: Boolean, granted: Boolean): Boolean {
        val wanted = on && granted
        if (!wanted) {
            stop()
            return false
        }
        if (controller != null) return false
        controller = create().also { it.start() }
        return true
    }

    /** A permission that changes how the source reports (READ_CALL_LOG) flipped: same controller, new listener. */
    fun restartSource() {
        controller?.restartSource()
    }

    fun stop() {
        controller?.stop()
        controller = null
    }
}
