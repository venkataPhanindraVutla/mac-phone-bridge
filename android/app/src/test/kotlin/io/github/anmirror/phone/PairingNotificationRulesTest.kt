package io.github.anmirror.phone

import io.github.anmirror.feature.mirror.PairingError
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.phone.service.NotificationPermission
import io.github.anmirror.phone.service.PairingInput
import io.github.anmirror.phone.service.closesPairingNotification
import io.github.anmirror.phone.service.pairingInput
import kotlin.test.Test
import kotlin.test.assertEquals

class PairingNotificationRulesTest {
    @Test
    fun inAppFieldsOnlyWhenTheNotificationCantShow() {
        // Allowed: the notification, as before.
        assertEquals(PairingInput.NOTIFICATION, pairingInput(NotificationPermission.GRANTED, appNotificationsOn = true, channelOn = true))
        // Not asked yet: ask first.
        assertEquals(PairingInput.ASK_PERMISSION, pairingInput(NotificationPermission.ASKABLE, appNotificationsOn = true, channelOn = true))
        // Denied (or denied for good): in the app.
        assertEquals(PairingInput.IN_APP, pairingInput(NotificationPermission.DENIED, appNotificationsOn = true, channelOn = true))
        assertEquals(PairingInput.IN_APP, pairingInput(NotificationPermission.DENIED, appNotificationsOn = false, channelOn = false))
        // Granted, but blocked: the "Full mode setup" channel, or all of the app's notifications.
        assertEquals(PairingInput.IN_APP, pairingInput(NotificationPermission.GRANTED, appNotificationsOn = true, channelOn = false))
        assertEquals(PairingInput.IN_APP, pairingInput(NotificationPermission.GRANTED, appNotificationsOn = false, channelOn = true))
    }

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
