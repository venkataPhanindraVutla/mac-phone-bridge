package io.github.anmirror.phone

import io.github.anmirror.phone.service.BootDecision
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BootDecisionTest {
    @Test
    fun bootReceiverStartsServiceOnlyWhenPaired() {
        assertFalse(BootDecision.shouldStartService(0))
        assertTrue(BootDecision.shouldStartService(1))
        assertTrue(BootDecision.shouldStartService(3))
    }

    @Test
    fun unreadableStoreNeverStopsService() = assertFalse(BootDecision.shouldSelfStop(false, confirmedEmpty = false))

    @Test
    fun pairingUnderWayNeverStops() = assertFalse(BootDecision.shouldSelfStop(true, true))

    @Test
    fun confirmedEmptyStops() = assertTrue(BootDecision.shouldSelfStop(false, true))

    @Test
    fun appOpenStartsServiceWheneverPaired() {
        assertTrue(BootDecision.shouldStartService(1))
        assertFalse(BootDecision.shouldStartService(0))
    }
}
