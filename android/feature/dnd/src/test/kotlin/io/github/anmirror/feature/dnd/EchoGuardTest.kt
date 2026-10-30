package io.github.anmirror.feature.dnd

import kotlin.test.Test
import kotlin.test.assertEquals

class EchoGuardTest {
    @Test fun nothingAppliedIsUser() {
        assertEquals(Echo.USER, EchoGuard().classify(true, 1_000))
    }

    @Test fun matchWithinWindowIsSuppressed() {
        val guard = EchoGuard()
        guard.applied(true, 1_000)
        assertEquals(Echo.SUPPRESS, guard.classify(true, 4_000))
    }

    @Test fun echoWindowExpiresAfter10s() {
        val inside = EchoGuard().apply { applied(true, 0) }
        assertEquals(Echo.SUPPRESS, inside.classify(true, 9_999))
        val after = EchoGuard().apply { applied(true, 0) }
        assertEquals(Echo.SYNC, after.classify(true, 10_000))
    }

    @Test fun theOtherStateIsUserEvenInsideTheWindow() {
        val guard = EchoGuard()
        guard.applied(true, 0)
        assertEquals(Echo.USER, guard.classify(false, 2_000))
    }

    @Test fun aTransitionInBetweenEndsTheMatch() {
        val guard = EchoGuard()
        guard.applied(true, 0)
        assertEquals(Echo.USER, guard.classify(false, 20_000))
        assertEquals(Echo.USER, guard.classify(true, 30_000))
    }

    @Test fun theEchoIsConsumedOnce() {
        val guard = EchoGuard()
        guard.applied(true, 0)
        assertEquals(Echo.SYNC, guard.classify(true, 11_000))
        assertEquals(Echo.USER, guard.classify(true, 50_000))
    }

    @Test fun theLatestApplyCounts() {
        val guard = EchoGuard()
        guard.applied(true, 0)
        guard.applied(false, 1_000)
        assertEquals(Echo.SUPPRESS, guard.classify(false, 2_000))
    }

    @Test fun theWindowIsConfigurable() {
        val guard = EchoGuard(windowMs = 1_000)
        guard.applied(true, 0)
        assertEquals(Echo.SYNC, guard.classify(true, 1_000))
    }
}
