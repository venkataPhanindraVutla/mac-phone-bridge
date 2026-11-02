package io.github.anmirror.phone

import io.github.anmirror.feature.mirror.PairingError
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.phone.service.NotificationPermission
import io.github.anmirror.phone.service.PairingInput
import io.github.anmirror.phone.service.closesPairingNotification
import io.github.anmirror.phone.service.holdReplyBroadcast
import io.github.anmirror.phone.service.pairingInput
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
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

    @Test
    fun replyBroadcastIsLetGoOnceConnectingStarts() = runTest {
        // Android delivers one broadcast at a time to the app: held any longer, the reply would
        // keep the ADB proof's own broadcast (ruling R58) waiting until the proof timed out.
        val state = MutableStateFlow<SetupState>(SetupState.Pairing(portKnown = true))
        val work = launch { CompletableDeferred<Unit>().await() }
        val held = async { holdReplyBroadcast(work, state, holdMs = 50_000) }
        runCurrent()
        assertFalse(held.isCompleted, "held while pairing")
        state.value = SetupState.Connecting
        runCurrent()
        assertTrue(held.isCompleted, "let go once connecting, though the work goes on")
        work.cancel()
    }

    @Test
    fun replyBroadcastIsLetGoWhenTheWorkEndsOrTheHoldRunsOut() = runTest {
        val state = MutableStateFlow<SetupState>(SetupState.Pairing(portKnown = true))
        val quick = launch { }
        holdReplyBroadcast(quick, state, holdMs = 50_000)
        val stuck = launch { CompletableDeferred<Unit>().await() }
        val held = async { holdReplyBroadcast(stuck, state, holdMs = 50_000) }
        advanceTimeBy(50_001)
        assertTrue(held.isCompleted)
        stuck.cancel()
    }
}
