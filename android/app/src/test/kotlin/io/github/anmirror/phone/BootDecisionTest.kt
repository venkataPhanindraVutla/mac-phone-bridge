package io.github.anmirror.phone

import io.github.anmirror.phone.service.BootDecision
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BootDecisionTest {
    @Test
    fun unreadableStoreStartsService() = assertTrue(BootDecision.shouldStart(confirmedEmpty = false))

    @Test
    fun storeConfirmedEmptyDoesNotStart() = assertFalse(BootDecision.shouldStart(confirmedEmpty = true))

    @Test
    fun unreadableStoreNeverStopsService() = assertFalse(BootDecision.shouldSelfStop(false, confirmedEmpty = false))

    @Test
    fun pairingUnderWayNeverStops() = assertFalse(BootDecision.shouldSelfStop(true, true))

    @Test
    fun confirmedEmptyStops() = assertTrue(BootDecision.shouldSelfStop(false, true))
}
