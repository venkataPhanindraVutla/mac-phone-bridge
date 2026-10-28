package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.AvailabilityReason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NotificationAccessTest {
    @Test
    fun availabilityMapsGrantAndSwitch() {
        val on = featureAvailability(granted = true, userOn = true)
        assertTrue(on.enabled)

        val noAccess = featureAvailability(granted = false, userOn = true)
        assertEquals(false, noAccess.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION, noAccess.reason)

        val off = featureAvailability(granted = true, userOn = false)
        assertEquals(false, off.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER, off.reason)

        // The user has not asked for the feature: not their problem yet.
        assertEquals(
            AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER,
            featureAvailability(granted = false, userOn = false).reason,
        )
    }
}
