package io.github.anmirror.feature.status

/** One cell's reading, reduced to what the mapping needs. */
data class CellView(val valid: Boolean)

/** [SignalStrength][android.telephony.SignalStrength] reduced to a JVM-testable shape. */
data class SignalStrengthView(val level: Int, val cells: List<CellView>)

/**
 * Signal level for the Mac: 0..4, or -1 for unknown / no service (no SIM, airplane mode, no
 * cell readings, or only invalid ones). A real level 0 stays 0 ("no bars").
 */
fun signalLevel(simReady: Boolean, airplane: Boolean, strength: SignalStrengthView?): Int = when {
    !simReady || airplane || strength == null -> -1
    strength.cells.none { it.valid } -> -1
    else -> strength.level.coerceIn(0, 4)
}
