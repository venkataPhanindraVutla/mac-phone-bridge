package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.AvailabilityReason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MediaAvailabilityTest {
    @Test fun partialAccessBlocksScreenshotsButNotPhotos() {
        // Screenshots: with only some photos allowed, new screenshots can't be found.
        val screenshots = mediaFeatureAvailability(MediaAccess.PARTIAL, userOn = true, partialWorks = false)
        assertFalse(screenshots.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_PARTIAL_ACCESS, screenshots.reason)
        // Photos: the picked ones still show, and the Mac says only those are shown.
        val photos = mediaFeatureAvailability(MediaAccess.PARTIAL, userOn = true, partialWorks = true)
        assertTrue(photos.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_PARTIAL_ACCESS, photos.reason)
    }

    @Test fun fullAccessIsEnabledEitherWay() {
        for (partialWorks in listOf(true, false)) {
            val a = mediaFeatureAvailability(MediaAccess.FULL, userOn = true, partialWorks = partialWorks)
            assertTrue(a.enabled)
            assertEquals(AvailabilityReason.AVAILABILITY_REASON_UNSPECIFIED, a.reason)
        }
    }

    @Test fun switchOffComesFirst() {
        for (access in MediaAccess.entries) {
            val a = mediaFeatureAvailability(access, userOn = false, partialWorks = true)
            assertFalse(a.enabled)
            assertEquals(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER, a.reason)
        }
    }

    @Test fun noAccessNeedsPermission() {
        val a = mediaFeatureAvailability(MediaAccess.NONE, userOn = true, partialWorks = true)
        assertFalse(a.enabled)
        assertEquals(AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION, a.reason)
    }
}
