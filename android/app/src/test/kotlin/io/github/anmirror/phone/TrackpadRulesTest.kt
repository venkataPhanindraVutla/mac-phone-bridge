package io.github.anmirror.phone

import android.view.KeyEvent
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.remote.volumeKeySlide
import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.FeatureAvailability
import io.github.anmirror.protocol.v1.RemoteKey
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TrackpadRulesTest {
    private val mac = PairedMac("ab", "Mac", "ab", ByteArray(32), "10.0.0.5", 4000, 0)
    private val session = PhoneConnectionState.Connected(mac, setOf("status.v1", "input.v1"))
    private val enabled = FeatureAvailability.newBuilder().setEnabled(true).build()

    private fun off(reason: AvailabilityReason) = FeatureAvailability.newBuilder().setEnabled(false).setReason(reason).build()

    @Test fun openOnlyWhenTheMacAllowsItInThisSession() {
        assertTrue(inputOpen(session, MacInputAvailability(session, enabled)))
        assertFalse(inputOpen(session, null)) // nothing heard yet
        assertFalse(inputOpen(session, MacInputAvailability(session, off(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER))))
        // An equal but new session: what the last one's Mac said no longer counts.
        val next = session.copy()
        assertFalse(inputOpen(next, MacInputAvailability(session, enabled)))
        val notShared = PhoneConnectionState.Connected(mac, setOf("status.v1"))
        assertFalse(inputOpen(notShared, MacInputAvailability(notShared, enabled)))
        assertFalse(inputOpen(PhoneConnectionState.Searching, MacInputAvailability(session, enabled)))
    }

    @Test fun lineSaysWhatToTurnOnOnTheMac() {
        assertEquals(R.string.clipboard_not_connected, trackpadLine(PhoneConnectionState.Searching, null))
        assertEquals(
            R.string.trackpad_mac_off,
            trackpadLine(session, MacInputAvailability(session, off(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER))),
        )
        assertEquals(
            R.string.trackpad_mac_needs_accessibility,
            trackpadLine(session, MacInputAvailability(session, off(AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION))),
        )
        assertNull(trackpadLine(session, MacInputAvailability(session, enabled)))
        assertNull(trackpadLine(session, null))
        assertNull(trackpadLine(PhoneConnectionState.Connected(mac, setOf("status.v1")), null))
    }

    @Test fun homeRowOnlyWhileConnectedToAMacWithTheTrackpad() {
        assertTrue(inputShared(session))
        assertFalse(inputShared(PhoneConnectionState.Connected(mac, setOf("status.v1"))))
        assertFalse(inputShared(PhoneConnectionState.Searching))
    }

    @Test fun volumeKeysChangeSlidesOnlyOnTheRemoteTabWithTheSwitchOn() {
        assertEquals(RemoteKey.REMOTE_KEY_NEXT_SLIDE, volumeKeySlide(KeyEvent.KEYCODE_VOLUME_UP, remoteShown = true, switchOn = true))
        assertEquals(RemoteKey.REMOTE_KEY_PREV_SLIDE, volumeKeySlide(KeyEvent.KEYCODE_VOLUME_DOWN, remoteShown = true, switchOn = true))
        assertNull(volumeKeySlide(KeyEvent.KEYCODE_VOLUME_UP, remoteShown = false, switchOn = true))
        assertNull(volumeKeySlide(KeyEvent.KEYCODE_VOLUME_DOWN, remoteShown = true, switchOn = false))
        assertNull(volumeKeySlide(KeyEvent.KEYCODE_VOLUME_MUTE, remoteShown = true, switchOn = true))
    }
}
