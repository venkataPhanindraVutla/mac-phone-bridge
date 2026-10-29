package io.github.anmirror.phone

import io.github.anmirror.phone.service.failureReasonRes
import io.github.anmirror.phone.service.failureTitleRes
import io.github.anmirror.phone.service.ongoingTitleRes
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.transfer.Direction
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TransferNotifierTextTest {
    private val reasons = setOf(
        R.string.transfer_reason_no_space_mac,
        R.string.transfer_reason_no_space_phone,
        R.string.transfer_reason_connection_lost,
        R.string.transfer_reason_damaged,
        R.string.transfer_reason_cancelled,
        R.string.transfer_reason_no_answer,
        R.string.transfer_reason_read_failed,
        R.string.transfer_reason_save_failed,
        R.string.transfer_reason_not_found,
        R.string.transfer_reason_refused,
        R.string.transfer_reason_refused_here,
    )

    @Test
    fun failureReasonsMapToCopy() {
        // Every error, also ones a newer Mac may send (UNRECOGNIZED) and none at all, has a reason line.
        for (direction in Direction.entries) {
            for (error in TransferError.entries + listOf<TransferError?>(null)) {
                assertTrue(failureReasonRes(error, direction) in reasons, "$error $direction")
            }
        }
        // Space is about the receiving side.
        assertEquals(R.string.transfer_reason_no_space_mac, failureReasonRes(TransferError.TRANSFER_ERROR_NO_SPACE, Direction.SEND))
        assertEquals(R.string.transfer_reason_no_space_phone, failureReasonRes(TransferError.TRANSFER_ERROR_NO_SPACE, Direction.RECEIVE))
        assertEquals(R.string.transfer_reason_connection_lost, failureReasonRes(TransferError.TRANSFER_ERROR_INTERRUPTED, Direction.SEND))
        assertEquals(R.string.transfer_reason_damaged, failureReasonRes(TransferError.TRANSFER_ERROR_HASH_MISMATCH, Direction.RECEIVE))
        assertEquals(R.string.transfer_reason_cancelled, failureReasonRes(TransferError.TRANSFER_ERROR_CANCELLED, Direction.SEND))
        assertEquals(R.string.transfer_reason_no_answer, failureReasonRes(TransferError.TRANSFER_ERROR_TIMED_OUT, Direction.SEND))
        assertEquals(R.string.transfer_reason_read_failed, failureReasonRes(TransferError.TRANSFER_ERROR_IO, Direction.SEND))
        assertEquals(R.string.transfer_reason_save_failed, failureReasonRes(TransferError.TRANSFER_ERROR_IO, Direction.RECEIVE))
        assertEquals(R.string.transfer_reason_refused, failureReasonRes(TransferError.TRANSFER_ERROR_DISABLED, Direction.SEND))
        assertEquals(R.string.transfer_reason_refused_here, failureReasonRes(TransferError.TRANSFER_ERROR_BAD_TARGET, Direction.RECEIVE))
        assertEquals(R.string.transfer_reason_connection_lost, failureReasonRes(TransferError.TRANSFER_ERROR_UNSPECIFIED, Direction.RECEIVE))
    }

    @Test
    fun titlesFollowTheDirection() {
        assertEquals(R.string.transfer_sending, ongoingTitleRes(Direction.SEND))
        assertEquals(R.string.transfer_receiving, ongoingTitleRes(Direction.RECEIVE))
        assertEquals(R.string.transfer_send_failed, failureTitleRes(Direction.SEND))
        assertEquals(R.string.transfer_receive_failed, failureTitleRes(Direction.RECEIVE))
    }
}
