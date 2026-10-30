package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION
import io.github.anmirror.protocol.v1.AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP
import io.github.anmirror.protocol.v1.AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.FeatureAvailability
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DndRowTest {
    private fun feature(reason: AvailabilityReason?): FeatureAvailability =
        if (reason == null) FeatureAvailability.newBuilder().setEnabled(true).build()
        else FeatureAvailability.newBuilder().setEnabled(false).setReason(reason).build()

    /** The Mac's availability; a null reason is enabled. */
    private fun mac(sends: AvailabilityReason?, applies: AvailabilityReason?): DndAvailability =
        DndAvailability.newBuilder().setSends(feature(sends)).setApplies(feature(applies)).build()

    @Test fun availabilityFollowsSwitchThenAccess() {
        val off = dndAvailability(userOn = false, policyAccess = true)
        assertFalse(off.sends.enabled)
        assertEquals(AVAILABILITY_REASON_OFF_BY_USER, off.sends.reason)
        assertEquals(AVAILABILITY_REASON_OFF_BY_USER, off.applies.reason)

        val noAccess = dndAvailability(userOn = true, policyAccess = false)
        assertTrue(noAccess.sends.enabled) // reading the filter needs no permission
        assertFalse(noAccess.applies.enabled)
        assertEquals(AVAILABILITY_REASON_NEEDS_PERMISSION, noAccess.applies.reason)

        val all = dndAvailability(userOn = true, policyAccess = true)
        assertTrue(all.sends.enabled)
        assertTrue(all.applies.enabled)
    }

    @Test fun bothDirectionsActive() {
        assertEquals(
            listOf(R.string.home_dnd_phone_to_mac, R.string.home_dnd_mac_to_phone),
            dndRowLines(on = true, access = true, mac = mac(sends = null, applies = null)),
        )
    }

    @Test fun switchOffShowsNoLines() {
        assertEquals(emptyList(), dndRowLines(on = false, access = true, mac = mac(sends = null, applies = null)))
    }

    @Test fun nothingFromTheMacYetShowsNoLines() {
        assertEquals(emptyList(), dndRowLines(on = true, access = true, mac = null))
    }

    @Test fun missingShortcutsAskForThem() {
        assertEquals(
            listOf(R.string.home_dnd_needs_shortcuts, R.string.home_dnd_mac_to_phone),
            dndRowLines(on = true, access = true, mac = mac(sends = null, applies = AVAILABILITY_REASON_NEEDS_SETUP)),
        )
    }

    @Test fun macSettingOffIsSaidOnce() {
        assertEquals(
            listOf(R.string.home_dnd_mac_off),
            dndRowLines(on = true, access = true, mac = mac(sends = AVAILABILITY_REASON_OFF_BY_USER, applies = AVAILABILITY_REASON_OFF_BY_USER)),
        )
    }

    @Test fun macToPhoneNeedsAccess() {
        // Without access the row shows the Allow button instead.
        assertEquals(
            listOf(R.string.home_dnd_phone_to_mac),
            dndRowLines(on = true, access = false, mac = mac(sends = null, applies = null)),
        )
    }

    @Test fun macThatCannotReadFocusShowsOnlyTheOtherDirection() {
        assertEquals(
            listOf(R.string.home_dnd_phone_to_mac),
            dndRowLines(on = true, access = true, mac = mac(sends = AVAILABILITY_REASON_NEEDS_PERMISSION, applies = null)),
        )
    }
}
