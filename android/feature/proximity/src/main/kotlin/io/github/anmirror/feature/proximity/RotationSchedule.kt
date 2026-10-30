package io.github.anmirror.feature.proximity

import io.github.anmirror.protocol.PairingCrypto

private const val EPOCH_MS = 900_000L

/** Milliseconds from [nowMs] (Unix time) to the start of the next 15-minute epoch (SPEC 6); never 0. */
fun msUntilNextEpoch(nowMs: Long): Long = EPOCH_MS - Math.floorMod(nowMs, EPOCH_MS)

/**
 * When the beacon wakes (ruling R29). Everything is wall-clock time, recomputed from the clock on
 * each wake: a late alarm, or a clock set back or forward, lands on the epoch of now.
 */
object RotationSchedule {
    /** The rotation waits this long past the boundary, so the new epoch is surely under way. */
    const val AFTER_BOUNDARY_MS = 1_000L

    /** The epoch of [nowMs] (Unix ms). */
    fun epochAt(nowMs: Long): Long = PairingCrypto.epochOf(Math.floorDiv(nowMs, 1000L))

    /** 1 s past the next boundary after [nowMs]. */
    fun nextRotationAt(nowMs: Long): Long = nowMs + msUntilNextEpoch(nowMs) + AFTER_BOUNDARY_MS

    /** The earlier of the next rotation and the earliest pending retry. */
    fun nextWake(nowMs: Long, retries: Collection<Long>): Long =
        minOf(nextRotationAt(nowMs), retries.minOrNull() ?: Long.MAX_VALUE)
}

/** How long a failed advertisement waits before its next try (ruling R30). */
object RetryBackoff {
    /** The longest wait; a retry further away than this (the clock went back) is due now. */
    const val MAX_MS = 300_000L

    /** 5 s, 15 s, 60 s, then every 5 minutes. [attempt] counts the failures before this one. */
    fun delayMs(attempt: Int): Long = when (attempt) {
        0 -> 5_000L
        1 -> 15_000L
        2 -> 60_000L
        else -> MAX_MS
    }
}
