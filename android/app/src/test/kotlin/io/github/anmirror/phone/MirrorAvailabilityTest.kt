package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.FeatureAvailability
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MirrorAvailabilityTest {
    private fun off(reason: AvailabilityReason) = FeatureAvailability.newBuilder().setEnabled(false).setReason(reason).build()

    private fun avail(
        sdk: Int = 34,
        userOn: Boolean = true,
        paired: Boolean = true,
        wirelessDebugging: Boolean? = true,
        lastConnectFailed: Boolean = false,
    ) = mirrorAvailability(sdk, userOn, paired, wirelessDebugging, lastConnectFailed)

    @Test
    fun android10IsUnavailable() {
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE), avail(sdk = 29))
        // Before the switch: an Android 10 phone can never mirror.
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE), avail(sdk = 29, userOn = false, paired = false))
        assertTrue(avail(sdk = 30).enabled)
    }

    @Test
    fun switchOffIsOffByUser() {
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER), avail(userOn = false))
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER), avail(userOn = false, paired = false, wirelessDebugging = false))
    }

    @Test
    fun unpairedNeedsSetup() {
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP), avail(paired = false))
    }

    @Test
    fun wirelessDebuggingOffNeedsSetup() {
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP), avail(wirelessDebugging = false))
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP), avail(lastConnectFailed = true))
    }

    @Test
    fun unreadableSettingDoesNotBlock() {
        assertEquals(FeatureAvailability.newBuilder().setEnabled(true).build(), avail(wirelessDebugging = null))
        assertEquals(off(AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP), avail(wirelessDebugging = null, lastConnectFailed = true))
    }

    @Test
    fun allSetIsEnabled() {
        assertEquals(FeatureAvailability.newBuilder().setEnabled(true).build(), avail())
    }

    @Test
    fun reconnectOnlyWhenOnPairedAndFailed() {
        // A process that starts (or a setting that flips) with Wireless debugging on after a failed connect.
        assertEquals(true, fullModeNeedsReconnect(wirelessDebugging = true, paired = true, lastConnectFailed = true))
        assertEquals(false, fullModeNeedsReconnect(wirelessDebugging = true, paired = true, lastConnectFailed = false)) // ready already
        assertEquals(false, fullModeNeedsReconnect(wirelessDebugging = true, paired = false, lastConnectFailed = true)) // needs pairing
        assertEquals(false, fullModeNeedsReconnect(wirelessDebugging = false, paired = true, lastConnectFailed = true))
        assertEquals(false, fullModeNeedsReconnect(wirelessDebugging = null, paired = true, lastConnectFailed = true)) // unreadable: no guess
    }

    @Test
    fun rowLineFollowsTheSetup() {
        fun line(sdk: Int = 34, on: Boolean = true, paired: Boolean = true, wd: Boolean? = true, failed: Boolean = false) =
            mirrorRowLine(sdk, on, paired, wd, failed)
        assertEquals(MirrorRowLine.NEEDS_ANDROID_11, line(sdk = 29, on = false))
        assertEquals(null, line(on = false))
        assertEquals(MirrorRowLine.NEEDS_SETUP, line(paired = false))
        assertEquals(MirrorRowLine.WIRELESS_DEBUGGING_OFF, line(wd = false))
        assertEquals(MirrorRowLine.WIRELESS_DEBUGGING_OFF, line(failed = true))
        assertEquals(MirrorRowLine.READY, line())
        assertEquals(MirrorRowLine.READY, line(wd = null))
    }
}
