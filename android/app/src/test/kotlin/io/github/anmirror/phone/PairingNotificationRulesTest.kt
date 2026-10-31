package io.github.anmirror.phone

import io.github.anmirror.feature.mirror.PairingError
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.phone.service.closesPairingNotification
import kotlin.test.Test
import kotlin.test.assertEquals

class PairingNotificationRulesTest {
    @Test
    fun notificationGoesOnceThePairingIsDone() {
        val closes = listOf(
            SetupState.Unpaired, SetupState.Looking, SetupState.Pairing(portKnown = true), SetupState.PairFailed(PairingError.WRONG_CODE),
            SetupState.Connecting, SetupState.Ready, SetupState.ConnectFailed,
        ).associateWith(::closesPairingNotification)
        // Kept while the code is awaited or was wrong (it is posted again with the error); gone once paired.
        assertEquals(
            listOf(false, false, false, false, true, true, true),
            closes.values.toList(),
        )
    }
}
