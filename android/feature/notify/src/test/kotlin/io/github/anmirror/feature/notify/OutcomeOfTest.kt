package io.github.anmirror.feature.notify

import android.app.PendingIntent
import io.github.anmirror.protocol.v1.ActionOutcome
import kotlin.test.Test
import kotlin.test.assertEquals

class OutcomeOfTest {
    @Test
    fun sendSucceedsIsOk() = assertEquals(ActionOutcome.ACTION_OUTCOME_OK, outcomeOf { })

    @Test
    fun canceledPendingIntentIsGone() =
        assertEquals(ActionOutcome.ACTION_OUTCOME_GONE, outcomeOf { throw PendingIntent.CanceledException() })

    @Test
    fun otherFailureIsFailed() =
        assertEquals(ActionOutcome.ACTION_OUTCOME_FAILED, outcomeOf { throw IllegalStateException("x") })
}
