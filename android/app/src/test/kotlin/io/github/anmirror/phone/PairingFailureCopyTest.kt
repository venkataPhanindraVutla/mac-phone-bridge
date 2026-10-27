package io.github.anmirror.phone

import io.github.anmirror.connection.PairingFailure
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class PairingFailureCopyTest {
    @Test
    fun everyPairingFailureHasCopy() {
        val ids = PairingFailure.entries.map { it.messageRes() }
        ids.forEach { assertNotEquals(0, it, "a PairingFailure has no copy") }
        assertEquals(ids.size, ids.toSet().size, "two PairingFailures share copy: $ids")
    }
}
