package io.github.anmirror.feature.mirror

import com.google.protobuf.ByteString
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.MirrorReason

/** Dials one of the session's bulk links to the connected Mac (SPEC 13), writing its `bulk.hello`. */
fun interface LinkDialer {
    suspend fun dial(role: BulkRole, token: ByteString): BulkStream
}

/** What [MirrorController] drives: a [MirrorSession] on the phone, a fake in tests. */
interface MirrorRun {
    /**
     * Reports STARTING at once, then waits for [awaitPrevious] (the session it replaces must have
     * closed, its pkill included, before this one touches the helper), then RUNNING and the end,
     * through the report it was made with. Returns once all is closed.
     */
    suspend fun run(awaitPrevious: suspend () -> Unit)

    /**
     * Ends the session (idempotent): STOPPED with [reason], nothing when null (a disconnect). With
     * [drainControl] (the Mac's own stop) the Mac's last control bytes reach the helper first.
     */
    fun stop(reason: MirrorReason?, drainControl: Boolean = false)
}

/**
 * Why a Full mode connect failed, for `mirror.state FAILED`: Wireless debugging is off, the
 * pairing is gone, or the peer failed the ADB proof (NEEDS_SETUP, ruling R58: Full mode needs
 * re-enabling); otherwise it could not be reached (ADB_FAILED).
 */
fun connectFailureReason(wirelessDebugging: Boolean?, paired: Boolean, proofFailed: Boolean = false): MirrorReason =
    if (wirelessDebugging == false || !paired || proofFailed) MirrorReason.MIRROR_REASON_NEEDS_SETUP else MirrorReason.MIRROR_REASON_ADB_FAILED
