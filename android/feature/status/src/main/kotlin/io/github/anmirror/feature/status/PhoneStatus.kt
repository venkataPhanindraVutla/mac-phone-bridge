package io.github.anmirror.feature.status

import io.github.anmirror.protocol.v1.NetworkKind
import io.github.anmirror.protocol.v1.StatusUpdate

/** What the Mac shows about this phone. [signalLevel] is 0..4, or -1 for unknown / no service (no SIM, airplane mode,
 * no usable cell reading). 0 is a real "no bars" reading. [backgroundRestricted] is true when the phone is not exempt
 * from battery optimisation, so it may disconnect while locked (SPEC 7). */
data class PhoneStatus(
    val batteryPercent: Int,
    val charging: Boolean,
    val signalLevel: Int,
    val network: NetworkKind,
    val backgroundRestricted: Boolean = false,
) {
    fun toProto(): StatusUpdate = StatusUpdate.newBuilder()
        .setBatteryPercent(batteryPercent)
        .setCharging(charging)
        .setSignalLevel(signalLevel)
        .setNetwork(network)
        .setBackgroundRestricted(backgroundRestricted)
        .build()
}
