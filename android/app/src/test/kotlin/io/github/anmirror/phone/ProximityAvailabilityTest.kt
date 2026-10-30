package io.github.anmirror.phone

import io.github.anmirror.feature.proximity.AdvertiserState
import io.github.anmirror.protocol.v1.AvailabilityReason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ProximityAvailabilityTest {
    @Test fun proximityAvailabilityMapping() {
        val off = proximityAvailability(userOn = false, granted = true, adapter = AdvertiserState.READY)
        assertFalse(off.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER, off.reason)
        // The switch comes first, also when the adapter can't advertise.
        assertEquals(
            AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER,
            proximityAvailability(userOn = false, granted = false, adapter = AdvertiserState.UNSUPPORTED).reason,
        )

        val noPermission = proximityAvailability(userOn = true, granted = false, adapter = AdvertiserState.READY)
        assertFalse(noPermission.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION, noPermission.reason)

        for (adapter in listOf(AdvertiserState.BLUETOOTH_OFF, AdvertiserState.UNSUPPORTED)) {
            val unavailable = proximityAvailability(userOn = true, granted = true, adapter = adapter)
            assertFalse(unavailable.enabled)
            assertEquals(AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE, unavailable.reason)
        }

        assertTrue(proximityAvailability(userOn = true, granted = true, adapter = AdvertiserState.READY).enabled)
    }

    @Test fun proximityRowLines() {
        assertNull(proximityRowLine(on = false, granted = false, adapter = AdvertiserState.BLUETOOTH_OFF))
        assertEquals(R.string.home_proximity_needs_permission, proximityRowLine(on = true, granted = false, adapter = AdvertiserState.BLUETOOTH_OFF))
        assertEquals(R.string.home_proximity_bluetooth_off, proximityRowLine(on = true, granted = true, adapter = AdvertiserState.BLUETOOTH_OFF))
        assertEquals(R.string.home_proximity_unsupported, proximityRowLine(on = true, granted = true, adapter = AdvertiserState.UNSUPPORTED))
        assertNull(proximityRowLine(on = true, granted = true, adapter = AdvertiserState.READY))
    }
}
