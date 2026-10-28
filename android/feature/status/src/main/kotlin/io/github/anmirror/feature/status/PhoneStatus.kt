package io.github.anmirror.feature.status

import io.github.anmirror.protocol.v1.NetworkKind
import io.github.anmirror.protocol.v1.StatusUpdate

/** What the Mac shows about this phone. [signalLevel] is 0..4, or -1 for unknown / no service (no SIM, airplane mode,
 * no usable cell reading). 0 is a real "no bars" reading. */
data class PhoneStatus(
    val batteryPercent: Int,
    val charging: Boolean,
    val signalLevel: Int,
    val network: NetworkKind,
) {
    fun toProto(): StatusUpdate = StatusUpdate.newBuilder()
        .setBatteryPercent(batteryPercent)
        .setCharging(charging)
        .setSignalLevel(signalLevel)
        .setNetwork(network)
        .build()
}
